require "base_x"
require "cbor"
require "openssl"
require "protobuf"

module Jalopy
  MAX_SIZE_V0 = 0x40000
  MAX_SIZE_V1 = 0x100000

  enum FileType
    Raw
    Directory
    File
    Metadata
    Symlink
    HAMTShard
  end

  #
  # Simple Protobuf structures for UnixFS
  #

  struct InlineFile
    include Protobuf::Message
    contract do
      required :type, FileType, 1, default: FileType::File
      optional :data, :bytes, 2
      optional :size, :uint64, 3
      repeated :blocks, :uint64, 4
    end
  end

  struct NodeLink
    include Protobuf::Message
    contract do
      optional :hash, :bytes, 1
      optional :name, :string, 2
      optional :tsize, :uint64, 3
    end
  end

  struct Node
    include Protobuf::Message
    contract do
      repeated :links, NodeLink, 2
      optional :file, InlineFile, 1
    end
  end

  #
  # Protobuf from IPNS spec, for creating a V1+V2 entry
  #

  module IPNS
    enum KeyType
      RSA
      Ed25519
      Secp256k1
      ECDSA
    end

    struct PublicKey
      include Protobuf::Message
      contract do
        required :type, KeyType, 1, default: KeyType::RSA
        required :data, :bytes, 2
      end
    end

    enum ValidityType
      EOL
    end

    class Repr
      include CBOR::Serializable
      @[CBOR::Field(key: "TTL")]
      property ttl : UInt64
      @[CBOR::Field(key: "Value")]
      property value : Bytes
      @[CBOR::Field(key: "Sequence")]
      property sequence : UInt64
      @[CBOR::Field(key: "Validity")]
      property validity : Time
      @[CBOR::Field(key: "ValidityType")]
      property validity_type : UInt64

      def initialize(@ttl, @value, @sequence, @validity, @validity_type)
      end
    end

    struct Entry
      include Protobuf::Message
      contract do
        optional :value, :bytes, 1
        optional :signatureV1, :bytes, 2
        optional :validityType, ValidityType, 3
        optional :validity, :bytes, 4
        optional :sequence, :uint64, 5
        optional :ttl, :uint64, 6
        optional :pubKey, :bytes, 7
        optional :signatureV2, :bytes, 8
        optional :data, :bytes, 9
      end

      def self.build(addr : String, sig : Bytes, seq : UInt64 = 0)
        addb = "/ipfs/#{addr}".to_slice
        timb = Time.utc + 100.years 
        repr = Jalopy::IPNS::Repr.new(UInt64.new(1800000000000), addb, seq, timb, 0)
        ipns = Jalopy::IPNS::Entry.new(signatureV2: sig, data: repr.to_cbor)
         
        io = ipns.to_protobuf
        io.rewind
        io
      end
    end
  end

  class CAR
    VERSION = 1
    @root : Bytes?

    def initialize(@io : IO = IO::Memory.new)
      @nodes = [] of {String?, Bytes, IO, UInt64}
    end

    def add(name : String, io : String | IO, len = io.size)
      cid, buf = Jalopy.node(io, len, 1,
        ->(id : Bytes, buf : IO::Memory) { @nodes.push({nil, id, buf, UInt64.new(buf.size)}) })
      @nodes.push({name, cid, buf, UInt64.new(len)})
      cid
    end

    def write_header(cid : Bytes)
      cidlen = UInt32.new(cid.size + 1)
      # Fixed header length
      Jalopy.write_leb128(@io, cidlen + 21)
      # CBOR map "roots" array
      @io.write(Bytes[0xa2, 0x65, 0x72, 0x6f, 0x6f, 0x74, 0x73, 0x81, 0xd8, 0x2a, 0x58, cidlen, 0x00])
      # Tagged CID
      @io.write(cid)
      # CBOR map "version" key
      @io.write(Bytes[0x67, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, VERSION])
    end

    def write_data(cid : Bytes, codec : UInt8, data : IO)
      io = IO::Memory.new
      io.write(cid)
      data.rewind
      IO.copy(data, io)
      io.rewind

      Jalopy.write_leb128(@io, UInt32.new(io.size))
      IO.copy(io, @io)
    end

    def root
      unless @root
        links = [] of NodeLink
        @nodes.each do |(name, id, buf, len)|
          links.push(NodeLink.new(hash: id, name: name, tsize: len)) if name
        end
        node = Node.new(file: InlineFile.new(type: FileType::Directory),
          links: links)
        io = node.to_protobuf
        io.rewind

        @root, buf = Jalopy.hash(0x70, io)
        @nodes.unshift({nil, @root.as(Bytes), buf, UInt64.new(buf.size)})
      end
      @root
    end

    def flush
      write_header(root.as(Bytes))
      @nodes.each do |(name, id, buf, len)|
        write_data(id, 0x70, buf)
      end
    end
  end

  def self.write_leb128(io : IO, n : UInt32)
    loop do
      bits = n & 0x7F
      n >>= 7
      if n == 0
        io.write_byte(bits.to_u8!)
        break
      end
      io.write_byte (bits | 0x80).to_u8!
    end
  end

  def self.hash(codec : Int32, buf : IO::Memory, version = 1)
    extra = (version == 0 ? 2 : 4)
    hsh = OpenSSL::Digest.new("SHA256").update(buf).final
    multi = Bytes.new(hsh.size + extra)
    if version == 0
      multi[0] = 0x12
      multi[1] = 0x20
    else
      multi[0] = 0x1
      multi[1] = codec.to_u8
      multi[2] = 0x12
      multi[3] = 0x20
    end
    hsh.each_with_index { |x, i| multi[i + extra] = x }
    {multi, buf}
  end

  # Builds a CID and UNIXFS node for some content.
  def self.node(io : String | IO, len : Number = io.size, version = 1, block : (Bytes, IO ->)? = nil)
    io =
      case io
      when String
        IO::Memory.new(io)
      else
        io
      end

    max_size = (version == 0 ? MAX_SIZE_V0 : MAX_SIZE_V1)
    codec, proto =
      if len <= max_size
        if version == 0
          slice = Bytes.new(len)
          io.read(slice)
          n = Node.new(file: InlineFile.new(type: FileType::File, data: slice, size: UInt64.new(len)))
          {0x70, n.to_protobuf}
        else
          buf = IO::Memory.new
          IO.copy(io, buf, len)
          {0x55, buf}
        end
      else
        links = [] of NodeLink
        blocks = [] of UInt64
        rem = len
        while rem > 0
          chunk = Math.min(rem, max_size)
          linkid, linkbuf = node(io, chunk, version)
          links << NodeLink.new(hash: linkid, name: "", tsize: UInt64.new(linkbuf.size))
          block.call(linkid, linkbuf) if block
          blocks << UInt64.new(chunk)
          rem -= chunk
        end
        n = Node.new(links: links, file: InlineFile.new(type: FileType::File, size: UInt64.new(len), blocks: blocks))
        {0x70, n.to_protobuf}
      end

    proto.rewind
    hash(codec, proto, version)
  end

  # Computes the raw CID and file size for an IPFS chunk.
  #
  # Returns {cid, size} 
  def self.link(io : String | IO, len = io.size, version = 1)
    multi, buf = node(io, len, version)
    {multi, buf.size}
  end

  BASE32 = "abcdefghijklmnopqrstuvwxyz234567"
  BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  # Computes the CID string (Base85-encoded multihash, suitable for IPFS) for a
  # file. Files larger than MAX_SIZE will be split into chunks.
  def self.cid(io, len = io.size, version = 1)
    str, _ = node(io, len, version)
    if version == 0
      self.encode(str, BASE58)
    else
      "b" + self.base32(str)
    end
  end

  def self.base32(ary)
    String.build do |str|
      i = 0
      until i > ary.size
        n = ((ary[i]? || 0).to_u64! << 32) | ((ary[i + 1]? || 0).to_u64! << 24) | ((ary[i + 2]? || 0).to_u64! << 16) |
         ((ary[i + 3]? || 0).to_u64! << 8) | (ary[i + 4]? || 0).to_u64!
        e = (40 - (Math.min(ary.size - i, 5) * 8)) - 4
        j = 35
        while j >= e
          str << BASE32[(n >> j) & 0x1f]
          j -= 5 
        end
        i += 5
      end
    end
  end

  def self.encode(ary, alpha, base = alpha.size)
    int = ary.empty? ? 0 : ary.hexstring.to_big_i(16)
    String.build do |str|
      while int >= base
        mod = int % base
        str << alpha[mod, 1]
        int = (int - mod).divmod(base).first
      end
      str << alpha[int, 1]
    end.reverse
  end
end

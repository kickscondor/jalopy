require "base_x"
require "openssl"
require "protobuf"

module Jalopy
  MAX_SIZE = 0x100000

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

  class CAR
    VERSION = 1

    def initialize(@io : IO = IO::Memory.new)
      @nodes = [] of {String?, Bytes, IO, UInt64}
    end

    def add(name : String, io : String | IO, len = io.size)
      cid, buf = Jalopy.node(io, len,
        ->(id : Bytes, buf : IO::Memory) { @nodes.push({nil, id, buf, UInt64.new(buf.size)}) })
      @nodes.push({name, cid, buf, UInt64.new(len)})
    end

    def write_leb128(io : IO, n : UInt32)
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

    def write_header(cid : Bytes)
      # Fixed header length
      write_leb128(@io, 0x3a)
      # CBOR map "roots" array
      @io.write(Bytes[0xa2, 0x65, 0x72, 0x6f, 0x6f, 0x74, 0x73, 0x81, 0xd8, 0x2a, 0x58, 0x25, 0x00])
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

      write_leb128(@io, UInt32.new(io.size))
      IO.copy(io, @io)
    end

    def flush
      links = [] of NodeLink
      @nodes.each do |(name, id, buf, len)|
        links.push(NodeLink.new(hash: id, name: name, tsize: len)) if name
      end
      node = Node.new(file: InlineFile.new(type: FileType::Directory),
        links: links)
      io = node.to_protobuf
      io.rewind
      root, buf = Jalopy.hash(0x70, io)
      @nodes.push({nil, root, buf, UInt64.new(buf.size)})

      write_header(root)
      @nodes.each do |(name, id, buf, len)|
        write_data(id, 0x70, buf)
      end
    end
  end

  def self.hash(codec : Int32, buf : IO::Memory)
    hsh = OpenSSL::Digest.new("SHA256").update(buf).final
    multi = Bytes.new(hsh.size + 4)
    multi[0] = 0x1
    multi[1] = codec.to_u8
    multi[2] = 0x12
    multi[3] = 0x20
    hsh.each_with_index { |x, i| multi[i + 4] = x }
    {multi, buf}
  end

  # Builds a CID and UNIXFS node for some content.
  def self.node(io : String | IO, len : Number = io.size, block : (Bytes, IO ->)? = nil)
    io =
      case io
      when String
        IO::Memory.new(io)
      else
        io
      end

    codec, proto =
      if len <= MAX_SIZE
        buf = IO::Memory.new
        IO.copy(io, buf, len)
        {0x55, buf}
      else
        links = [] of NodeLink
        blocks = [] of UInt64
        rem = len
        while rem > 0
          chunk = Math.min(rem, MAX_SIZE)
          linkid, linkbuf = node(io, chunk)
          links << NodeLink.new(hash: linkid, name: "", tsize: UInt64.new(linkbuf.size))
          block.call(linkid, linkbuf) if block
          blocks << UInt64.new(chunk)
          rem -= chunk
        end
        n = Node.new(links: links, file: InlineFile.new(type: FileType::File, size: UInt64.new(len), blocks: blocks))

        buf = n.to_protobuf
        {0x70, buf}
      end

    proto.rewind
    hash(codec, proto)
  end

  # Computes the raw CID and file size for an IPFS chunk.
  #
  # Returns {cid, size} 
  def self.link(io : String | IO, len = io.size)
    multi, buf = node(io, len)
    {multi, buf.size}
  end

  # Computes the CID string (Base85-encoded multihash, suitable for IPFS) for a
  # file. Files larger than MAX_SIZE will be split into chunks.
  def self.cid(io, len = io.size)
    str, _ = link(io, len)
    BaseX::Base58.encode(str)
  end
end

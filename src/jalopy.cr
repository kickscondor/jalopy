require "base_x"
require "openssl"
require "protobuf"

module Jalopy
  MAX_SIZE = 262144

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

  # Computes the raw CID and file size for an IPFS chunk.
  #
  # Returns {cid, size} 
  def self.link(io : String | IO, len = io.size)
    io =
      case io
      when String
        IO::Memory.new(io)
      else
        io
      end

    proto =
      if len <= MAX_SIZE
        slice = Bytes.new(len)
        io.read(slice)
        Node.new(file: InlineFile.new(type: FileType::File, data: slice, size: UInt64.new(len)))
      else
        links = [] of NodeLink
        blocks = [] of UInt64
        rem = len
        while rem > 0
          chunk = Math.min(rem, MAX_SIZE)
          linkid, linkchunk = link(io, chunk)
          links << NodeLink.new(hash: linkid, name: "", tsize: UInt64.new(linkchunk))
          blocks << UInt64.new(chunk)
          rem -= chunk
        end
        Node.new(links: links, file: InlineFile.new(type: FileType::File, size: UInt64.new(len), blocks: blocks))
      end

    buf = proto.to_protobuf
    hsh = OpenSSL::Digest.new("SHA256").update(buf).final
    multi = Bytes.new(hsh.size + 2)
    multi[0] = 0x12
    multi[1] = 0x20
    hsh.each_with_index { |x, i| multi[i + 2] = x }
    {multi, buf.size}
  end

  # Computes the CID string (Base85-encoded multihash, suitable for IPFS) for a
  # file. Files larger than MAX_SIZE will be split into chunks.
  def self.cid(io, len = io.size)
    str, _ = link(io, len)
    BaseX::Base58.encode(str)
  end
end

require "spec"
require "../src/jalopy"

describe Jalopy do
  describe "#cid" do
    it "encodes a small string" do
      str = "ipfs-multihash"
      cid = Jalopy.cid(str)
      cid.should eq "QmYMv86WfWCFKifDYRaFUM7F1p7z7NuZv8bXTWUYBgQWcL"
    end

    it "encodes a small string with a newline" do
      str = "Hello World\n"
      cid = Jalopy.cid(str)
      cid.should eq "QmWATWQ7fVPP2EFGu71UkfnqhYXDYH566qy47CnJDgvs8u"
    end

    it "encodes a 13k HTML file" do
      io = File.open("spec/hen.html")
      cid = Jalopy.cid(io)
      cid.should eq "QmRDXYAzwWPNq9bHoshz83T6f2uui4vy4XNCaCv963M3zK"
    end

    it "encodes a 13k HTML file" do
      io = File.open("spec/static.gif")
      cid = Jalopy.cid(io)
      cid.should eq "QmX6aEL1LCCNAqFaDYxsaFMQEApan6Mpvy8n95pqZi9Upd"
    end
  end

  describe Jalopy::CAR do
    it "packages the spec directory" do
      File.open("spec.car", "w") do |f|
        car = Jalopy::CAR.new(f)
        car.add("hello.txt", "Hello!")
        car.add("hello2.txt", "Hello2")
        car.add("static.gif", File.open("spec/static.gif"), 1209555)
        car.flush
      end
    end
  end
end

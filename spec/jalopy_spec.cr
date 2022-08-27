require "spec"
require "../src/jalopy"

describe Jalopy do
  describe "#cid" do
    it "encodes a small string" do
      str = "ipfs-multihash"
      cid = Jalopy.cid(str, version: 0)
      cid.should eq "QmYMv86WfWCFKifDYRaFUM7F1p7z7NuZv8bXTWUYBgQWcL"
      cid = Jalopy.cid(str, version: 1)
      cid.should eq "bafkreic35sj7aglwpkijjn5za3yf3d24yqdxe3ajp775akt6qwdyjnciba"
    end

    it "encodes a small string with a newline" do
      str = "Hello World\n"
      cid = Jalopy.cid(str, version: 0)
      cid.should eq "QmWATWQ7fVPP2EFGu71UkfnqhYXDYH566qy47CnJDgvs8u"
      cid = Jalopy.cid(str, version: 1)
      cid.should eq "bafkreigsvbhuxc3fbe36zd3tzwf6fr2k3vnjcg5gjxzhiwhnqiu5vackey"
    end

    it "encodes a 13k HTML file" do
      io = File.open("spec/hen.html")
      cid = Jalopy.cid(io, version: 0)
      cid.should eq "QmRDXYAzwWPNq9bHoshz83T6f2uui4vy4XNCaCv963M3zK"
      io.rewind
      cid = Jalopy.cid(io, version: 1)
      cid.should eq "bafkreidta54hbobjtrat3szzmgssn3y5syj3ayyem4vavnrerrrqts5bve"
    end

    it "encodes a 13k HTML file" do
      io = File.open("spec/static.gif")
      cid = Jalopy.cid(io, version: 0)
      cid.should eq "QmX6aEL1LCCNAqFaDYxsaFMQEApan6Mpvy8n95pqZi9Upd"
      io.rewind
      cid = Jalopy.cid(io, version: 1)
      cid.should eq "bafybeifva4jmzwr2jeas6i7ef5fqjskom2ronwm4soadhtsc54q22prkaq"
    end
  end

  describe Jalopy::CAR do
    it "packages the spec directory" do
      File.open("spec.car", "w") do |f|
        car = Jalopy::CAR.new(f)
        car.add("small.txt", "ipfs-multihash")
        car.add("hen.html", File.open("spec/hen.html"), 13653)
        car.add("static.gif", File.open("spec/static.gif"), 1209555)
        car.flush
      end
    end
  end
end

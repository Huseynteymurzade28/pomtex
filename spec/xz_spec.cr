require "./spec_helper"

private def xz(data : String) : Bytes
  output = IO::Memory.new
  Process.run("xz", ["-c"], input: IO::Memory.new(data), output: output).success?.should be_true
  output.to_slice
end

private def decode(bytes : Bytes) : String
  Pomtex::Seed::XZ::Reader.open(IO::Memory.new(bytes)) { |reader| reader.gets_to_end }
end

describe Pomtex::Seed::XZ::Reader do
  it "decodes a stream larger than its buffers" do
    text = "pomegranate arils\n" * 50_000
    decode(xz(text)).should eq text
  end

  it "decodes concatenated streams" do
    joined = IO::Memory.new
    joined.write(xz("first "))
    joined.write(xz("second"))
    decode(joined.to_slice).should eq "first second"
  end

  it "rejects data that is not xz" do
    expect_raises(Pomtex::Error, /not in .xz format/) { decode(("plain text, not compressed " * 10).to_slice) }
  end

  it "rejects a truncated stream" do
    bytes = xz("x" * 10_000)
    expect_raises(Pomtex::Error, /unexpected end of input/) { decode(bytes[0, bytes.size - 8]) }
  end

  it "rejects corrupt data" do
    bytes = xz("checksummed " * 1000).dup
    bytes[bytes.size // 2] ^= 0xff
    expect_raises(Pomtex::Error, /xz:/) { decode(bytes) }
  end
end

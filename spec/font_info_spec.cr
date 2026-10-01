require "./spec_helper"
require "../src/seed/font_info"

# A minimal sfnt with only a `name` table, enough for FontInfo.
private def font_bytes(records : Array({UInt16, UInt16, UInt16, UInt16, Bytes}), magic = "OTTO") : Bytes
  io = IO::Memory.new
  be = IO::ByteFormat::BigEndian
  io.write(magic.to_slice)
  io.write_bytes(1_u16, be) # numTables
  io.write(Bytes.new(6))    # searchRange, entrySelector, rangeShift
  io.write("name".to_slice)
  io.write_bytes(0_u32, be)  # checksum
  io.write_bytes(28_u32, be) # offset of the name table (12 + 16)
  io.write_bytes(0_u32, be)  # length (unused)

  storage = 6 + 12 * records.size
  io.write_bytes(0_u16, be)
  io.write_bytes(records.size.to_u16, be)
  io.write_bytes(storage.to_u16, be)
  offset = 0
  records.each do |platform, encoding, language, name_id, text|
    {platform, encoding, language, name_id, text.size.to_u16, offset.to_u16}.each { |value| io.write_bytes(value, be) }
    offset += text.size
  end
  records.each { |record| io.write(record[4]) }
  io.to_slice
end

private def utf16(text : String) : Bytes
  io = IO::Memory.new
  text.to_utf16.each { |unit| io.write_bytes(unit, IO::ByteFormat::BigEndian) }
  io.to_slice
end

describe Pomtex::Seed::FontInfo do
  it "prefers the typographic family over the legacy one" do
    with_tmpdir do |dir|
      bytes = font_bytes([
        {3_u16, 1_u16, 0x409_u16, 1_u16, utf16("Fira Sans Light")},
        {3_u16, 1_u16, 0x409_u16, 16_u16, utf16("Fira Sans")},
      ])
      File.write(dir.join("f.otf"), bytes)
      Pomtex::Seed::FontInfo.family(dir.join("f.otf")).should eq "Fira Sans"
    end
  end

  it "falls back to Mac Roman names and TrueType headers" do
    with_tmpdir do |dir|
      File.write(dir.join("f.ttf"), font_bytes([{1_u16, 0_u16, 0_u16, 1_u16, "Inconsolatazi4".to_slice}], "\u{0}\u{1}\u{0}\u{0}"))
      Pomtex::Seed::FontInfo.family(dir.join("f.ttf")).should eq "Inconsolatazi4"
    end
  end

  it "returns nil for files that are not fonts" do
    with_tmpdir do |dir|
      File.write(dir.join("x.otf"), "not a font")
      Pomtex::Seed::FontInfo.family(dir.join("x.otf")).should be_nil
    end
  end
end

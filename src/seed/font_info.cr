module Pomtex::Seed
  # Reads family names from OpenType/TrueType fonts (the `name` table), so
  # pomtex can tell users the name fontspec actually expects.
  module FontInfo
    extend self

    BE = IO::ByteFormat::BigEndian

    TYPOGRAPHIC_FAMILY = 16_u16 # preferred family ("Inconsolatazi4")
    FAMILY             =  1_u16 # legacy family, may carry the style ("Fira Sans Light")

    # The family name of the first font in `path` (.otf, .ttf or .ttc), if readable.
    def family(path : Path | String) : String?
      File.open(path) do |io|
        offset = font_offset(io)
        return nil unless offset
        name_table = find_table(io, offset, "name")
        return nil unless name_table
        names = read_names(io, name_table)
        names[TYPOGRAPHIC_FAMILY]? || names[FAMILY]?
      end
    rescue IO::Error | File::Error
      nil
    end

    # Collections (.ttc) start with "ttcf" and point to their first font.
    private def font_offset(io : IO) : UInt32?
      tag = read_tag(io)
      case tag
      when "ttcf"
        io.seek(12)
        io.read_bytes(UInt32, BE)
      when "OTTO", "true", "\u{0}\u{1}\u{0}\u{0}"
        0_u32
      end
    end

    private def find_table(io : IO, font_offset : UInt32, wanted : String) : UInt32?
      io.seek(font_offset + 4)
      count = io.read_bytes(UInt16, BE)
      io.seek(font_offset + 12)
      count.times do
        tag = read_tag(io)
        io.skip(4) # checksum
        offset = io.read_bytes(UInt32, BE)
        io.skip(4) # length
        return offset if tag == wanted
      end
      nil
    end

    # nameID => string, preferring Windows English (3/1/0x409), then any
    # Windows Unicode record, then Mac Roman.
    private def read_names(io : IO, table : UInt32) : Hash(UInt16, String)
      io.seek(table + 2)
      count = io.read_bytes(UInt16, BE)
      storage = table + io.read_bytes(UInt16, BE)
      ranked = {} of UInt16 => {Int32, String}
      records = Array.new(count) do
        {io.read_bytes(UInt16, BE), io.read_bytes(UInt16, BE), io.read_bytes(UInt16, BE),
         io.read_bytes(UInt16, BE), io.read_bytes(UInt16, BE), io.read_bytes(UInt16, BE)}
      end
      records.each do |platform, encoding, language, name_id, length, offset|
        next unless name_id == FAMILY || name_id == TYPOGRAPHIC_FAMILY
        rank = rank(platform, encoding, language)
        next unless rank
        next if (current = ranked[name_id]?) && current[0] <= rank
        io.seek(storage + offset)
        bytes = Bytes.new(length)
        io.read_fully(bytes)
        text = platform == 3 ? utf16be(bytes) : String.new(bytes)
        ranked[name_id] = {rank, text.strip} unless text.blank?
      end
      ranked.transform_values(&.[1])
    end

    private def rank(platform : UInt16, encoding : UInt16, language : UInt16) : Int32?
      if platform == 3 && (encoding == 1 || encoding == 10)
        language == 0x409 ? 0 : 1
      elsif platform == 1 && encoding == 0
        2
      end
    end

    private def utf16be(bytes : Bytes) : String
      units = Slice(UInt16).new(bytes.size // 2) { |i| (bytes[2 * i].to_u16 << 8) | bytes[2 * i + 1] }
      String.from_utf16(units)
    end

    private def read_tag(io : IO) : String
      bytes = Bytes.new(4)
      io.read_fully(bytes)
      String.new(bytes)
    end
  end
end

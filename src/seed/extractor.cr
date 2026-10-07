require "compress/gzip"
require "../config"
require "./xz"

module Pomtex::Seed
  # Streams tar archives (.tar, .tar.gz, .tar.xz) straight into a target tree.
  #
  # The tar reader is implemented here (ustar + GNU long names + PAX paths); xz
  # goes through liblzma and gzip through the stdlib, so no external tools run.
  module Extractor
    extend self

    BLOCK = 512

    record Entry, name : String, type : Char, mode : Int32, size : Int64, link : String

    # Unpacks a TeX Live aril container into the user texmf tree, skipping the
    # tlpkg/ metadata. Returns the relative paths of the files written.
    def extract_aril(archive : Path | String, texmf : Path = Config.texmf_dir) : Array(String)
      extract(archive, texmf) { |name| name.starts_with?("tlpkg/") ? nil : name }
    end

    # Unpacks `archive` under `dest`. The block may rewrite each entry name or
    # return nil to skip it.
    def extract(archive : Path | String, dest : Path, &rename : String -> String?) : Array(String)
      Dir.mkdir_p(dest)
      root = File.realpath(dest)
      written = [] of String
      with_decompressed(archive.to_s) do |io|
        each_entry(io) do |entry, data|
          name = rename.call(entry.name)
          next if name.nil? || name.empty?
          relative = sanitize(name)
          next if relative.nil?
          target = Path[root].join(relative)
          case entry.type
          when '5'
            Dir.mkdir_p(target)
          when '2'
            prepare_parent(root, target)
            File.delete(target) if File.symlink?(target) || File.file?(target)
            File.symlink(entry.link, target)
            written << relative
          when '1'
            source = sanitize(rename.call(entry.link) || "")
            next unless source
            prepare_parent(root, target)
            File.delete(target) if File.exists?(target)
            File.copy(Path[root].join(source), target)
            written << relative
          when '0', '\0', '7'
            prepare_parent(root, target)
            File.delete(target) if File.symlink?(target)
            File.open(target, "w") { |file| IO.copy(data, file, entry.size) }
            File.chmod(target, entry.mode & 0o777 | 0o600)
            written << relative
          end
        end
      end
      written
    end

    # Yields an IO over the decompressed tar stream.
    def with_decompressed(path : String, & : IO ->) : Nil
      if path.ends_with?(".xz") || path.ends_with?(".txz")
        File.open(path) do |file|
          XZ::Reader.open(file) do |xz|
            yield xz
            # Decode past the end-of-archive marker so the stream checksums are verified.
            xz.skip_to_end
          end
        end
      elsif path.ends_with?(".gz") || path.ends_with?(".tgz")
        File.open(path) { |file| Compress::Gzip::Reader.open(file) { |gzip| yield gzip } }
      else
        File.open(path) { |file| yield file }
      end
    end

    # Iterates over tar entries. `data` is positioned at the entry payload; any
    # unread payload is skipped automatically.
    def each_entry(io : IO, & : Entry, IO ->) : Nil
      header = Bytes.new(BLOCK)
      long_name : String? = nil
      long_link : String? = nil
      pax = {} of String => String

      loop do
        break unless read_block(io, header)
        break if header.all?(&.zero?)

        size = parse_size(header[124, 12])
        type = header[156].unsafe_chr
        payload = IO::Sized.new(io, read_size: size)

        case type
        when 'L'
          long_name = payload.gets_to_end.rstrip('\0')
        when 'K'
          long_link = payload.gets_to_end.rstrip('\0')
        when 'x'
          pax = parse_pax(payload.gets_to_end)
        when 'g'
          # Global PAX headers carry nothing we need.
        else
          name = pax["path"]? || long_name || header_name(header)
          link = pax["linkpath"]? || long_link || cstring(header[157, 100])
          mode = parse_octal(header[100, 8]).to_i32
          yield Entry.new(name, type, mode, size, link), payload
          long_name = long_link = nil
          pax = {} of String => String
        end

        payload.skip_to_end
        padding = (BLOCK - size % BLOCK) % BLOCK
        io.skip(padding) if padding > 0
      end
    end

    # Normalises an archive path, rejecting absolute paths and `..` traversal.
    def sanitize(name : String) : String?
      parts = name.split('/').reject { |part| part.empty? || part == "." }
      return nil if parts.empty? || parts.any?("..") || name.starts_with?('/')
      parts.join('/')
    end

    private def prepare_parent(root : String, target : Path) : Nil
      parent = target.parent
      Dir.mkdir_p(parent)
      real = File.realpath(parent)
      unless real == root || real.starts_with?(root + "/")
        raise Error.new("refusing to write outside #{root}: #{target}")
      end
    end

    private def read_block(io : IO, buffer : Bytes) : Bool
      read = io.read_fully?(buffer)
      !read.nil?
    end

    private def header_name(header : Bytes) : String
      name = cstring(header[0, 100])
      magic = String.new(header[257, 5])
      prefix = magic == "ustar" ? cstring(header[345, 155]) : ""
      prefix.empty? ? name : "#{prefix}/#{name}"
    end

    private def cstring(bytes : Bytes) : String
      length = bytes.index(0_u8) || bytes.size
      String.new(bytes[0, length])
    end

    private def parse_size(field : Bytes) : Int64
      if field[0] & 0x80 != 0
        # GNU base-256 encoding for very large members.
        value = (field[0] & 0x7f).to_i64
        field[1..].each { |byte| value = (value << 8) | byte }
        value
      else
        parse_octal(field)
      end
    end

    private def parse_octal(field : Bytes) : Int64
      text = cstring(field).strip(" \0")
      text.empty? ? 0_i64 : text.to_i64(8)
    end

    # PAX records look like "<len> key=value\n".
    private def parse_pax(body : String) : Hash(String, String)
      records = {} of String => String
      body.each_line(chomp: true) do |line|
        _, _, record = line.partition(' ')
        key, eq, value = record.partition('=')
        records[key] = value unless eq.empty?
      end
      records
    end
  end
end

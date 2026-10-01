require "../config"
require "./extractor"
require "./aril_fetcher"

module Pomtex::Seed
  # One CTAN/TeX Live package as published in tlnet.
  record Package,
    name : String,
    size : Int64,
    sha512 : String,
    depends : Array(String),
    probe : String?,
    maps : Array(String)

  # The file -> package index, built from TeX Live's texlive.tlpdb and cached as TSV.
  class Index
    FORMAT_TAG = "pomtex-index-v1"
    MAX_AGE    = 14.days

    getter packages = {} of String => Package
    getter files = {} of String => String
    getter fonts = {} of String => String

    # Parses a texlive.tlpdb stream. Only run files are indexed; doc/src files are
    # never fetched because arils are run-time containers.
    def self.from_tlpdb(io : IO) : Index
      index = new
      ranks = {} of String => Int32

      name = ""
      size = 0_i64
      sha = ""
      depends = [] of String
      maps = [] of String
      runfiles = [] of String
      section = ""

      flush = -> do
        unless name.empty? || Config.skip_package?(name)
          probe = runfiles.find { |path| path.starts_with?("tex/") && path.ends_with?(/\.(sty|cls)$/) } ||
                  runfiles.find(&.starts_with?("tex/")) || runfiles.first?
          index.packages[name] = Package.new(name, size, sha, depends.dup, probe.try { |p| File.basename(p) }, maps.dup)
          runfiles.each do |path|
            base = File.basename(path)
            rank = file_rank(path)
            if (current = ranks[base]?).nil? || rank < current
              ranks[base] = rank
              index.files[base] = name
            end
            if base.ends_with?(".otf") || base.ends_with?(".ttf")
              index.fonts[normalize_font(File.basename(base, File.extname(base)))] ||= base
            end
          end
        end
        name = ""
        size = 0_i64
        sha = ""
        depends.clear
        maps.clear
        runfiles.clear
        section = ""
      end

      io.each_line(chomp: true) do |line|
        if line.empty?
          flush.call
        elsif line.starts_with?(' ')
          next unless section == "runfiles"
          path = line.lstrip.split(' ', 2).first
          path = path.lchop("RELOC/").lchop("texmf-dist/")
          runfiles << path unless path.starts_with?("bin/") || path.starts_with?("tlpkg/")
        else
          key, _, value = line.partition(' ')
          section = key
          case key
          when "name"              then name = value
          when "containersize"     then size = value.to_i64? || 0_i64
          when "containerchecksum" then sha = value
          when "depend"            then depends << value unless value.includes?("ARCH")
          when "execute"
            action, _, argument = value.partition(' ')
            maps << argument if action == "addMap" || action == "addMixedMap"
          end
        end
      end
      flush.call
      index
    end

    def self.load(path : Path) : Index?
      return nil unless File.exists?(path)
      index = new
      File.open(path) do |file|
        return nil unless file.gets(chomp: true) == FORMAT_TAG
        file.each_line(chomp: true) do |line|
          fields = line.split('\t')
          case fields[0]?
          when "P"
            next unless fields.size >= 7
            index.packages[fields[1]] = Package.new(
              fields[1], fields[2].to_i64? || 0_i64, fields[3], split_list(fields[5]),
              fields[4].presence, split_list(fields[6]))
          when "F" then index.files[fields[1]] = fields[2] if fields.size >= 3
          when "T" then index.fonts[fields[1]] = fields[2] if fields.size >= 3
          end
        end
      end
      index
    end

    def save(path : Path) : Nil
      tmp = Path["#{path}.tmp"]
      File.open(tmp, "w") do |file|
        file.puts FORMAT_TAG
        packages.each_value do |pkg|
          file << "P\t" << pkg.name << '\t' << pkg.size << '\t' << pkg.sha512 << '\t' << (pkg.probe || "") << '\t'
          file << pkg.depends.join(',') << '\t' << pkg.maps.join(',') << '\n'
        end
        files.each { |base, pkg| file << "F\t" << base << '\t' << pkg << '\n' }
        fonts.each { |key, base| file << "T\t" << key << '\t' << base << '\n' }
      end
      File.rename(tmp, path)
    end

    def self.normalize_font(name : String) : String
      name.downcase.gsub(/[\s_\-]/, "")
    end

    private def self.split_list(field : String) : Array(String)
      field.split(',', remove_empty: true)
    end

    # Lower is better: when two packages ship the same basename prefer LaTeX ones.
    private def self.file_rank(path : String) : Int32
      case path
      when .starts_with?("tex/latex/")   then 0
      when .starts_with?("tex/generic/") then 1
      when .starts_with?("tex/")         then 2
      when .starts_with?("fonts/")       then 3
      else                                    4
      end
    end
  end

  # Maps requested files (*.sty, *.cls, *.tfm, ...) to the arils that provide them.
  class Resolver
    getter index : Index?

    def initialize(@index : Index?)
    end

    # Loads the cached index, (re)building it from tlnet when missing or stale.
    def self.open(offline : Bool = false, refresh : Bool = false) : Resolver
      path = Config.index_file
      cached = refresh ? nil : Index.load(path)
      fresh = cached && File.info(path).modification_time > Time.utc - Index::MAX_AGE
      return new(cached) if offline || fresh

      begin
        new(rebuild_index)
      rescue ex
        raise ex unless cached
        UI.warn "could not refresh the package index (#{ex.message}); using the cached copy"
        new(cached)
      end
    end

    def self.rebuild_index : Index
      Config.ensure_dirs
      archive = Config.downloads_dir.join("texlive.tlpdb.xz")
      UI.step "Indexing the orchard (texlive.tlpdb)"
      started = Pomtex.clock
      ArilFetcher.stream(Config.tlpdb_url, archive)
      index = uninitialized Index
      Extractor.with_decompressed(archive.to_s) { |io| index = Index.from_tlpdb(io) }
      index.save(Config.index_file)
      File.delete?(archive)
      UI.ok "#{index.packages.size} packages, #{index.files.size} files indexed in #{UI.duration(Pomtex.clock - started)}"
      index
    end

    def available? : Bool
      !index.nil?
    end

    # Other names that satisfy a request: \usetikzlibrary{x} falls back to the
    # pgf-level library when there is no tikz-level one (e.g. arrows.meta).
    def self.alternates(file : String) : Array(String)
      if file.starts_with?("tikzlibrary")
        [file.sub("tikzlibrary", "pgflibrary")]
      else
        [] of String
      end
    end

    # The package that provides `file`, trying `file.tex` for extension-less inputs.
    def package_for(file : String) : String?
      ([file] + self.class.alternates(file)).each do |name|
        if pkg = package_for_name(name)
          return pkg
        end
      end
      nil
    end

    private def package_for_name(file : String) : String?
      base = File.basename(file)
      if idx = index
        # Like kpathsea, retry with ".tex" (\input{pgf.revision} reads pgf.revision.tex).
        idx.files[base]? || (base.ends_with?(".tex") ? nil : idx.files["#{base}.tex"]?)
      else
        Config::SEED_HINTS[base]?
      end
    end

    def package(name : String) : Package?
      index.try &.packages[name]?
    end

    # Finds an OpenType/TrueType file for a font name such as "TeX Gyre Termes".
    def font_file(name : String) : String?
      idx = index
      return nil unless idx
      key = Index.normalize_font(File.basename(name, File.extname(name)))
      return nil if key.empty?
      idx.fonts[key]? ||
        idx.fonts.find { |stem, _| stem.starts_with?("#{key}regular") }.try(&.[1]) ||
        idx.fonts.find { |stem, _| stem.starts_with?(key) }.try(&.[1])
    end

    # Expands `roots` with their dependencies, keeping only packages for which
    # `missing` reports true. `missing` receives a whole layer at a time so the
    # caller can probe kpathsea in one batch.
    def closure(roots : Enumerable(String), & : Array(Package) -> Array(Package)) : Array(Package)
      result = [] of Package
      seen = Set(String).new
      layer = roots.to_a.uniq

      until layer.empty?
        candidates = layer.compact_map do |name|
          next if seen.includes?(name) || Config.skip_package?(name)
          seen << name
          package(name) || (index ? nil : Package.new(name, 0_i64, "", [] of String, nil, [] of String))
        end
        break if candidates.empty?
        absent = yield candidates
        result.concat(absent)
        layer = absent.flat_map(&.depends).reject { |dep| seen.includes?(dep) }.uniq
      end
      result
    end
  end
end

module Pomtex::Seed
  # Records which arils pomtex planted, so they can be listed, removed and so
  # their font map files can be handed to the engine.
  module Manifest
    extend self

    record Entry, name : String, maps : Array(String), files : Array(String)

    def record(name : String, maps : Array(String), files : Array(String)) : Nil
      Dir.mkdir_p(Config.arils_dir)
      File.open(path(name), "w") do |io|
        io << "maps: " << maps.join(',') << '\n'
        files.each { |file| io << file << '\n' }
      end
    end

    def installed?(name : String) : Bool
      File.exists?(path(name))
    end

    def entries : Array(Entry)
      return [] of Entry unless Dir.exists?(Config.arils_dir)
      Dir.children(Config.arils_dir).select(&.ends_with?(".list")).sort.compact_map { |child| load(child.rchop(".list")) }
    end

    def load(name : String) : Entry?
      file = path(name)
      return nil unless File.exists?(file)
      lines = File.read_lines(file)
      header = lines.shift? || ""
      maps = header.lchop("maps:").strip.split(',', remove_empty: true)
      Entry.new(name, maps, lines.reject(&.empty?))
    end

    def map_files : Array(String)
      entries.flat_map(&.maps).uniq
    end

    # Deletes an aril's files from the texmf tree, pruning empty directories.
    def remove(name : String) : Bool
      entry = load(name)
      return false unless entry
      root = Config.texmf_dir
      entry.files.each do |relative|
        target = root.join(relative)
        File.delete?(target) if File.symlink?(target) || File.file?(target)
        dir = target.parent
        while dir != root && dir.to_s.starts_with?(root.to_s) && Dir.exists?(dir) && Dir.empty?(dir)
          Dir.delete(dir)
          dir = dir.parent
        end
      end
      File.delete?(path(name))
      true
    end

    private def path(name : String) : Path
      Config.arils_dir.join("#{name}.list")
    end
  end
end

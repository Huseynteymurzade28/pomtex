require "../config"

module Pomtex::Seed
  # What a document needs before it can be compiled.
  class ScanResult
    getter files = Set(String).new                    # TeX-side files: foo.sty, bar.cls, tikzlibraryx.code.tex, ...
    getter fonts = Set(String).new                    # fontspec font names
    getter sources = [] of Path                       # local files that were scanned
    property engine : String? = nil                   # explicit `% !TEX program = ...`
    property needs_unicode = false                    # fontspec & friends
    property needs_lua = false                        # \directlua, luacode, ...
    getter tcb_libraries = Set(String).new            # tcolorbox libraries: `skins`, `most`, ...
    getter tcb_styles = {} of String => Array(String) # library styles defined by tcolorbox.sty
    getter assets = [] of Path                        # local non-TeX inputs: graphics, .bib, listings
    getter asset_refs = [] of Scanner::AssetRef       # unresolved references to those inputs
    getter graphics_paths = [] of String              # \graphicspath{{fig/}{img/}}
    property current_dir : Path? = nil                # directory of the file being scanned

    # The engine to run when the user did not choose one.
    def suggested_engine : String
      if explicit = engine
        return explicit
      end
      return "lualatex" if needs_lua
      return "xelatex" if needs_unicode || !fonts.empty?
      "pdflatex"
    end

    def packages : Array(String)
      files.select(&.ends_with?(".sty")).map(&.rchop(".sty")).sort!
    end

    # Library files for the requested tcolorbox libraries. Styles such as `most`
    # expand to other libraries once tcolorbox.sty (which defines them) is scanned.
    def tcb_library_files : Set(String)
      result = Set(String).new
      seen = Set(String).new
      pending = tcb_libraries.to_a
      while library = pending.pop?
        next unless seen.add?(library)
        if expansion = tcb_styles[library]?
          pending.concat(expansion)
        elsif !Scanner::TCB_STYLE_NAMES.includes?(library)
          result << "tcb#{library}.code.tex"
        end
      end
      result
    end
  end

  # Statically scans .tex sources for the packages, classes and fonts they pull in,
  # following local \input / \include / \subfile chains and local .sty/.cls files.
  module Scanner
    extend self

    OPT = %q{(?:\s*\[[^\]]*\])*\s*}

    # A local file referenced by the document that is not TeX source.
    record AssetRef, name : String, dir : Path?, graphic : Bool = false

    GRAPHIC_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".eps", ".jbig2", ".jb2"}

    MAGIC_PROGRAM = /%\s*!\s*TEX\s+(?:TS-)?program\s*=\s*([A-Za-z]+)/i
    PACKAGES      = Regex.new(%q{\\(?:usepackage|RequirePackage|RequirePackageWithOptions)} + OPT + %q<\{([^}]*)\}>)
    CLASSES       = Regex.new(%q{\\(?:documentclass|LoadClass|LoadClassWithOptions)} + OPT + %q<\{([^}]*)\}>)
    THEMES        = Regex.new(%q{\\use(|color|font|inner|outer)theme} + OPT + %q<\{([^}]*)\}>)
    TIKZ_LIBS     = /\\usetikzlibrary\s*\{([^}]*)\}/
    PGF_LIBS      = /\\usepgflibrary\s*\{([^}]*)\}/
    PGFPLOTS_LIBS = /\\usepgfplotslibrary\s*\{([^}]*)\}/
    TCB_LIBS      = /\\tcbuselibrary\s*\{([^}]*)\}/
    TCB_PACKAGE   = /\\(?:usepackage|RequirePackage)\s*\[([^\]]*)\]\s*\{tcolorbox\}/
    TCB_STYLE     = /\\tcb@add@library@style\s*\{([^}]*)\}\s*\{([^}]*)\}/
    INPUTS        = /\\(?:input|include|subfile)\s*\{([^}]*)\}/
    OPTIONAL      = /\\InputIfFileExists\s*\{([^}]*)\}/
    IMPORTS       = /\\(?:sub)?import\*?\s*\{([^}]*)\}\s*\{([^}]*)\}/
    BARE_INPUT    = /\\input\s+([A-Za-z0-9_\-.\/]+)/
    BIB_STYLE     = /\\bibliographystyle\s*\{([^}]*)\}/
    FONT_SETTERS  = Regex.new(%q{\\(?:setmainfont|setsansfont|setmonofont|setmathfont|fontspec|newfontfamily\s*\\[A-Za-z@]+|newfontface\s*\\[A-Za-z@]+)} + OPT + %q<\{([^}]*)\}>)
    LUA_MARKERS   = /\\directlua|\\begin\{luacode\*?\}|\\luaexec/
    BABEL         = /\\usepackage\s*\[([^\]]*)\]\s*\{babel\}/
    GRAPHICS      = Regex.new(%q{\\includegraphics\*?} + OPT + %q<\{([^}]*)\}>)
    GRAPHICS_PATH = /\\graphicspath\s*\{((?:\s*\{[^}]*\})+)\s*\}/
    BIBLIOGRAPHY  = /\\bibliography\s*\{([^}]*)\}/
    BIB_RESOURCE  = Regex.new(%q{\\addbibresource} + OPT + %q<\{([^}]*)\}>)
    LISTING_INPUT = Regex.new(%q{\\(?:lstinputlisting|verbatiminput|VerbatimInput)} + OPT + %q<\{([^}]*)\}>)
    MINTED_INPUT  = Regex.new(%q{\\inputminted} + OPT + %q<\{[^}]*\}\s*\{([^}]*)\}>)

    # babel package options that are not language names.
    # tcolorbox library styles; their expansion is read from tcolorbox.sty.
    TCB_STYLE_NAMES = {"most", "many", "all"}

    BABEL_FLAGS = {"activeacute", "activegrave", "base", "bidi", "config", "hyphenmap", "keepshorthandsactive",
                   "layout", "math", "noconfigs", "nocase", "provide", "safe", "shorthands", "showlanguages",
                   "silent", "strings", "headfoot"}

    def scan(path : Path | String) : ScanResult
      result = ScanResult.new
      main = Path[path].expand
      raise Error.new("no such file: #{main}") unless File.file?(main)
      visit(main, main.parent, result, Set(String).new)
      resolve_assets(result, main.parent)
      result
    end

    # Scans TeX source text (comments are stripped first). Exposed for testing.
    #
    # With `top_level_only`, commands nested inside `{...}` are ignored. Package
    # code wraps conditional loads in braces (`\gdef\x{\RequirePackage{...}}`,
    # `\IfPackageLoadedTF{...}{...}`), while unconditional ones sit at the top.
    def scan_source(text : String, result : ScanResult = ScanResult.new, top_level_only : Bool = false,
                    &local : String -> Path?) : ScanResult
      if result.engine.nil? && (magic = text.match(MAGIC_PROGRAM))
        result.engine = magic[1].downcase
      end
      code = strip_comments(text)
      depths = top_level_only ? brace_depths(code) : nil
      keep = ->(match : Regex::MatchData) { depths.nil? || depths[match.begin]? == 0 }

      each_name(code, PACKAGES, keep) do |name|
        result.needs_unicode = true if Config::XETEX_TRIGGERS.includes?(name)
        result.needs_lua = true if name.starts_with?("luatex") || name == "luacode"
        request(result, "#{name}.sty", &local)
      end
      each_name(code, CLASSES, keep) { |name| request(result, "#{name}.cls", &local) }
      code.scan(THEMES) do |match|
        next unless keep.call(match)
        split_names(match[2]).each { |name| request(result, "beamer#{match[1]}theme#{name}.sty", &local) }
      end
      each_name(code, TIKZ_LIBS, keep) { |name| result.files << "tikzlibrary#{name}.code.tex" }
      each_name(code, PGF_LIBS, keep) { |name| result.files << "pgflibrary#{name}.code.tex" }
      each_name(code, PGFPLOTS_LIBS, keep) { |name| result.files << "pgfplotslibrary#{name}.code.tex" }
      each_name(code, TCB_LIBS, keep) { |name| result.tcb_libraries << name }
      code.scan(TCB_PACKAGE) do |match|
        next unless keep.call(match)
        split_names(match[1]).each { |name| result.tcb_libraries << name unless name.includes?('=') }
      end
      code.scan(TCB_STYLE) { |match| result.tcb_styles[match[1].strip] = split_names(match[2]) }
      each_name(code, BIB_STYLE, keep) { |name| result.files << "#{name}.bst" }
      each_name(code, FONT_SETTERS, keep) { |name| result.fonts << name }
      code.scan(BABEL) do |match|
        next unless keep.call(match)
        babel_languages(match[1]).each { |lang| result.files << "#{lang}.ldf" }
      end
      result.needs_lua = true if code.matches?(LUA_MARKERS)
      scan_assets(code, result, keep)

      inputs = [] of String
      code.scan(INPUTS) { |match| inputs << match[1].strip if keep.call(match) }
      code.scan(BARE_INPUT) { |match| inputs << match[1] if keep.call(match) }
      code.scan(IMPORTS) { |match| inputs << File.join(match[1].strip, match[2].strip) if keep.call(match) }
      inputs.each do |name|
        next if name.empty? || name.includes?('\\') || name.includes?('#')
        candidates = File.extname(name).empty? ? ["#{name}.tex", name] : [name]
        unless candidates.any? { |candidate| local.call(candidate) }
          result.files << candidates.first
        end
      end
      # \InputIfFileExists is optional by definition: follow local files only.
      code.scan(OPTIONAL) do |match|
        name = match[1].strip
        local.call(name) unless name.empty? || name.includes?('\\')
      end
      result.files.concat(result.tcb_library_files)
      result
    end

    private def scan_assets(code : String, result : ScanResult, keep : Regex::MatchData -> Bool) : Nil
      dir = result.current_dir
      code.scan(GRAPHICS_PATH) do |match|
        match[1].scan(/\{([^}]*)\}/) { |path| result.graphics_paths << path[1].strip }
      end
      code.scan(GRAPHICS) do |match|
        name = match[1].strip
        result.asset_refs << AssetRef.new(name, dir, graphic: true) if keep.call(match) && plain?(name)
      end
      code.scan(BIBLIOGRAPHY) do |match|
        next unless keep.call(match)
        split_names(match[1]).each do |name|
          result.asset_refs << AssetRef.new(name.ends_with?(".bib") ? name : "#{name}.bib", dir)
        end
      end
      {BIB_RESOURCE, LISTING_INPUT, MINTED_INPUT}.each do |pattern|
        code.scan(pattern) do |match|
          name = match[1].strip
          result.asset_refs << AssetRef.new(name, dir) if keep.call(match) && plain?(name)
        end
      end
    end

    # Resolves asset references the way LaTeX would: relative to the including
    # file, then the project root, then every \graphicspath entry for graphics.
    def resolve_assets(result : ScanResult, root : Path) : Nil
      result.asset_refs.each do |ref|
        bases = [ref.dir, root].compact.uniq
        if ref.graphic
          bases += result.graphics_paths.flat_map { |prefix| [ref.dir, root].compact.map(&.join(prefix)) }
        end
        names = ref.graphic && File.extname(ref.name).empty? ? GRAPHIC_EXTENSIONS.map { |ext| ref.name + ext } : [ref.name]
        if (found = first_file(bases.uniq, names)) && !result.assets.includes?(found)
          result.assets << found
        end
      end
    end

    private def first_file(bases : Array(Path), names : Enumerable(String)) : Path?
      bases.each do |base|
        names.each do |name|
          path = Path[name].absolute? ? Path[name] : base.join(name).expand
          return path if File.file?(path)
        end
      end
      nil
    end

    private def plain?(name : String) : Bool
      !name.empty? && !name.includes?('\\') && !name.includes?('#')
    end

    # Brace nesting depth at every character (escaped braces do not count).
    def brace_depths(code : String) : Array(Int32)
      depths = Array(Int32).new(code.size, 0)
      depth = 0
      escaped = false
      code.each_char_with_index do |char, index|
        if escaped
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif char == '{'
          depth += 1
        elsif char == '}'
          depth = Math.max(depth - 1, 0)
        end
        # A command's own argument opens after it, so a match starts at its depth.
        depths[index] = char == '{' ? depth - 1 : depth
      end
      depths
    end

    # Removes `%` comments while keeping escaped `\%`.
    def strip_comments(text : String) : String
      String.build do |io|
        text.each_line(chomp: false) do |line|
          cut = nil
          index = 0
          while index < line.size
            char = line[index]
            if char == '\\'
              index += 2
              next
            elsif char == '%'
              cut = index
              break
            end
            index += 1
          end
          if cut
            io << line[0, cut] << '\n'
          else
            io << line
          end
        end
      end
    end

    private def visit(file : Path, root : Path, result : ScanResult, seen : Set(String)) : Nil
      return unless seen.add?(file.to_s)
      result.sources << file
      result.current_dir = file.parent
      text = File.read(file).scrub
      followups = [] of Path
      scan_source(text, result) do |name|
        candidate = resolve_local(name, file.parent, root)
        followups << candidate if candidate
        candidate
      end
      followups.each { |child| visit(child, root, result, seen) }
    end

    # Local inputs resolve against the including file's directory, then the
    # project root (LaTeX resolves against the working directory).
    private def resolve_local(name : String, dir : Path, root : Path) : Path?
      {dir, root}.each do |base|
        candidate = Path[name].absolute? ? Path[name] : base.join(name).expand
        return candidate if File.file?(candidate)
      end
      nil
    end

    private def request(result : ScanResult, file : String, &local : String -> Path?) : Nil
      result.files << file unless local.call(file)
    end

    private def each_name(code : String, pattern : Regex, keep : Regex::MatchData -> Bool, & : String ->) : Nil
      code.scan(pattern) do |match|
        next unless keep.call(match)
        split_names(match[1]).each { |name| yield name }
      end
    end

    # Language names from babel's options: `turkish`, or `main=turkish`.
    def babel_languages(options : String) : Array(String)
      options.split(',').compact_map do |option|
        key, eq, value = option.strip.partition('=')
        name = eq.empty? ? key : (key.strip == "main" ? value.strip : nil)
        next unless name && name.matches?(/\A[A-Za-z]+\z/)
        next if BABEL_FLAGS.includes?(name.downcase)
        name
      end
    end

    private def split_names(list : String) : Array(String)
      list.split(',').map(&.strip).reject { |name| name.empty? || name.includes?('\\') || name.includes?('#') }
    end
  end
end

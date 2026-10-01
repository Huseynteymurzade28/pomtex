require "../config"

module Pomtex::Seed
  # What a document needs before it can be compiled.
  class ScanResult
    getter files = Set(String).new  # TeX-side files: foo.sty, bar.cls, tikzlibraryx.code.tex, ...
    getter fonts = Set(String).new  # fontspec font names
    getter sources = [] of Path     # local files that were scanned
    property engine : String? = nil # explicit `% !TEX program = ...`
    property needs_unicode = false  # fontspec & friends
    property needs_lua = false      # \directlua, luacode, ...

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
  end

  # Statically scans .tex sources for the packages, classes and fonts they pull in,
  # following local \input / \include / \subfile chains and local .sty/.cls files.
  module Scanner
    extend self

    OPT = %q{(?:\s*\[[^\]]*\])*\s*}

    MAGIC_PROGRAM = /%\s*!\s*TEX\s+(?:TS-)?program\s*=\s*([A-Za-z]+)/i
    PACKAGES      = Regex.new(%q{\\(?:usepackage|RequirePackage|RequirePackageWithOptions)} + OPT + %q<\{([^}]*)\}>)
    CLASSES       = Regex.new(%q{\\(?:documentclass|LoadClass|LoadClassWithOptions)} + OPT + %q<\{([^}]*)\}>)
    THEMES        = Regex.new(%q{\\use(|color|font|inner|outer)theme} + OPT + %q<\{([^}]*)\}>)
    TIKZ_LIBS     = /\\usetikzlibrary\s*\{([^}]*)\}/
    PGF_LIBS      = /\\usepgflibrary\s*\{([^}]*)\}/
    PGFPLOTS_LIBS = /\\usepgfplotslibrary\s*\{([^}]*)\}/
    TCB_LIBS      = /\\tcbuselibrary\s*\{([^}]*)\}/
    INPUTS        = /\\(?:input|include|subfile|InputIfFileExists)\s*\{([^}]*)\}/
    IMPORTS       = /\\(?:sub)?import\*?\s*\{([^}]*)\}\s*\{([^}]*)\}/
    BARE_INPUT    = /\\input\s+([A-Za-z0-9_\-.\/]+)/
    BIB_STYLE     = /\\bibliographystyle\s*\{([^}]*)\}/
    FONT_SETTERS  = Regex.new(%q{\\(?:setmainfont|setsansfont|setmonofont|setmathfont|fontspec|newfontfamily\s*\\[A-Za-z@]+|newfontface\s*\\[A-Za-z@]+)} + OPT + %q<\{([^}]*)\}>)
    LUA_MARKERS   = /\\directlua|\\begin\{luacode\*?\}|\\luaexec/
    BABEL         = /\\usepackage\s*\[([^\]]*)\]\s*\{babel\}/

    # babel package options that are not language names.
    BABEL_FLAGS = {"activeacute", "activegrave", "base", "bidi", "config", "hyphenmap", "keepshorthandsactive",
                   "layout", "math", "noconfigs", "nocase", "provide", "safe", "shorthands", "showlanguages",
                   "silent", "strings", "headfoot"}

    def scan(path : Path | String) : ScanResult
      result = ScanResult.new
      main = Path[path].expand
      raise Error.new("no such file: #{main}") unless File.file?(main)
      visit(main, main.parent, result, Set(String).new)
      result
    end

    # Scans TeX source text (comments are stripped first). Exposed for testing.
    def scan_source(text : String, result : ScanResult = ScanResult.new, &local : String -> Path?) : ScanResult
      if result.engine.nil? && (magic = text.match(MAGIC_PROGRAM))
        result.engine = magic[1].downcase
      end
      code = strip_comments(text)

      each_name(code, PACKAGES) do |name|
        result.needs_unicode = true if Config::XETEX_TRIGGERS.includes?(name)
        result.needs_lua = true if name.starts_with?("luatex") || name == "luacode"
        request(result, "#{name}.sty", &local)
      end
      each_name(code, CLASSES) { |name| request(result, "#{name}.cls", &local) }
      code.scan(THEMES) do |match|
        split_names(match[2]).each { |name| request(result, "beamer#{match[1]}theme#{name}.sty", &local) }
      end
      each_name(code, TIKZ_LIBS) { |name| result.files << "tikzlibrary#{name}.code.tex" }
      each_name(code, PGF_LIBS) { |name| result.files << "pgflibrary#{name}.code.tex" }
      each_name(code, PGFPLOTS_LIBS) { |name| result.files << "pgfplotslibrary#{name}.code.tex" }
      each_name(code, TCB_LIBS) { |name| result.files << "tcb#{name}.code.tex" unless {"most", "all", "many"}.includes?(name) }
      each_name(code, BIB_STYLE) { |name| result.files << "#{name}.bst" }
      each_name(code, FONT_SETTERS) { |name| result.fonts << name }
      code.scan(BABEL) { |match| babel_languages(match[1]).each { |lang| result.files << "#{lang}.ldf" } }
      result.needs_lua = true if code.matches?(LUA_MARKERS)

      inputs = [] of String
      code.scan(INPUTS) { |match| inputs << match[1].strip }
      code.scan(BARE_INPUT) { |match| inputs << match[1] }
      code.scan(IMPORTS) { |match| inputs << File.join(match[1].strip, match[2].strip) }
      inputs.each do |name|
        next if name.empty? || name.includes?('\\') || name.includes?('#')
        candidates = File.extname(name).empty? ? ["#{name}.tex", name] : [name]
        unless candidates.any? { |candidate| local.call(candidate) }
          result.files << candidates.first
        end
      end
      result
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
        candidate = base.join(name).expand
        return candidate if File.file?(candidate)
      end
      nil
    end

    private def request(result : ScanResult, file : String, &local : String -> Path?) : Nil
      result.files << file unless local.call(file)
    end

    private def each_name(code : String, pattern : Regex, & : String ->) : Nil
      code.scan(pattern) { |match| split_names(match[1]).each { |name| yield name } }
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

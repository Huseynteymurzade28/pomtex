require "../config"
require "../core/detector"
require "../seed/resolver"
require "../seed/aril_fetcher"
require "./runner"
require "./bibliography"
require "../seed/font_info"
require "../core/cache_lock"

module Pomtex::Engine
  # Compiles a document, intercepting "file not found" failures on the fly:
  # missing files are resolved to arils, fetched, and the run is retried.
  # Raised in --offline mode when the document needs arils that are not planted.
  class OfflineMissing < Error
    getter packages : Array(String)

    def initialize(@packages)
      super("offline: missing #{packages.join(", ")} (run without --offline to install)")
    end
  end

  class RuntimeGuard
    record Missing, kind : Kind, name : String do
      enum Kind
        File
        Font
        Type1
      end
    end

    MISSING_FILE   = /LaTeX Error: File [`'"]([^'"`]+)' not found/
    CANT_FIND_FILE = /I can't find file [`'"]([^'"`]+)'/
    MISSING_TFM    = /Font \\?[^=\s]+=([A-Za-z0-9_\-]+)(?:\s+at\s+[\d.]+pt)?\s+not loadable: Metric \(TFM\) file/
    MKTEXTFM       = /kpathsea: Running mktextfm ([A-Za-z0-9_\-]+)/
    MISSING_ENC    = /\(file ([^()\s]+\.enc)\): cannot open encoding file/
    MISSING_MAP    = /\(file ([^()\s]+\.map)\)/
    MISSING_TYPE1  = /\(file ([^()\s]+\.pf[ab])\): cannot open Type 1 font file/
    # No map entry and no PK bitmap: pdfTeX gave up on the font entirely.
    PK_FONT        = /\(file [^()\s]+\): Font ([A-Za-z0-9_\-]+) at \d+ not found/
    FONTSPEC_FONT  = /The font "([^"]+)" cannot be found/
    BABEL_LANGUAGE = /Package babel Error: Unknown option [`'"]([A-Za-z]+)'/
    RERUN          = /Rerun to get|Label\(s\) may have changed|Please \(?re\)?run LaTeX|\(rerunfilecheck\).*Rerun|Please rerun/

    # Extracts everything the log says is missing. Exposed for testing.
    def self.missing_from_log(log : String) : Array(Missing)
      found = [] of Missing
      log.scan(MISSING_FILE) { |m| found << Missing.new(Missing::Kind::File, m[1]) }
      log.scan(CANT_FIND_FILE) { |m| found << Missing.new(Missing::Kind::File, m[1]) }
      log.scan(MISSING_TFM) { |m| found << Missing.new(Missing::Kind::File, "#{m[1]}.tfm") }
      log.scan(MKTEXTFM) { |m| found << Missing.new(Missing::Kind::File, "#{m[1]}.tfm") }
      log.scan(MISSING_ENC) { |m| found << Missing.new(Missing::Kind::File, File.basename(m[1])) }
      log.scan(MISSING_TYPE1) { |m| found << Missing.new(Missing::Kind::File, File.basename(m[1])) }
      log.scan(PK_FONT) { |m| found << Missing.new(Missing::Kind::Type1, m[1]) }
      log.each_line do |line|
        next unless line.includes?("cannot open") && line.includes?("map file")
        if m = line.match(MISSING_MAP)
          found << Missing.new(Missing::Kind::File, File.basename(m[1]))
        end
      end
      log.scan(FONTSPEC_FONT) { |m| found << Missing.new(Missing::Kind::Font, m[1]) }
      # babel reports a missing language definition as an unknown option.
      log.scan(BABEL_LANGUAGE) { |m| found << Missing.new(Missing::Kind::File, "#{m[1]}.ldf") }
      found.uniq
    end

    # The Type 1 file a font map assigns to `font` (`ptmr8r Times-Roman "..." <8r.enc <utmr8a.pfb`).
    def self.type1_file(font : String, map : String) : String?
      map.each_line do |line|
        fields = line.split
        next unless fields.first? == font
        fields.each do |field|
          name = field.lchop('<').lchop('<').lchop('[')
          return name if name.ends_with?(".pfb") || name.ends_with?(".pfa")
        end
      end
      nil
    end

    def self.rerun_needed?(log : String) : Bool
      log.matches?(RERUN)
    end

    # The first error and its context, for display after a failed run.
    def self.error_excerpt(log : String, lines : Int32 = 12) : String
      all = log.lines
      start = all.index { |line| line.starts_with?('!') || line.matches?(/^[^:\s]+:\d+: /) }
      excerpt = start ? all[start, lines] : all.last(lines)
      excerpt.map { |line| line.rstrip.size > 160 ? "#{line.rstrip[0, 160]}…" : line.rstrip }.join('\n')
    end

    getter toolchain : Core::Toolchain
    property offline = false
    property jobs = Config::DEFAULT_JOBS
    @resolver : Seed::Resolver? = nil

    def initialize(@toolchain)
    end

    def environment : Hash(String, String)
      Runner.environment(toolchain)
    end

    def resolver : Seed::Resolver
      @resolver ||= Seed::Resolver.open(offline: offline)
    end

    # Compiles `runner`'s document. Returns the final result (successful or not).
    #
    # The whole compile holds a shared cache lock, so `pomtex clean` in another
    # terminal cannot remove files mid-build; fetches upgrade it to exclusive.
    def compile(runner : Runner, scan : Seed::ScanResult? = nil, stream : Bool = false) : Runner::Result
      Core::CacheLock.shared { compile_locked(runner, scan, stream) }
    end

    private def compile_locked(runner : Runner, scan : Seed::ScanResult?, stream : Bool) : Runner::Result
      prepare(scan) if scan
      result = compile_rounds(runner, stream)
      font_hints(result.log, scan.try(&.sources) || [runner.source]) unless result.success
      result
    end

    # fontspec selects fonts by family name, which can differ from the file
    # name pomtex resolved: "Inconsolata" lives in Inconsolatazi4-Regular.otf,
    # whose family is "Inconsolatazi4". Name the families that do exist.
    def font_hints(log : String, sources : Array(Path)) : Nil
      requested = log.scan(FONTSPEC_FONT).map(&.[1]).uniq
      return if requested.empty? || !resolver.available?
      env = environment
      requested.each do |name|
        candidates = resolver.font_candidates(name).first(12)
        paths = toolchain.lookup(candidates, env)
        families = candidates.compact_map { |file| paths[file]?.try { |path| Seed::FontInfo.family(path) } }.uniq
        # Spaces matter to XeTeX ("SourceCodePro" is not "Source Code Pro"); case does not.
        families.reject! { |family| family.downcase == name.strip.downcase }
        next if families.empty?
        suggestions = families.map(&.inspect).join(" or ")
        UI.warn "no font family is called #{name.inspect}; the installed files provide #{suggestions}. " \
                "Use that name, e.g. #{font_command(sources, name)}{#{families.first}}"
      end
    end

    # The command in the user's sources that asked for the font. The log can't
    # tell: fontspec loads fonts at \begin{document}.
    def self.font_command(sources : Enumerable(String), name : String) : String
      pattern = /(\\(?:set(?:main|sans|mono|math)font|fontspec|new(?:fontfamily|fontface)\s*\\[A-Za-z@]+))\s*(?:\[[^\]]*\])?\s*\{\s*#{Regex.escape(name)}\s*\}/
      sources.each do |text|
        if match = text.match(pattern)
          return match[1]
        end
      end
      "\\setmainfont"
    end

    private def font_command(sources : Array(Path), name : String) : String
      self.class.font_command(sources.compact_map { |path| File.read(path).scrub rescue nil }, name)
    end

    private def compile_rounds(runner : Runner, stream : Bool) : Runner::Result
      attempted = Set(Missing).new
      passes = 0
      rounds = 0
      bibliography_runs = 0
      loop do
        runner.map_files = Seed::Manifest.map_files
        result = runner.run(stream)
        missing = self.class.missing_from_log(result.log).reject { |item| attempted.includes?(item) }

        if result.success && missing.empty?
          if bibliography_runs < Config::MAX_BIBLIOGRAPHY_RUNS && (tool = Bibliography.pending(runner, result.log))
            bibliography_runs += 1
            next if run_bibliography(tool, runner)
          end
          if self.class.rerun_needed?(result.log) && passes < Config::MAX_RERUN_PASSES
            passes += 1
            UI.info "rerunning for cross-references (pass #{passes + 1})"
            next
          end
          return result
        end

        if missing.empty? || rounds >= Config::MAX_GUARD_ROUNDS
          return result
        end

        rounds += 1
        missing.each { |item| attempted << item }
        UI.step "Runtime guard caught #{missing.map(&.name).join(", ")}"
        files = missing.select(&.kind.file?).map(&.name)
        fonts = missing.select(&.kind.font?).map(&.name)
        files.concat(type1_files(missing.select(&.kind.type1?).map(&.name), runner.map_files))
        planted = provision(files, fonts)
        # Nothing new could be planted: retrying would fail the same way.
        return result if planted == 0
      end
    end

    # The outline files behind fonts pdfTeX could not embed: whatever the loaded
    # maps name, else `<font>.pfb`, the usual name for fonts without a map entry.
    private def type1_files(fonts : Array(String), map_files : Array(String)) : Array(String)
      return [] of String if fonts.empty?
      maps = toolchain.lookup(["pdftex.map"] + map_files, environment).values
        .compact_map { |path| File.read(path).scrub rescue nil }
      fonts.map do |font|
        maps.compact_map { |map| self.class.type1_file(font, map) }.first? || "#{font}.pfb"
      end
    end

    # Runs BibTeX/Biber. Returns true when the engine should run again.
    private def run_bibliography(tool : Bibliography::Tool, runner : Runner) : Bool
      executable = tool_path(tool.command)
      unless executable
        UI.warn "#{tool.command} is not available; citations will be missing"
        return false
      end
      UI.step "Running #{tool.command}"
      started = Pomtex.clock
      outcome = Bibliography.run(tool, executable, runner)

      # A missing .bst is just another aril: plant it and try once more.
      styles = tool.bibtex? && !outcome.success ? Bibliography.missing_styles(outcome.log) : [] of String
      if !styles.empty? && provision(styles) > 0
        outcome = Bibliography.run(tool, executable, runner)
      end

      if outcome.success
        UI.ok "#{tool.command} in #{UI.duration(Pomtex.clock - started)}"
      else
        UI.warn "#{tool.command} failed; citations may be missing\n#{Bibliography.error_excerpt(outcome.log).gsub(/^/m, "    ")}"
      end
      outcome.success
    end

    # Finds a helper program such as biber, planting its binary aril if needed.
    # With the rind, a biber from $PATH is not trusted: biber must match the
    # biblatex version, and the planted one comes from the same TeX Live release.
    def tool_path(name : String) : String?
      if found = toolchain.executable(name)
        return found
      end
      planted = Config.aril_bin_dir.join(name)
      return planted.to_s if File::Info.executable?(planted)
      if toolchain.origin.system? && (found = Process.find_executable(name))
        return found
      end

      package = resolver.package("#{name}.#{Config::PLATFORM}")
      return nil unless package
      raise OfflineMissing.new([package.name]) if offline
      fetch([package])
      File::Info.executable?(planted) ? planted.to_s : nil
    end

    # Provisions what the document asks for, then follows the load graph through
    # the arils pomtex planted: their own \RequirePackage, \input, \tcbuselibrary,
    # ... are fetched in batches before the first engine run. TeX Live's dependency
    # metadata misses these (e.g. tcolorbox's `skins` library needs tikzfill), and
    # with -halt-on-error each one would otherwise cost a full compile.
    #
    # Only aril files are scanned: the rind and system TeX ship complete dependency
    # sets, and following their conditional loads would over-fetch.
    def prepare(scan : Seed::ScanResult) : Int32
      planted = provision(scan.files, scan.fonts)

      graph = Seed::ScanResult.new
      graph.files.concat(scan.files)
      graph.tcb_libraries.concat(scan.tcb_libraries)
      scanned = Set(String).new
      env = environment

      Config::MAX_PREFETCH_ROUNDS.times do
        pending = graph.files.reject { |file| scanned.includes?(file) }
        break if pending.empty?
        pending.each { |file| scanned << file }

        before = graph.files.dup
        fonts_before = graph.fonts.dup
        toolchain.lookup(pending, env).each_value do |path|
          next unless aril_file?(path)
          text = File.read(path).scrub rescue next
          Seed::Scanner.scan_source(text, graph, top_level_only: true) { nil }
        end
        # tcolorbox styles may only now be known; expand them for every request.
        graph.files.concat(graph.tcb_library_files)

        discovered = graph.files - before
        new_fonts = graph.fonts - fonts_before
        break if discovered.empty? && new_fonts.empty?
        UI.debug "load graph: #{discovered.to_a.sort.join(", ")}"
        planted += provision(discovered, new_fonts, warn_unknown: false)
      end
      planted
    end

    private def aril_file?(path : String) : Bool
      root = (@aril_root ||= File.realpath(Config.texmf_dir) rescue Config.texmf_dir.to_s)
      path.starts_with?(root + "/")
    end

    @aril_root : String? = nil

    # Makes `files` (and fonts) visible to kpathsea, fetching arils for whatever
    # is missing. Returns the number of arils planted.
    def provision(files : Enumerable(String), fonts : Enumerable(String) = [] of String,
                  warn_unknown : Bool = true) : Int32
      env = environment
      wanted = files.to_a.uniq
      font_names = fonts.to_a.uniq
      return 0 if wanted.empty? && font_names.empty?

      present = toolchain.locate(wanted + wanted.flat_map { |file| Seed::Resolver.alternates(file) }, env)
      absent = wanted.reject do |file|
        present.includes?(file) || Seed::Resolver.alternates(file).any? { |alt| present.includes?(alt) }
      end
      unless font_names.empty?
        # Fonts available via fontconfig are fine for XeTeX; we only fill gaps from CTAN.
        font_names.each do |font|
          if file = resolver.font_file(font)
            absent << file unless toolchain.locate([file], env).includes?(file)
          else
            UI.debug "no aril ships a font named #{font.inspect}"
          end
        end
      end
      return 0 if absent.empty?

      roots = [] of String
      absent.each do |file|
        if pkg = resolver.package_for(file)
          roots << pkg
          UI.debug "#{file} → #{pkg}"
        elsif warn_unknown
          UI.warn "no aril provides #{file}#{resolver.available? ? "" : " (index unavailable)"}"
        else
          UI.debug "no aril provides #{file} (optional or engine-specific)"
        end
      end
      return 0 if roots.empty?

      plan = plan(roots.uniq, env)
      return 0 if plan.empty?

      # Offline, a missing package is final: stop before running the engine
      # rather than letting it fail on the same file.
      raise OfflineMissing.new(plan.map(&.name)) if offline
      fetch(plan)
    end

    # Roots are known missing; dependencies are probed by kpathsea, layer by layer.
    def plan(roots : Array(String), env : Hash(String, String) = environment) : Array(Seed::Package)
      first = true
      resolver.closure(roots) do |layer|
        if first
          first = false
          next layer.reject { |pkg| Seed::Manifest.installed?(pkg.name) }
        end
        candidates = layer.reject { |pkg| pkg.probe.nil? || Seed::Manifest.installed?(pkg.name) }
        seen = toolchain.locate(candidates.compact_map(&.probe), env)
        candidates.reject { |pkg| seen.includes?(pkg.probe.not_nil!) }
      end
    end

    def fetch(plan : Array(Seed::Package)) : Int32
      Core::CacheLock.exclusive do
        # Another process may have planted some of these while we waited.
        todo = plan.reject { |pkg| Seed::Manifest.installed?(pkg.name) }
        if todo.size < plan.size
          UI.info "already planted by another process: #{(plan - todo).map(&.name).join(", ")}"
        end
        todo.empty? ? 0 : fetch_unlocked(todo)
      end
    end

    private def fetch_unlocked(plan : Array(Seed::Package)) : Int32
      total = plan.sum(&.size)
      UI.step "Fetching #{plan.size} aril#{plan.size == 1 ? "" : "s"} (#{UI.bytes(total)}) with #{Math.min(jobs, plan.size)} fibers"
      started = Pomtex.clock
      fetcher = Seed::ArilFetcher.new(jobs)
      outcomes = fetcher.fetch_all(plan) { |outcome| report(outcome) }

      # Checksum mismatches mean tlnet moved on: refresh the index once and retry.
      stale = outcomes.select { |outcome| outcome.error.try(&.includes?("checksum mismatch")) }
      unless stale.empty?
        UI.info "package index is stale; refreshing"
        @resolver = Seed::Resolver.new(Seed::Resolver.rebuild_index)
        retry = stale.compact_map { |outcome| resolver.package(outcome.package.name) }
        outcomes = outcomes.reject { |outcome| stale.includes?(outcome) } +
                   fetcher.fetch_all(retry) { |outcome| report(outcome) }
      end

      planted = 0
      outcomes.each do |outcome|
        next unless outcome.ok?
        Seed::Manifest.record(outcome.package.name, outcome.package.maps, outcome.files)
        planted += 1
      end
      UI.ok "#{planted}/#{plan.size} planted in #{UI.duration(Pomtex.clock - started)}"
      planted
    end

    private def report(outcome : Seed::ArilFetcher::Outcome) : Nil
      if error = outcome.error
        UI.error "#{outcome.package.name}: #{error}"
      else
        UI.ok "#{outcome.package.name.ljust(22)} #{UI.bytes(outcome.package.size).rjust(10)}  #{UI.duration(outcome.elapsed)}"
      end
    end
  end
end

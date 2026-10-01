require "option_parser"
require "file_utils"
require "./config"
require "./ui"
require "./core/detector"
require "./core/bootstrap"
require "./core/cache_lock"
require "./core/update_check"
require "./seed/scanner"
require "./seed/resolver"
require "./seed/aril_fetcher"
require "./seed/extractor"
require "./engine/runner"
require "./engine/runtime_guard"
require "./watcher/live_pulse"

module Pomtex
  class CLI
    USAGE = <<-TEXT
      pomtex #{VERSION} — the pomegranate TeX engine: a featherlight rind, arils on demand.

      Usage:
        pomtex build <file.tex>        compile, fetching missing packages on the fly
        pomtex watch <file.tex>        rebuild whenever the document (or its inputs) change
        pomtex scan <file.tex>         list what a document needs and what is missing
        pomtex fetch <pkg|file>...     plant arils explicitly (e.g. `pgf`, `tikz-cd.sty`)
        pomtex bootstrap [--force]     download the portable TeX kernel (the rind)
        pomtex index [--refresh]       build/refresh the CTAN file → package index
        pomtex list                    show planted arils
        pomtex remove <aril>...        uproot arils
        pomtex clean [--all]           remove all arils (and with --all the rind and index)
        pomtex doctor                  report what pomtex sees on this machine

      Options:
      TEXT

    COMMANDS = {"build", "watch", "scan", "fetch", "bootstrap", "index", "list", "remove", "clean", "doctor"}

    property command = ""
    property engine : String? = nil
    property outdir : String? = nil
    property jobs = Config::DEFAULT_JOBS
    property offline = false
    property prefer_rind = false
    property stream = false
    property force = false
    property refresh = false
    property all = false
    property debounce = Config::DEFAULT_DEBOUNCE
    property args = [] of String
    @recorded = [] of Path

    def run(argv : Array(String)) : Int32
      UI.setup
      parser = build_parser
      argv = argv.dup
      self.command = argv.shift if COMMANDS.includes?(argv.first?)
      parser.parse(argv)
      self.args = args.reject(&.empty?)

      case command
      when "build"     then build_command
      when "watch"     then watch_command
      when "scan"      then scan_command
      when "fetch"     then fetch_command
      when "bootstrap" then bootstrap_command
      when "index"     then index_command
      when "list"      then list_command
      when "remove"    then remove_command
      when "clean"     then clean_command
      when "doctor"    then doctor_command
      when ""
        if (first = args.first?) && first.ends_with?(".tex")
          build_command
        else
          puts parser
          args.empty? ? 0 : 2
        end
      else
        UI.error "unknown command: #{command}"
        2
      end
    rescue ex : OptionParser::Exception
      UI.error ex.message || "invalid arguments"
      2
    rescue ex : Pomtex::Error
      UI.error ex.message || "failed"
      1
    rescue ex : IO::Error | Socket::Error | File::Error
      # `pomtex list | head` closes the pipe early; that is not an error.
      return 0 if ex.os_error == Errno::EPIPE
      UI.error "#{ex.class.name.split("::").last}: #{ex.message}"
      1
    end

    private def build_parser : OptionParser
      OptionParser.new do |parser|
        parser.banner = USAGE
        parser.on("-e ENGINE", "--engine=ENGINE", "pdflatex | xelatex | lualatex (default: auto-detect)") { |value| self.engine = value }
        parser.on("-o DIR", "--outdir=DIR", "Directory for the PDF and auxiliary files") { |value| self.outdir = value }
        parser.on("-j N", "--jobs=N", "Concurrent aril downloads (default: #{Config::DEFAULT_JOBS})") do |value|
          self.jobs = value.to_i? || raise OptionParser::InvalidOption.new("--jobs #{value}")
        end
        parser.on("--offline", "Never touch the network; only report what is missing") { self.offline = true }
        parser.on("--rind", "Use the pomtex rind even if a system TeX is installed") { self.prefer_rind = true }
        parser.on("--stream", "Show the engine's own output while compiling") { self.stream = true }
        parser.on("--debounce=MS", "watch: quiet period before rebuilding (default: #{Config::DEFAULT_DEBOUNCE.total_milliseconds.to_i})") do |value|
          self.debounce = (value.to_i? || raise OptionParser::InvalidOption.new("--debounce #{value}")).milliseconds
        end
        parser.on("--force", "bootstrap: download the rind again") { self.force = true }
        parser.on("--refresh", "index: rebuild the index from tlnet") { self.refresh = true }
        parser.on("--all", "clean: also remove the rind and the index") { self.all = true }
        parser.on("-v", "--verbose", "Explain every decision") { UI.verbose = true }
        parser.on("-q", "--quiet", "Only print errors") { UI.quiet = true }
        parser.on("--version", "Print the version") do
          puts "pomtex #{VERSION}"
          exit 0
        end
        parser.on("-h", "--help", "Show this help") do
          puts parser
          exit 0
        end
        parser.unknown_args { |before, after| self.args = before + after }
        parser.invalid_option { |flag| raise OptionParser::InvalidOption.new(flag) }
      end
    end

    # ── commands ────────────────────────────────────────────────────────────

    private def build_command : Int32
      file = source_argument
      compile(file) ? 0 : 1
    end

    private def watch_command : Int32
      file = source_argument
      Signal::INT.trap do
        STDERR.puts
        UI.info "stopped watching"
        exit 0
      end
      Watcher::LivePulse.new(debounce) do
        compile(file)
        watch_list(file)
      end.run
    end

    private def scan_command : Int32
      file = source_argument
      scan = Seed::Scanner.scan(file)
      toolchain = Core::Detector.detect(prefer_rind)
      present = toolchain ? toolchain.locate(scan.files, Engine::Runner.environment(toolchain)) : Set(String).new
      resolver = Seed::Resolver.open(offline: offline) rescue Seed::Resolver.new(nil)

      puts "#{File.basename(file)} → #{scan.suggested_engine}#{scan.engine ? " (magic comment)" : ""}"
      puts "sources: #{scan.sources.map { |path| Path[path].relative_to(Path[file].expand.parent) }.join(", ")}"
      scan.files.to_a.sort.each do |name|
        if !toolchain
          puts "  ? #{name}"
        elsif present.includes?(name)
          puts "  #{"✓".colorize(:green)} #{name}"
        else
          pkg = resolver.package_for(name)
          puts "  #{"✗".colorize(:red)} #{name}  #{pkg ? "→ aril #{pkg}" : "(no aril found)".colorize(:yellow)}"
        end
      end
      scan.fonts.each do |font|
        aril = resolver.font_file(font).try { |found| resolver.package_for(found) }
        puts "  font #{font.inspect}#{aril ? " → aril #{aril}" : ""}"
      end
      UI.warn "no TeX found; run `pomtex bootstrap`" unless toolchain
      0
    end

    private def fetch_command : Int32
      raise Error.new("fetch needs at least one package or file name") if args.empty?
      guard = new_guard(acquire_toolchain)
      files, packages = args.partition(&.includes?('.'))
      planted = 0
      planted += guard.provision(files) unless files.empty?
      unless packages.empty?
        unknown = packages.reject { |name| guard.resolver.package(name) } if guard.resolver.available?
        unknown.try &.each { |name| UI.warn "unknown package: #{name}" }
        plan = guard.plan(packages - (unknown || [] of String))
        if plan.empty?
          UI.ok "already present: #{packages.join(", ")}"
        elsif offline
          raise Engine::OfflineMissing.new(plan.map(&.name))
        else
          planted += guard.fetch(plan)
        end
      end
      planted >= 0 ? 0 : 1
    end

    private def bootstrap_command : Int32
      if !force && Core::Detector.rind_present?
        UI.ok "the rind is already grown at #{Config.rind_dir} (use --force to replace it)"
        return 0
      end
      Core::Bootstrap.ensure_rind(force: true)
      0
    end

    private def index_command : Int32
      resolver = refresh ? Seed::Resolver.new(Seed::Resolver.rebuild_index) : Seed::Resolver.open(offline: offline)
      if index = resolver.index
        UI.ok "#{index.packages.size} packages, #{index.files.size} files (#{Config.index_file})"
        0
      else
        UI.error "no index available"
        1
      end
    end

    private def list_command : Int32
      entries = Seed::Manifest.entries
      if entries.empty?
        UI.info "no arils planted yet"
        return 0
      end
      entries.each do |entry|
        maps = entry.maps.empty? ? "" : "  maps: #{entry.maps.join(", ")}"
        puts "#{entry.name.ljust(24)} #{entry.files.size.to_s.rjust(5)} files#{maps}"
      end
      puts "#{entries.size} arils in #{Config.texmf_dir}"
      0
    end

    private def remove_command : Int32
      raise Error.new("remove needs at least one aril name") if args.empty?
      status = 0
      args.each do |name|
        if Seed::Manifest.remove(name)
          UI.ok "uprooted #{name}"
        else
          UI.error "#{name} is not a planted aril"
          status = 1
        end
      end
      status
    end

    private def clean_command : Int32
      Core::CacheLock.exclusive do
        FileUtils.rm_rf(Config.texmf_dir)
        FileUtils.rm_rf(Config.arils_dir)
        FileUtils.rm_rf(Config.downloads_dir)
        UI.ok "removed all arils"
        if all
          Core::Bootstrap.remove
          FileUtils.rm_rf(Config.index_dir)
          UI.ok "removed the rind and the index"
        end
      end
      0
    end

    private def doctor_command : Int32
      puts "version     #{VERSION} (#{update_status})"
      puts "cache       #{Config.cache_root}"
      puts "mirror      #{Config.mirror}"
      system_tc = Core::Detector.system_toolchain
      rind_tc = Core::Detector.rind_toolchain
      puts "system TeX  #{system_tc ? "#{system_tc.bin_dir} (#{system_tc.engines.join(", ")})" : "not found"}"
      puts "rind        #{rind_tc ? "#{rind_tc.bin_dir} (#{rind_tc.engines.join(", ")})" : "not grown (pomtex bootstrap)"}"
      active = Core::Detector.detect(prefer_rind)
      puts "active      #{active || "none"}"
      if File.exists?(Config.index_file)
        age = Time.utc - File.info(Config.index_file).modification_time
        puts "index       #{UI.bytes(File.size(Config.index_file))}, #{age.days} day#{age.days == 1 ? "" : "s"} old"
      else
        puts "index       not built yet (built on first miss)"
      end
      puts "arils       #{Seed::Manifest.entries.size} planted"
      puts "xz          #{Process.find_executable("xz") || "MISSING — required to unpack arils"}"
      Process.find_executable("xz") ? 0 : 1
    end

    # ── helpers ─────────────────────────────────────────────────────────────

    private def update_status : String
      return "update check skipped: --offline" if offline
      result = Core::UpdateCheck.check
      case result.status
      when .outdated? then "#{result.latest} available, update with: #{result.hint}"
      when .current?  then "latest"
      else                 "could not check for updates"
      end
    end

    private def source_argument : String
      file = args.first? || raise Error.new("#{command.presence || "build"} needs a .tex file")
      file = "#{file}.tex" if !File.exists?(file) && File.exists?("#{file}.tex")
      raise Error.new("no such file: #{file}") unless File.file?(file)
      file
    end

    private def acquire_toolchain(engine : String? = nil) : Core::Toolchain
      toolchain = Core::Detector.detect(prefer_rind)
      toolchain = nil if toolchain && prefer_rind && toolchain.origin.system?
      if toolchain && engine && !toolchain.has_engine?(engine)
        UI.warn "#{engine} is not available in #{toolchain}; switching to the rind"
        toolchain = Core::Detector.rind_toolchain
      end
      return toolchain if toolchain
      raise Error.new("no TeX found and --offline given; run `pomtex bootstrap` first") if offline
      UI.info "no usable TeX found — growing the rind (one-time download)"
      Core::Bootstrap.ensure_rind
    end

    private def new_guard(toolchain : Core::Toolchain) : Engine::RuntimeGuard
      guard = Engine::RuntimeGuard.new(toolchain)
      guard.offline = offline
      guard.jobs = jobs
      guard
    end

    private def compile(file : String) : Bool
      scan = Seed::Scanner.scan(file)
      chosen = engine || scan.suggested_engine
      toolchain = acquire_toolchain(chosen)
      runner = Engine::Runner.new(toolchain, chosen, file, outdir)
      guard = new_guard(toolchain)

      UI.step "Compiling #{File.basename(file)} with #{chosen} (#{toolchain.origin.to_s.downcase} TeX)"
      started = Pomtex.clock
      result = guard.compile(runner, scan, stream)
      elapsed = UI.duration(Pomtex.clock - started)
      @recorded = runner.recorded_inputs

      if result.success && (pdf = result.pdf)
        pages = result.log.match(/Output written on .*?\((\d+) pages?/).try(&.[1])
        UI.ok "#{Path[pdf].relative_to(Dir.current)}#{pages ? " (#{pages} page#{pages == "1" ? "" : "s"})" : ""} in #{elapsed}"
        true
      else
        UI.error "compilation failed after #{elapsed} (log: #{runner.log_path})"
        STDERR.puts Engine::RuntimeGuard.error_excerpt(result.log).gsub(/^/m, "    ") unless UI.quiet
        false
      end
    rescue ex : Pomtex::Error | File::Error | IO::Error
      UI.error ex.message || "build failed"
      false
    end

    # Everything `watch` should react to: the scanned sources and assets, plus
    # every project file the last run actually read (from the -recorder log).
    # Files outside the project (TeX trees, the pomtex cache) are not watched.
    private def watch_list(file : String) : Array(Path)
      root = Path[file].expand.parent
      scan = Seed::Scanner.scan(file)
      recorded = @recorded.select { |path| inside?(path, root) && !inside?(path, Config.cache_root) && File.file?(path) }
      list = (scan.sources + scan.assets + recorded).uniq
      UI.debug "watching: #{list.map(&.relative_to(root)).join(", ")}"
      list
    rescue
      [Path[file].expand]
    end

    private def inside?(path : Path, dir : Path) : Bool
      path.to_s.starts_with?(dir.to_s.rchop('/') + "/")
    end
  end
end

exit Pomtex::CLI.new.run(ARGV)

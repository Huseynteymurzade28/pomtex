require "digest/sha1"
require "../config"
require "./runner"

module Pomtex::Engine
  # Decides when a job needs BibTeX or Biber and runs it.
  #
  # The tools only run when their output would change: the .bbl is missing, a
  # .bib file is newer than it, the citations changed (the .aux citation lines
  # for BibTeX, the .bcf for Biber), or biblatex asks for a run. This keeps
  # `pomtex watch` from re-running them on every save.
  module Bibliography
    extend self

    enum Tool
      Bibtex
      Biber

      def command : String
        bibtex? ? "bibtex" : "biber"
      end
    end

    BIBER_REQUEST  = /Please \(re\)run Biber/
    BIBTEX_REQUEST = /Please \(re\)run BibTeX/
    AUX_CITATIONS  = /^\\(?:citation|bibdata|bibstyle)\{.*$/
    AUX_INCLUDES   = /^\\@input\{([^}]+)\}/
    BCF_DATASOURCE = /<bcf:datasource[^>]*>([^<]+)<\/bcf:datasource>/
    MISSING_BST    = /I couldn't open style file ([^\s]+\.bst)/

    record Outcome, ran : Bool, success : Bool, log : String

    # The tool the last engine run asks for, or nil when nothing is stale.
    def pending(runner : Runner, log : String) : Tool?
      bbl = runner.outdir.join("#{runner.jobname}.bbl")
      bcf = runner.outdir.join("#{runner.jobname}.bcf")
      aux = runner.outdir.join("#{runner.jobname}.aux")

      if log.matches?(BIBTEX_REQUEST) || (!File.exists?(bcf) && bibdata?(aux))
        return Tool::Bibtex if log.matches?(BIBTEX_REQUEST) || stale_bibtex?(runner, aux, bbl)
      elsif File.exists?(bcf)
        # biblatex only asks for Biber when citations are undefined; a new
        # \nocite{*} changes the .bcf without any request, so compare it too.
        return Tool::Biber if log.matches?(BIBER_REQUEST) || !File.exists?(bbl) ||
                              changed?(runner, Tool::Biber, bcf_digest(bcf)) ||
                              newer_than?(biber_sources(runner, bcf), bbl)
      end
      nil
    end

    # Runs `tool` (at `executable`) for the runner's job.
    def run(tool : Tool, executable : String, runner : Runner) : Outcome
      source_dir = runner.source.parent.to_s
      env = runner.environment
      output = IO::Memory.new
      status =
        if tool.bibtex?
          # bibtex runs next to the .aux; local .bib/.bst files live with the source.
          env["BIBINPUTS"] = "#{source_dir}:#{ENV["BIBINPUTS"]? || ""}"
          env["BSTINPUTS"] = "#{source_dir}:#{ENV["BSTINPUTS"]? || ""}"
          Process.run(executable, [runner.jobname], env: env, chdir: runner.outdir.to_s,
            output: output, error: output)
        else
          args = ["--input-directory", runner.outdir.to_s, "--output-directory", runner.outdir.to_s, runner.jobname]
          Process.run(executable, args, env: env, chdir: source_dir, output: output, error: output)
        end
      record_state(runner, tool) if status.success?
      blg = runner.outdir.join("#{runner.jobname}.blg")
      log = File.exists?(blg) ? File.read(blg).scrub : output.to_s
      Outcome.new(true, status.success?, log)
    end

    # .bst files BibTeX could not open (fetched as arils, then BibTeX is re-run).
    def missing_styles(log : String) : Array(String)
      log.scan(MISSING_BST).map { |match| File.basename(match[1]) }.uniq
    end

    # The first error lines of a .blg, for display.
    def error_excerpt(log : String, lines : Int32 = 4) : String
      errors = log.lines.select { |line| line.matches?(/ERROR|error message|I couldn't|^Warning--I didn't find/) }
      (errors.empty? ? log.lines.last(lines) : errors.first(lines)).map(&.strip).join('\n')
    end

    # ── BibTeX staleness ──────────────────────────────────────────────────────

    private def bibdata?(aux : Path) : Bool
      File.exists?(aux) && File.read(aux).includes?("\\bibdata{")
    end

    private def stale_bibtex?(runner : Runner, aux : Path, bbl : Path) : Bool
      return true unless File.exists?(bbl)
      return true if changed?(runner, Tool::Bibtex, citations_digest(runner, aux))
      newer_than?(bibtex_sources(runner, aux), bbl)
    end

    # Citations, databases and style from the main .aux and every included .aux.
    private def citations_digest(runner : Runner, aux : Path) : String
      lines = [] of String
      pending = [aux]
      seen = Set(Path).new
      while file = pending.shift?
        next unless seen.add?(file) && File.exists?(file)
        File.read(file).scrub.each_line do |line|
          lines << line if line.matches?(AUX_CITATIONS)
          if (match = line.match(AUX_INCLUDES))
            pending << runner.outdir.join(match[1])
          end
        end
      end
      Digest::SHA1.hexdigest(lines.join('\n'))
    end

    private def bibtex_sources(runner : Runner, aux : Path) : Array(Path)
      names = File.read(aux).scan(/\\bibdata\{([^}]*)\}/).flat_map(&.[1].split(','))
      names.map { |name| local_file(runner, name.strip.ends_with?(".bib") ? name.strip : "#{name.strip}.bib") }.compact
    end

    # ── state: what the tool last ran on ──────────────────────────────────────

    private def current_digest(runner : Runner, tool : Tool) : String
      if tool.bibtex?
        citations_digest(runner, runner.outdir.join("#{runner.jobname}.aux"))
      else
        bcf_digest(runner.outdir.join("#{runner.jobname}.bcf"))
      end
    end

    private def changed?(runner : Runner, tool : Tool, digest : String) : Bool
      state = state_file(runner, tool)
      !File.exists?(state) || File.read(state) != digest
    end

    private def record_state(runner : Runner, tool : Tool) : Nil
      file = state_file(runner, tool)
      Dir.mkdir_p(file.parent)
      File.write(file, current_digest(runner, tool))
    end

    # Kept in the cache, not next to the user's document.
    private def state_file(runner : Runner, tool : Tool) : Path
      key = Digest::SHA1.hexdigest(runner.outdir.join(runner.jobname).to_s)
      Config.cache_root.join("state", "#{key}.#{tool.command}")
    end

    # ── Biber ─────────────────────────────────────────────────────────────────

    private def bcf_digest(bcf : Path) : String
      Digest::SHA1.hexdigest(File.read(bcf))
    end

    private def biber_sources(runner : Runner, bcf : Path) : Array(Path)
      File.read(bcf).scrub.scan(BCF_DATASOURCE).compact_map { |match| local_file(runner, match[1].strip) }
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    private def local_file(runner : Runner, name : String) : Path?
      {runner.source.parent, runner.outdir}.each do |dir|
        path = Path[name].absolute? ? Path[name] : dir.join(name)
        return path if File.file?(path)
      end
      nil
    end

    private def newer_than?(sources : Array(Path), target : Path) : Bool
      return true unless File.exists?(target)
      reference = File.info(target).modification_time
      sources.any? { |path| File.info(path).modification_time > reference }
    end
  end
end

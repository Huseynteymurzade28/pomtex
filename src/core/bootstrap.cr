require "json"
require "file_utils"
require "http/client"
require "../config"
require "../seed/aril_fetcher"
require "../seed/extractor"
require "./detector"
require "./cache_lock"

module Pomtex::Core
  # Grows the rind: fetches the portable TinyTeX-1 kernel into ~/.cache/pomtex/rind.
  module Bootstrap
    extend self

    def ensure_rind(force : Bool = false) : Toolchain
      if !force && (toolchain = Detector.rind_toolchain)
        return toolchain
      end
      CacheLock.exclusive do
        # Another process may have grown the rind while we waited for the lock.
        install if force || !Detector.rind_present?
      end
      Detector.rind_toolchain || raise Error.new("the rind was unpacked but pdflatex is missing from #{Config.rind_bin_dir}")
    end

    def install : Nil
      Config.ensure_dirs
      version = resolve_version
      url = Config.rind_url(version)
      archive = Config.downloads_dir.join("#{Process.pid}-#{File.basename(URI.parse(url).path)}")

      UI.step "Growing the rind (TinyTeX #{version})"
      started = Pomtex.clock
      size = Seed::ArilFetcher.stream(url, archive, progress: progress_printer)
      STDERR.print "\r\e[K" if STDERR.tty? && !UI.quiet
      UI.ok "downloaded #{UI.bytes(size)} in #{UI.duration(Pomtex.clock - started)}"

      staging = Path["#{Config.rind_dir}.staging"]
      FileUtils.rm_rf(staging)
      if archive.extension == ".exe"
        self_extract(archive, staging)
      else
        Seed::Extractor.extract(archive, staging) do |name|
          top, _, rest = name.partition('/')
          Config::RIND_TOP_DIRS.includes?(top) ? rest : nil
        end
      end
      FileUtils.rm_rf(Config.rind_dir)
      File.rename(staging, Config.rind_dir)
      File.delete?(archive)

      verify!
      UI.ok "rind ready in #{UI.duration(Pomtex.clock - started)} → #{Config.rind_dir}"
    end

    def remove : Nil
      CacheLock.exclusive { FileUtils.rm_rf(Config.rind_dir) }
    end

    # The newest TinyTeX release tag, falling back to the pinned one offline.
    def resolve_version : String
      if pinned = ENV["POMTEX_RIND_VERSION"]?.presence
        return pinned
      end
      response = HTTP::Client.get("https://api.github.com/repos/#{Config::RIND_REPO}/releases/latest",
        headers: HTTP::Headers{"Accept" => "application/vnd.github+json", "User-Agent" => Seed::ArilFetcher::USER_AGENT})
      return Config::RIND_PINNED_VERSION unless response.success?
      JSON.parse(response.body)["tag_name"].as_s? || Config::RIND_PINNED_VERSION
    rescue
      Config::RIND_PINNED_VERSION
    end

    # The Windows bundle is a 7-Zip self-extractor: `-y` unpacks `TinyTeX/` into
    # the working directory without asking, as TinyTeX's own installer runs it.
    private def self_extract(archive : Path, staging : Path) : Nil
      unpack = Path["#{staging}.unpack"]
      FileUtils.rm_rf(unpack)
      Dir.mkdir_p(unpack)
      output = IO::Memory.new
      status = Process.run(archive.to_s, ["-y"], chdir: unpack.to_s, output: output, error: output)
      raise Error.new("could not unpack #{archive.basename}: #{output.to_s.lines.last?}") unless status.success?
      top = Config::RIND_TOP_DIRS.map { |name| unpack.join(name) }.find { |dir| Dir.exists?(dir) } ||
            raise Error.new("#{archive.basename} has no TinyTeX directory")
      File.rename(top, staging)
    ensure
      FileUtils.rm_rf(unpack) if unpack
    end

    private def verify! : Nil
      pdflatex = Config.rind_bin_dir.join(Config.executable_name("pdflatex"))
      output = IO::Memory.new
      status = Process.run(pdflatex.to_s, ["--version"], output: output, error: output)
      raise Error.new("rind self-test failed: #{output.to_s.lines.first?}") unless status.success?
      UI.debug output.to_s.lines.first? || ""
    end

    private def progress_printer : Proc(Int64, Int64?, Nil)?
      return nil unless STDERR.tty? && !UI.quiet
      last = Pomtex.clock - 1.second
      ->(done : Int64, total : Int64?) do
        now = Pomtex.clock
        return if now - last < 100.milliseconds && done != total
        last = now
        if total && total > 0
          percent = (done * 100 // total).clamp(0, 100)
          bar = "█" * (percent // 4) + "░" * (25 - percent // 4)
          STDERR.print "\r  #{bar} #{percent.to_s.rjust(3)}%  #{UI.bytes(done)} / #{UI.bytes(total)}\e[K"
        else
          STDERR.print "\r  #{UI.bytes(done)}\e[K"
        end
        nil
      end
    end
  end
end

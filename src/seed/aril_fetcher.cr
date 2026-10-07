require "http/client"
require "digest/sha512"
require "../config"
require "./extractor"

module Pomtex::Seed
  # Downloads arils concurrently and pipes each finished archive to an unpacking
  # stage, so extraction overlaps with the remaining downloads:
  #
  #     packages ─▶ [jobs] ─▶ N download fibers ─▶ [ready] ─▶ unpack fibers ─▶ [results]
  class ArilFetcher
    MAX_REDIRECTS = 8
    # mirror.ctan.org sends each request to a mirror of its choosing, so a retry
    # usually lands on a different one when the first is broken.
    ATTEMPTS   = 3
    USER_AGENT = "pomtex/#{VERSION} (+https://ctan.org)"
    UNPACKERS  = 2

    record Outcome,
      package : Package,
      files : Array(String) = [] of String,
      error : String? = nil,
      elapsed : Time::Span = Time::Span.zero do
      def ok? : Bool
        error.nil?
      end
    end

    private record Ready, package : Package, archive : Path, started : Instant

    getter jobs : Int32

    def initialize(@jobs : Int32 = Config::DEFAULT_JOBS, @texmf : Path = Config.texmf_dir)
      @jobs = @jobs.clamp(1, 32)
    end

    def fetch_all(packages : Array(Package), & : Outcome ->) : Array(Outcome)
      return [] of Outcome if packages.empty?
      Config.ensure_dirs

      queue = Channel(Package).new(packages.size)
      ready = Channel(Ready).new(packages.size)
      results = Channel(Outcome).new(packages.size)
      packages.each { |pkg| queue.send(pkg) }
      queue.close

      downloaders = Math.min(@jobs, packages.size)
      finished = Channel(Nil).new(downloaders)

      downloaders.times do
        spawn do
          while pkg = queue.receive?
            started = Pomtex.clock
            begin
              archive = download(pkg)
              ready.send(Ready.new(pkg, archive, started))
            rescue ex
              results.send(Outcome.new(pkg, error: ex.message || ex.class.name, elapsed: Pomtex.clock - started))
            end
          end
          finished.send(nil)
        end
      end

      # Close the hand-off channel once every downloader is done.
      spawn do
        downloaders.times { finished.receive }
        ready.close
      end

      UNPACKERS.times do
        spawn do
          while item = ready.receive?
            outcome = begin
              files = Extractor.extract_aril(item.archive, @texmf)
              File.delete?(item.archive)
              Outcome.new(item.package, files: files, elapsed: Pomtex.clock - item.started)
            rescue ex
              Outcome.new(item.package, error: "unpack failed: #{ex.message}", elapsed: Pomtex.clock - item.started)
            end
            results.send(outcome)
          end
        end
      end

      Array.new(packages.size) do
        outcome = results.receive
        yield outcome
        outcome
      end
    end

    private def download(pkg : Package) : Path
      # Per-process names: two pomtex processes never share an in-flight file.
      dest = Config.downloads_dir.join("#{pkg.name}.#{Process.pid}.tar.xz")
      self.class.stream(Config.aril_url(pkg.name), dest, pkg.sha512.presence)
      dest
    end

    # Streams `url` to `dest` (via a .part file), following redirects and
    # verifying the SHA-512 when one is given; retries from `url` on failure.
    # Returns the byte count.
    def self.stream(url : String, dest : Path, sha512 : String? = nil,
                    progress : Proc(Int64, Int64?, Nil)? = nil) : Int64
      attempt = 1
      loop do
        return stream_once(url, dest, sha512, progress)
      rescue ex : Error
        raise ex if attempt >= ATTEMPTS
        UI.debug "#{ex.message}; retrying (#{attempt}/#{ATTEMPTS - 1})"
        sleep (attempt * 500).milliseconds
        attempt += 1
      end
    end

    private def self.stream_once(url : String, dest : Path, sha512 : String?,
                                 progress : Proc(Int64, Int64?, Nil)?) : Int64
      part = Path["#{dest}.part"]
      current = URI.parse(url)
      headers = HTTP::Headers{"User-Agent" => USER_AGENT}

      MAX_REDIRECTS.times do
        client = HTTP::Client.new(current)
        client.connect_timeout = 20.seconds
        client.read_timeout = 60.seconds
        begin
          redirect = nil
          written = 0_i64
          client.get(current.request_target, headers: headers) do |response|
            if response.status.redirection? && (location = response.headers["Location"]?)
              redirect = current.resolve(location)
              next
            end
            unless response.success?
              raise Error.new("HTTP #{response.status_code} for #{current}")
            end
            total = response.headers["Content-Length"]?.try(&.to_i64?)
            File.open(part, "w") do |file|
              digest = Digest::SHA512.new
              buffer = Bytes.new(64 * 1024)
              body = response.body_io
              while (count = body.read(buffer)) > 0
                chunk = buffer[0, count]
                file.write(chunk)
                digest.update(chunk) if sha512
                written += count
                progress.try &.call(written, total)
              end
              if sha512 && (actual = digest.hexfinal) != sha512.downcase
                raise Error.new("checksum mismatch for #{File.basename(dest)} (expected #{sha512[0, 12]}…, got #{actual[0, 12]}…)")
              end
            end
          end
          if target = redirect
            current = target
            next
          end
          File.rename(part, dest)
          return written
        rescue ex : IO::Error | Socket::Error | OpenSSL::Error
          # Name the mirror: with mirror.ctan.org it is not the host that was asked.
          raise Error.new("#{current.host}: #{ex.message}")
        ensure
          client.close
          File.delete?(part)
        end
      end
      raise Error.new("too many redirects for #{url}")
    end
  end
end

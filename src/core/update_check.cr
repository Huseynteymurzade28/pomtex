require "json"
require "http/client"
require "../config"

module Pomtex::Core
  # Tells `pomtex doctor` whether a newer release exists, and how to get it.
  # Never used during builds: a network check must not slow down compilation.
  module UpdateCheck
    extend self

    TIMEOUT = 3.seconds

    enum Status
      Current
      Outdated
      Unknown
    end

    record Result, status : Status, latest : String? = nil, hint : String? = nil

    def check(current : String = VERSION) : Result
      latest = latest_version
      return Result.new(Status::Unknown) unless latest
      if newer?(latest, current)
        Result.new(Status::Outdated, latest, upgrade_hint)
      else
        Result.new(Status::Current, latest)
      end
    end

    # The latest release tag on GitHub, without the leading "v".
    def latest_version : String?
      uri = URI.parse("https://api.github.com/repos/#{Config::REPO}/releases/latest")
      client = HTTP::Client.new(uri)
      client.connect_timeout = TIMEOUT
      client.read_timeout = TIMEOUT
      headers = HTTP::Headers{"Accept" => "application/vnd.github+json", "User-Agent" => "pomtex/#{VERSION}"}
      response = client.get(uri.request_target, headers: headers)
      return nil unless response.success?
      JSON.parse(response.body)["tag_name"].as_s?.try(&.lchop('v'))
    rescue
      nil
    ensure
      client.try &.close
    end

    # Numeric comparison of dotted versions: 0.10.0 is newer than 0.9.1.
    def newer?(candidate : String, current : String) : Bool
      (segments(candidate) <=> segments(current)) > 0
    end

    # How this binary was installed decides how to update it.
    def upgrade_hint(executable : String? = Process.executable_path) : String
      if executable && (package = pacman_owner(executable))
        "yay -S #{package}"
      else
        "https://github.com/#{Config::REPO}/releases/latest"
      end
    end

    private def pacman_owner(path : String) : String?
      pacman = Process.find_executable("pacman") || return nil
      output = IO::Memory.new
      status = Process.run(pacman, ["-Qqo", path], output: output, error: Process::Redirect::Close)
      status.success? ? output.to_s.strip.presence : nil
    end

    private def segments(version : String) : Array(Int32)
      parts = version.lchop('v').split('-').first.split('.').map { |part| part.to_i? || 0 }
      parts + [0] * Math.max(0, 3 - parts.size)
    end
  end
end

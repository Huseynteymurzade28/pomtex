require "../config"

module Pomtex::Watcher
  # Polls the document and everything it inputs, and fires a rebuild once the
  # files have been quiet for `debounce` (editors often write in several steps).
  #
  #     poll fiber ──(changed path)──▶ [pulses] ──▶ debounce (select/timeout) ──▶ rebuild
  class LivePulse
    getter debounce : Time::Span
    getter poll : Time::Span

    # `rebuild` compiles and returns the set of files to watch from then on.
    def initialize(@debounce = Config::DEFAULT_DEBOUNCE, @poll = Config::WATCH_POLL_PERIOD,
                   &@rebuild : -> Array(Path))
      @watched = [] of Path
      @stamps = {} of Path => Time?
    end

    def run : NoReturn
      pulses = Channel(Path).new(64)
      @watched = @rebuild.call
      snapshot
      announce

      spawn do
        loop do
          sleep poll
          @watched.each do |path|
            stamp = mtime(path)
            next if stamp == @stamps[path]?
            @stamps[path] = stamp
            pulses.send(path)
          end
        end
      end

      loop do
        first = pulses.receive
        changed = Set{first}
        # Debounce: keep absorbing pulses until the tree has been quiet.
        loop do
          select
          when path = pulses.receive
            changed << path
          when timeout(debounce)
            break
          end
        end
        UI.step "#{changed.map { |path| File.basename(path) }.join(", ")} changed — #{Time.local.to_s("%H:%M:%S")}"
        @watched = @rebuild.call
        snapshot
        announce
      end
    end

    private def snapshot : Nil
      @stamps = @watched.to_h { |path| {path, mtime(path)} }
    end

    private def announce : Nil
      UI.info "watching #{@watched.size} file#{@watched.size == 1 ? "" : "s"} (Ctrl-C to stop)"
    end

    private def mtime(path : Path) : Time?
      File.info?(path).try(&.modification_time)
    end
  end
end

require "../config"
require "./inotify"

module Pomtex::Watcher
  # Watches the document and everything it inputs, and fires a rebuild once the
  # files have been quiet for `debounce` (editors often write in several steps).
  #
  #     inotify fiber ─┐
  #                    ├─(changed path)──▶ [pulses] ──▶ debounce (select/timeout) ──▶ rebuild
  #     poll fiber ────┘
  #
  # inotify covers what it can; files it can't (network file systems, no
  # inotify at all) are polled for mtime changes instead.
  class LivePulse
    getter debounce : Time::Span
    getter poll : Time::Span

    # `rebuild` compiles and returns the set of files to watch from then on.
    def initialize(@debounce = Config::DEFAULT_DEBOUNCE, @poll = Config::WATCH_POLL_PERIOD,
                   @inotify : Inotify? = Inotify.open, &@rebuild : -> Array(Path))
      @watched = Set(Path).new
      @polled = [] of Path
      @stamps = {} of Path => Time?
    end

    def run : NoReturn
      pulses = Channel(Path).new(64)
      rewatch

      if inotify = @inotify
        spawn do
          inotify.each_event do |path|
            if path.nil?
              # The kernel dropped events: assume something we watch changed.
              @watched.first?.try { |any| pulses.send(any) }
            elsif @watched.includes?(path) && changed?(path)
              pulses.send(path)
            end
          end
        end
      end

      spawn do
        loop do
          sleep poll
          @polled.each { |path| pulses.send(path) if changed?(path) }
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
        rewatch
      end
    end

    private def rewatch : Nil
      list = @rebuild.call
      @watched = list.to_set
      @polled = @inotify.try(&.watch(list)) || list
      # Files the build itself rewrote (a .bbl from BibTeX) must not trigger
      # another build: only changes after this snapshot count.
      @stamps = list.to_h { |path| {path, mtime(path)} }
      UI.debug "polling: #{@polled.join(", ")}" unless @polled.empty? || @inotify.nil?
      UI.info "watching #{list.size} file#{list.size == 1 ? "" : "s"} (Ctrl-C to stop)"
    end

    private def changed?(path : Path) : Bool
      stamp = mtime(path)
      return false if stamp == @stamps[path]?
      @stamps[path] = stamp
      true
    end

    private def mtime(path : Path) : Time?
      File.info?(path).try(&.modification_time)
    end
  end
end

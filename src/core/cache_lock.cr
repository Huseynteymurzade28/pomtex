require "../config"
require "../ui"

module Pomtex::Core
  # Coordinates pomtex processes that share one cache (e.g. `pomtex watch` in one
  # terminal and `pomtex build` in another) with an flock on `<cache>/.lock`.
  #
  # - exclusive: anything that writes the cache (planting arils, growing the rind,
  #   rebuilding the index, remove/clean)
  # - shared: engine runs, so the tree cannot be removed underneath a compile
  #
  # Locks are re-entrant within a process. Taking an exclusive lock while holding
  # a shared one converts it. flock conversion is not atomic: a conversion that
  # has to wait drops the shared lock first, so two compiles that both need to
  # fetch cannot deadlock. Callers must re-check the cache state after acquiring,
  # because another process may have done the work already.
  module CacheLock
    extend self

    enum Mode
      Shared
      Exclusive
    end

    @@file : File? = nil
    @@mode : Mode? = nil
    @@depth = 0

    def exclusive(&)
      hold(Mode::Exclusive) { yield }
    end

    def shared(&)
      hold(Mode::Shared) { yield }
    end

    def held : Mode?
      @@mode
    end

    private def hold(mode : Mode, &)
      previous = @@mode
      if previous.nil? || (mode.exclusive? && previous.shared?)
        acquire(mode)
      end
      @@depth += 1
      begin
        yield
      ensure
        @@depth -= 1
        if @@depth == 0
          release
        elsif previous && previous != @@mode
          acquire(previous)
        end
      end
    end

    private def acquire(mode : Mode) : Nil
      file = (@@file ||= open_lock_file)
      begin
        lock(file, mode, blocking: false)
      rescue IO::Error
        UI.info "waiting for another pomtex process…"
        lock(file, mode, blocking: true)
      end
      @@mode = mode
    end

    private def lock(file : File, mode : Mode, blocking : Bool) : Nil
      mode.exclusive? ? file.flock_exclusive(blocking) : file.flock_shared(blocking)
    end

    private def release : Nil
      if file = @@file
        file.flock_unlock
        file.close
      end
      @@file = nil
      @@mode = nil
    end

    private def open_lock_file : File
      Dir.mkdir_p(Config.cache_root)
      File.open(Config.cache_root.join(".lock"), "a")
    end
  end
end

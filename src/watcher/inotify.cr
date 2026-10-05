module Pomtex::Watcher
  {% if flag?(:linux) %}
    lib LibInotify
      IN_NONBLOCK    =         0o4000
      IN_CLOEXEC     =      0o2000000
      IN_CLOSE_WRITE = 0x00000008_u32
      IN_MOVED_FROM  = 0x00000040_u32
      IN_MOVED_TO    = 0x00000080_u32
      IN_CREATE      = 0x00000100_u32
      IN_DELETE      = 0x00000200_u32
      IN_Q_OVERFLOW  = 0x00004000_u32
      IN_ONLYDIR     = 0x01000000_u32

      fun inotify_init1(flags : LibC::Int) : LibC::Int
      fun inotify_add_watch(fd : LibC::Int, path : LibC::Char*, mask : UInt32) : LibC::Int
      fun inotify_rm_watch(fd : LibC::Int, wd : LibC::Int) : LibC::Int
      fun statfs(path : LibC::Char*, buf : Void*) : LibC::Int
    end
  {% end %}

  # Change notification through Linux inotify. Directories are watched rather
  # than files: editors often save by writing a new file and renaming it over
  # the old one, which would silently drop a watch on the file itself.
  class Inotify
    # Remote and FUSE file systems don't report changes made elsewhere
    # (NFS, SMB/CIFS, FUSE such as sshfs, 9p as used by WSL, AFS, Ceph).
    NETWORK_FILESYSTEMS = {0x6969_u32, 0x517b_u32, 0xff534d42_u32, 0xfe534d42_u32, 0x65735546_u32,
                           0x01021997_u32, 0x5346414f_u32, 0x00c36400_u32}

    EVENT_HEADER = 16 # struct inotify_event: wd, mask, cookie, len; then the name

    @io : IO::FileDescriptor
    @dirs = {} of Int32 => Path
    @wds = {} of Path => Int32

    # nil when inotify is unavailable (another OS, or the instance limit is reached).
    def self.open : Inotify?
      {% if flag?(:linux) %}
        fd = LibInotify.inotify_init1(LibInotify::IN_NONBLOCK | LibInotify::IN_CLOEXEC)
        return nil if fd < 0
        # The fd is already non-blocking (IN_NONBLOCK). Crystal guesses blocking
        # for anonymous inodes, so say otherwise; newer versions deprecate `blocking:`.
        {% if IO::FileDescriptor.methods.any? { |method| method.name == "initialize" && method.args.any? { |arg| arg.name == "handle" } } %}
          new(IO::FileDescriptor.new(handle: fd))
        {% else %}
          new(IO::FileDescriptor.new(fd, blocking: false))
        {% end %}
      {% else %}
        nil
      {% end %}
    end

    private def initialize(@io)
      # inotify hands out whole events only; never split them across reads.
      @io.read_buffering = false
    end

    # Watches the directories of `paths`, dropping directories no longer needed.
    # Returns the paths inotify can't cover; the caller should poll those.
    def watch(paths : Enumerable(Path)) : Array(Path)
      unwatched = [] of Path
      {% if flag?(:linux) %}
        wanted = paths.group_by(&.parent)
        @wds.reject! do |dir, wd|
          next false if wanted.has_key?(dir)
          LibInotify.inotify_rm_watch(@io.fd, wd)
          @dirs.delete(wd)
          true
        end
        mask = LibInotify::IN_CLOSE_WRITE | LibInotify::IN_MOVED_FROM | LibInotify::IN_MOVED_TO |
               LibInotify::IN_CREATE | LibInotify::IN_DELETE | LibInotify::IN_ONLYDIR
        wanted.each do |dir, files|
          next if @wds.has_key?(dir)
          wd = self.class.network?(dir) ? -1 : LibInotify.inotify_add_watch(@io.fd, dir.to_s, mask)
          if wd < 0
            unwatched.concat(files)
          else
            @dirs[wd] = dir
            @wds[dir] = wd
          end
        end
      {% else %}
        unwatched.concat(paths)
      {% end %}
      unwatched
    end

    # Yields each changed path as events arrive, or nil when the kernel queue
    # overflowed and events were lost. Blocks only the calling fiber.
    def each_event(& : Path? ->) : Nil
      buffer = Bytes.new(64 * 1024)
      loop do
        size = begin
          @io.read(buffer)
        rescue ex : IO::Error
          raise ex unless @io.closed?
          0
        end
        break if size == 0
        offset = 0
        while offset + EVENT_HEADER <= size
          wd = IO::ByteFormat::SystemEndian.decode(Int32, buffer[offset, 4])
          mask = IO::ByteFormat::SystemEndian.decode(UInt32, buffer[offset + 4, 4])
          length = IO::ByteFormat::SystemEndian.decode(UInt32, buffer[offset + 12, 4]).to_i
          raw = buffer[offset + EVENT_HEADER, length]
          name = String.new(raw[0, raw.index(0_u8) || raw.size])
          offset += EVENT_HEADER + length

          {% if flag?(:linux) %}
            if mask & LibInotify::IN_Q_OVERFLOW != 0
              yield nil
              next
            end
          {% end %}
          if (dir = @dirs[wd]?) && !name.empty?
            yield dir.join(name)
          end
        end
      end
    end

    def close : Nil
      @io.close
    end

    def self.network?(dir : Path) : Bool
      {% if flag?(:linux) %}
        # struct statfs starts with f_type (a long) on every Linux architecture.
        buffer = uninitialized UInt8[256]
        return false unless LibInotify.statfs(dir.to_s, buffer.to_unsafe.as(Void*)) == 0
        magic = buffer.to_unsafe.as(LibC::Long*).value.to_u64! & 0xffffffff_u64
        NETWORK_FILESYSTEMS.includes?(magic.to_u32)
      {% else %}
        false
      {% end %}
    end
  end
end

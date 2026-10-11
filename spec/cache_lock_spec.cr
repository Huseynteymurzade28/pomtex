require "./spec_helper"

alias CacheLock = Pomtex::Core::CacheLock

private def with_cache(&)
  with_tmpdir do |dir|
    previous = ENV["POMTEX_HOME"]?
    ENV["POMTEX_HOME"] = dir.to_s
    Pomtex::UI.quiet = true
    begin
      yield dir.join(".lock").to_s
    ensure
      previous ? (ENV["POMTEX_HOME"] = previous) : ENV.delete("POMTEX_HOME")
      Pomtex::UI.quiet = false
    end
  end
end

# flock(2) from another process. The flock(1) command is util-linux only, so
# perl stands in for it on macOS too.
HOLD_LOCK = %q(open my $f, ">>", $ARGV[0] or die; flock($f, $ARGV[1] eq "-s" ? LOCK_SH : LOCK_EX) or die; select(undef, undef, undef, $ARGV[2]))
TRY_LOCK  = %q(open my $f, ">>", $ARGV[0] or die; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1))

# Windows perl emulates flock, so .NET takes the byte-range lock there instead.
# It can only lock exclusively; a ready file signals that it holds the lock.
HOLD_LOCK_PS = %q($f = [IO.File]::Open($env:LOCK, 'OpenOrCreate', 'ReadWrite', 'ReadWrite'); $f.Lock(0, [long]::MaxValue); New-Item "$env:LOCK.ready" | Out-Null; Start-Sleep -Milliseconds $env:HOLD_MS; $f.Close())

private def lockable?(lock : String) : Bool
  Process.run("perl", ["-MFcntl=:flock", "-e", TRY_LOCK, lock]).success?
end

# Holds `lock` in `mode` (-x or -s) for `seconds` in another process, once it has it.
private def hold_in_other_process(lock : String, mode : String, seconds : Float64) : Process
  File.touch(lock)
  {% if flag?(:win32) %}
    raise "shared locks can't be held from PowerShell" unless mode == "-x"
    env = {"LOCK" => lock, "HOLD_MS" => (seconds * 1000).to_i.to_s}
    Process.new("powershell", ["-NoProfile", "-Command", HOLD_LOCK_PS], env: env).tap do
      until File.exists?("#{lock}.ready")
        sleep 10.milliseconds
      end
    end
  {% else %}
    Process.new("perl", ["-MFcntl=:flock", "-e", HOLD_LOCK, lock, mode, seconds.to_s]).tap do
      while lockable?(lock)
        sleep 10.milliseconds
      end
    end
  {% end %}
end

private def elapsed(&) : Time::Span
  started = Pomtex.clock
  yield
  Pomtex.clock - started
end

describe Pomtex::Core::CacheLock do
  it "waits while another process holds the cache exclusively" do
    with_cache do |lock|
      holder = hold_in_other_process(lock, "-x", 0.8)
      elapsed { CacheLock.exclusive { } }.should be >= 0.5.seconds
      holder.wait
    end
  end

  # The other process holds a shared lock, which HOLD_LOCK_PS can't.
  it_unix "lets shared holders run concurrently" do
    with_cache do |lock|
      holder = hold_in_other_process(lock, "-s", 0.8)
      elapsed { CacheLock.shared { } }.should be < 0.3.seconds
      holder.wait
    end
  end

  it_unix "keeps writers out while a compile holds a shared lock" do
    with_cache do |lock|
      holder = hold_in_other_process(lock, "-s", 0.8)
      elapsed { CacheLock.exclusive { } }.should be >= 0.5.seconds
      holder.wait
    end
  end

  it "is re-entrant and restores the outer mode" do
    with_cache do |_|
      CacheLock.exclusive do
        CacheLock.shared { CacheLock.held.should eq CacheLock::Mode::Exclusive }
        CacheLock.held.should eq CacheLock::Mode::Exclusive
      end
      CacheLock.shared do
        CacheLock.exclusive { CacheLock.held.should eq CacheLock::Mode::Exclusive }
        CacheLock.held.should eq CacheLock::Mode::Shared
      end
      CacheLock.held.should be_nil
    end
  end

  it "releases the lock when the block raises" do
    with_cache do |lock|
      expect_raises(Exception, "boom") { CacheLock.exclusive { raise "boom" } }
      CacheLock.held.should be_nil
      lockable?(lock).should be_true
    end
  end
end

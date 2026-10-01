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

# Runs `flock <mode> <file> sleep <seconds>` and waits until it holds the lock.
private def hold_in_other_process(lock : String, mode : String, seconds : Float64) : Process
  File.touch(lock)
  holder = Process.new("flock", [mode, lock, "sleep", seconds.to_s])
  until Process.run("flock", ["-n", "-x", lock, "true"]).success? == false
    sleep 10.milliseconds
  end
  holder
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

  it "lets shared holders run concurrently" do
    with_cache do |lock|
      holder = hold_in_other_process(lock, "-s", 0.8)
      elapsed { CacheLock.shared { } }.should be < 0.3.seconds
      holder.wait
    end
  end

  it "keeps writers out while a compile holds a shared lock" do
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
      Process.run("flock", ["-n", "-x", lock, "true"]).success?.should be_true
    end
  end
end

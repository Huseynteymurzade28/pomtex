require "./spec_helper"
require "../src/watcher/inotify"

# Every event that arrives until the directory has been quiet for 200 ms.
private def drain(events : Channel(Path?)) : Array(Path?)
  seen = [] of Path?
  loop do
    select
    when path = events.receive
      seen << path
    when timeout(200.milliseconds)
      return seen
    end
  end
end

{% if flag?(:linux) %}
  describe Pomtex::Watcher::Inotify do
    it "reports writes, editor-style replacements and deletions in watched directories" do
      with_tmpdir do |dir|
        main = dir.join("main.tex")
        File.write(main, "a")
        inotify = Pomtex::Watcher::Inotify.open.not_nil!
        inotify.watch([main]).should be_empty

        events = Channel(Path?).new(16)
        spawn { inotify.each_event { |path| events.send(path) } }
        Fiber.yield

        File.write(main, "b")
        drain(events).uniq.should eq [main]

        # Vim-style save: write a temporary file, rename it over the original.
        File.write(dir.join("main.tex.tmp"), "c")
        File.rename(dir.join("main.tex.tmp"), main)
        drain(events).uniq.should eq [dir.join("main.tex.tmp"), main]

        File.delete(main)
        drain(events).should eq [main]
        inotify.close
      end
    end

    it "drops directories that are no longer watched" do
      with_tmpdir do |dir|
        Dir.mkdir(dir.join("a"))
        inotify = Pomtex::Watcher::Inotify.open.not_nil!
        inotify.watch([dir.join("a", "x.tex")]).should be_empty
        inotify.watch([dir.join("y.tex")]).should be_empty

        events = Channel(Path?).new(16)
        spawn { inotify.each_event { |path| events.send(path) } }
        Fiber.yield

        File.write(dir.join("a", "x.tex"), "")
        File.write(dir.join("y.tex"), "")
        drain(events).uniq.should eq [dir.join("y.tex")]
        inotify.close
      end
    end

    it "leaves files in missing directories to polling" do
      inotify = Pomtex::Watcher::Inotify.open.not_nil!
      missing = Path["/nonexistent-pomtex-dir/main.tex"]
      inotify.watch([missing]).should eq [missing]
      inotify.close
    end
  end
{% end %}

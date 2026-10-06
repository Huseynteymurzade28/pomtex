require "./spec_helper"

describe Pomtex::Seed::Extractor do
  it "unpacks .tar.gz and .tar.xz arils with long names, symlinks and modes" do
    with_tmpdir do |dir|
      src = dir.join("src")
      long = "tex/latex/" + "deep/" * 30 + "file.sty"
      Dir.mkdir_p(src.join(Path[long].parent))
      Dir.mkdir_p(src.join("tlpkg/tlpobj"))
      File.write(src.join(long), "\\ProvidesPackage{file}")
      File.write(src.join("tlpkg/tlpobj/x.tlpobj"), "meta")
      File.write(src.join("tex/run.sh"), "#!/bin/sh")
      File.chmod(src.join("tex/run.sh"), 0o755)
      File.symlink("run.sh", src.join("tex/link.sh"))

      # GNU tar calls the format "gnu", bsdtar (macOS) "gnutar".
      version = IO::Memory.new
      Process.run("tar", ["--version"], output: version)
      format = version.to_s.includes?("bsdtar") ? "--format=gnutar" : "--format=gnu"
      {"gz" => "-czf", "xz" => "-cJf"}.each do |ext, flag|
        archive = dir.join("aril.tar.#{ext}")
        Process.run("tar", [format, flag, archive.to_s, "-C", src.to_s, "tex", "tlpkg"]).success?.should be_true
        dest = dir.join("out-#{ext}")
        written = Pomtex::Seed::Extractor.extract_aril(archive, dest)

        written.should contain(long)
        written.any?(&.starts_with?("tlpkg/")).should be_false
        File.read(dest.join(long)).should eq "\\ProvidesPackage{file}"
        File.info(dest.join("tex/run.sh")).permissions.owner_execute?.should be_true
        File.readlink(dest.join("tex/link.sh")).should eq "run.sh"
      end
    end
  end

  it "rejects path traversal" do
    Pomtex::Seed::Extractor.sanitize("../../etc/passwd").should be_nil
    Pomtex::Seed::Extractor.sanitize("/etc/passwd").should be_nil
    Pomtex::Seed::Extractor.sanitize("./tex//latex/a.sty").should eq "tex/latex/a.sty"
  end
end

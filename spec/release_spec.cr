require "./spec_helper"

private def with_home(&)
  with_tmpdir do |dir|
    previous = ENV["POMTEX_HOME"]?
    ENV["POMTEX_HOME"] = dir.to_s
    Pomtex::UI.quiet = true
    begin
      Pomtex::Config.ensure_dirs
      yield dir
    ensure
      previous ? (ENV["POMTEX_HOME"] = previous) : ENV.delete("POMTEX_HOME")
      Pomtex::UI.quiet = false
      Pomtex::Config.release = nil
    end
  end
end

private def index_for(year : Int32, package : String) : Pomtex::Seed::Index
  tlpdb = "name 00texlive.config\ndepend frozen/0\ndepend release/#{year}\n\n" \
          "name #{package}\ncontainersize 1\ncontainerchecksum x\nrunfiles size=1\n RELOC/tex/latex/#{package}/#{package}.sty\n\n"
  Pomtex::Seed::Index.from_tlpdb(IO::Memory.new(tlpdb))
end

describe "TeX Live release matching" do
  it "records tlnet's release in the index and its cache" do
    with_home do |home|
      index = index_for(2026, "lipsum")
      index.release.should eq 2026
      index.save(home.join("files.idx"))
      Pomtex::Seed::Index.load(home.join("files.idx")).not_nil!.release.should eq 2026
      Pomtex::Seed::Index.cached_release(home.join("files.idx")).should eq 2026
    end
  end

  it "points the mirror and the index at the frozen archive of an older release" do
    with_home do
      Pomtex::Config.mirror.should eq Pomtex::Config::DEFAULT_MIRROR
      Pomtex::Config.release = 2025
      Pomtex::Config.mirror.should eq "#{Pomtex::Config::DEFAULT_HISTORIC_MIRROR}/2025/tlnet-final"
      Pomtex::Config.aril_url("lipsum").should end_with "/2025/tlnet-final/archive/lipsum.tar.xz"
      Pomtex::Config.index_file.basename.should eq "files-2025.idx"
    end
  end

  it "uses the archive matching an older kernel and current tlnet otherwise" do
    with_home do
      index_for(2026, "current").save(Pomtex::Config.index_file(nil))
      index_for(2025, "frozen").save(Pomtex::Config.index_file(2025))

      Pomtex::Seed::Resolver.for_release(2026, offline: true).package_for("current.sty").should eq "current"
      Pomtex::Config.release.should be_nil
      Pomtex::Seed::Resolver.for_release(nil, offline: true).package_for("current.sty").should eq "current"

      Pomtex::Seed::Resolver.for_release(2025, offline: true).package_for("frozen.sty").should eq "frozen"
      Pomtex::Config.release.should eq 2025
      Pomtex::Seed::Resolver.historic?(2025).should be_true
      Pomtex::Seed::Resolver.historic?(2026).should be_false
    end
  end

  it "decides from tlnet's release before any archive index exists" do
    with_home do
      index_for(2026, "current").save(Pomtex::Config.index_file(nil))
      Pomtex::Seed::Resolver.historic?(2024).should be_true
      # Offline, the archive index can't be built: there is nothing to resolve with.
      Pomtex::Seed::Resolver.for_release(2024, offline: true).available?.should be_false
      Pomtex::Config.release.should eq 2024
    end
  end

  it "leaves an explicit POMTEX_MIRROR alone" do
    with_home do
      index_for(2026, "current").save(Pomtex::Config.index_file(nil))
      ENV["POMTEX_MIRROR"] = "https://example.org/tlnet"
      begin
        Pomtex::Seed::Resolver.for_release(2024, offline: true).package_for("current.sty").should eq "current"
        Pomtex::Config.mirror.should eq "https://example.org/tlnet"
      ensure
        ENV.delete("POMTEX_MIRROR")
      end
    end
  end
end

describe Pomtex::Core::Toolchain do
  it "reads the TeX Live release from the installation's package database" do
    with_tmpdir do |dir|
      bin = dir.join("bin", "x86_64-linux")
      Dir.mkdir_p(bin)
      Dir.mkdir_p(dir.join("tlpkg"))
      File.write(dir.join("tlpkg", "texlive.tlpdb"), "name 00texlive.config\ncategory TLCore\ndepend minrelease/2016\ndepend release/2025\n\nname 00texlive.installation\n")
      Pomtex::Core::Toolchain.new(Pomtex::Core::Toolchain::Origin::Rind, bin).texlive_year.should eq 2025
    end
  end

  it "falls back to the engine's version banner" do
    with_tmpdir do |dir|
      script = dir.join("pdftex")
      File.write(script, "#!/bin/sh\necho 'pdfTeX 3.141592653-2.6-1.40.27 (TeX Live 2024/Debian)'\n")
      File.chmod(script, 0o755)
      Pomtex::Core::Toolchain.new(Pomtex::Core::Toolchain::Origin::System, dir).texlive_year.should eq 2024
    end
  end
end

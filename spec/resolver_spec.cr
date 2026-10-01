require "./spec_helper"

TLPDB = <<-TLPDB
  name 00texlive.config
  category ConfigFiles

  name tikz-cd
  category Package
  revision 1
  depend pgf
  containersize 6383
  containerchecksum abc123
  docfiles size=10
   RELOC/doc/latex/tikz-cd/tikz-cd-doc.pdf details="Package documentation"
  runfiles size=3
   RELOC/tex/generic/tikz-cd/tikzlibrarycd.code.tex
   RELOC/tex/latex/tikz-cd/tikz-cd.sty

  name pgf
  category Package
  depend xcolor
  depend pgf.ARCH
  containersize 719492
  containerchecksum def456
  runfiles size=2
   RELOC/tex/latex/pgf/frontendlayer/tikz.sty
   RELOC/tex/generic/pgf/pgf.revision.tex

  name libertinus-fonts
  category Package
  execute addMap libertinus.map
  runfiles size=1
   RELOC/fonts/opentype/public/libertinus-fonts/LibertinusSerif-Regular.otf

  name collection-latex
  category Collection
  depend pgf

  TLPDB

describe Pomtex::Seed::Index do
  index = Pomtex::Seed::Index.from_tlpdb(IO::Memory.new(TLPDB))

  it "indexes run files by basename, skipping meta packages" do
    index.files["tikzlibrarycd.code.tex"].should eq "tikz-cd"
    index.files["tikz.sty"].should eq "pgf"
    index.files.has_key?("tikz-cd-doc.pdf").should be_false
    index.packages.keys.sort.should eq ["libertinus-fonts", "pgf", "tikz-cd"]
  end

  it "keeps dependencies, checksums, probes and font maps" do
    pgf = index.packages["pgf"]
    pgf.depends.should eq ["xcolor"]
    pgf.sha512.should eq "def456"
    pgf.size.should eq 719492
    index.packages["tikz-cd"].probe.should eq "tikz-cd.sty"
    index.packages["libertinus-fonts"].maps.should eq ["libertinus.map"]
  end

  it "round-trips through the cache file" do
    with_tmpdir do |dir|
      index.save(dir.join("files.idx"))
      loaded = Pomtex::Seed::Index.load(dir.join("files.idx")).not_nil!
      loaded.packages.should eq index.packages
      loaded.files.should eq index.files
      loaded.fonts.should eq index.fonts
    end
  end
end

describe Pomtex::Seed::Resolver do
  resolver = Pomtex::Seed::Resolver.new(Pomtex::Seed::Index.from_tlpdb(IO::Memory.new(TLPDB)))

  it "maps files and font names to packages" do
    resolver.package_for("tikz-cd.sty").should eq "tikz-cd"
    resolver.package_for("pgf.revision").should eq "pgf"
    resolver.package_for("nope.sty").should be_nil
    resolver.font_file("Libertinus Serif").should eq "LibertinusSerif-Regular.otf"
  end

  it "expands dependencies only through missing packages" do
    layers = [] of Array(String)
    plan = resolver.closure(["tikz-cd"]) do |layer|
      layers << layer.map(&.name)
      layer # everything missing
    end
    plan.map(&.name).should eq ["tikz-cd", "pgf"]
    layers.should eq [["tikz-cd"], ["pgf"]] # xcolor is not in the index

    resolver.closure(["tikz-cd"]) { |layer| layer.reject { |pkg| pkg.name == "tikz-cd" } }.should be_empty
  end

  it "accepts pgf-level libraries for tikz library requests" do
    Pomtex::Seed::Resolver.alternates("tikzlibraryarrows.meta.code.tex").should eq ["pgflibraryarrows.meta.code.tex"]
    Pomtex::Seed::Resolver.alternates("tikz.sty").should be_empty
    index = Pomtex::Seed::Index.from_tlpdb(IO::Memory.new("name pgf\nrunfiles size=1\n RELOC/tex/generic/pgf/libraries/pgflibraryarrows.meta.code.tex\n\n"))
    Pomtex::Seed::Resolver.new(index).package_for("tikzlibraryarrows.meta.code.tex").should eq "pgf"
  end

  it "falls back to seed hints without an index" do
    Pomtex::Seed::Resolver.new(nil).package_for("tikz.sty").should eq "pgf"
  end
end

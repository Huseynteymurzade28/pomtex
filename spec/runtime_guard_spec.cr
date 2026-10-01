require "./spec_helper"

alias Guard = Pomtex::Engine::RuntimeGuard

describe Pomtex::Engine::RuntimeGuard do
  it "extracts missing files from LaTeX errors" do
    log = <<-'LOG'
      ./main.tex:3: LaTeX Error: File `lipsum.sty' not found.
      ! I can't find file `glyphtounicode'.
      ! Font T1/cmr/m/n/10=ecrm1000 at 10.0pt not loadable: Metric (TFM) file not found.
      kpathsea: Running mktextfm jkpmn8r
      !pdfTeX error: pdflatex (file ./kp-ts1.enc): cannot open encoding file for reading
      pdfTeX warning: pdflatex (file kpfonts.map): cannot open font map file
      LOG
    Guard.missing_from_log(log).map(&.name).should eq [
      "lipsum.sty", "glyphtounicode", "ecrm1000.tfm", "jkpmn8r.tfm", "kp-ts1.enc", "kpfonts.map",
    ]
  end

  it "recognises fontspec font misses" do
    missing = Guard.missing_from_log(%(! Package fontspec Error: The font "Libertinus Serif" cannot be found;))
    missing.should eq [Guard::Missing.new(Guard::Missing::Kind::Font, "Libertinus Serif")]
  end

  it "maps unknown babel languages to their .ldf file" do
    log = "babel.sty:4478: Package babel Error: Unknown option 'turkish'."
    Guard.missing_from_log(log).map(&.name).should eq ["turkish.ldf"]
  end

  it "detects when another pass is needed" do
    Guard.rerun_needed?("LaTeX Warning: Label(s) may have changed. Rerun to get cross-references right.").should be_true
    Guard.rerun_needed?("Output written on main.pdf (1 page, 1234 bytes).").should be_false
  end

  it "shows the first error with context" do
    log = "This is pdfTeX\n(./main.tex\n./main.tex:4: Undefined control sequence.\nl.4 \\foo\n\nmore"
    Guard.error_excerpt(log, 2).should eq "./main.tex:4: Undefined control sequence.\nl.4 \\foo"
  end
end

describe Pomtex::Engine::Runner do
  it "reads inputs from the -recorder log, minus files the job also writes" do
    fls = <<-FLS
      PWD /home/u/thesis
      INPUT /opt/tex/texmf-dist/tex/latex/base/article.cls
      INPUT ./thesis.tex
      INPUT thesis.tex
      INPUT ./fig/logo.pdf
      INPUT /home/u/thesis/build/thesis.aux
      OUTPUT /home/u/thesis/build/thesis.aux
      OUTPUT /home/u/thesis/build/thesis.log
      FLS
    Pomtex::Engine::Runner.recorded_inputs(fls).map(&.to_s).should eq [
      "/opt/tex/texmf-dist/tex/latex/base/article.cls",
      "/home/u/thesis/thesis.tex",
      "/home/u/thesis/fig/logo.pdf",
    ]
  end
end

describe Pomtex::Engine::OfflineMissing do
  it "names every missing package in one message" do
    error = Pomtex::Engine::OfflineMissing.new(["mhchem", "chemgreek"])
    error.message.should eq "offline: missing mhchem, chemgreek (run without --offline to install)"
    error.should be_a(Pomtex::Error)
  end
end

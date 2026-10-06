require "./spec_helper"

alias Bib = Pomtex::Engine::Bibliography

# A job directory with a fake toolchain; `pending` only looks at files.
private def with_job(&)
  with_tmpdir do |dir|
    previous = ENV["POMTEX_HOME"]?
    ENV["POMTEX_HOME"] = dir.join("cache").to_s
    begin
      File.write(dir.join("paper.tex"), "")
      toolchain = Pomtex::Core::Toolchain.new(Pomtex::Core::Toolchain::Origin::Rind, dir.join("bin"))
      yield Pomtex::Engine::Runner.new(toolchain, "pdflatex", dir.join("paper.tex")), dir
    ensure
      previous ? (ENV["POMTEX_HOME"] = previous) : ENV.delete("POMTEX_HOME")
    end
  end
end

# Pretends the tool ran successfully, which records what it ran on.
private def pretend_run(tool : Bib::Tool, runner : Pomtex::Engine::Runner, dir : Path) : Nil
  File.write(dir.join("paper.bbl"), "")
  Bib.run(tool, Process.find_executable("true").not_nil!, runner).success.should be_true
end

describe Pomtex::Engine::Bibliography do
  it "does nothing for documents without a bibliography" do
    with_job do |runner, dir|
      File.write(dir.join("paper.aux"), "\\relax\n")
      Bib.pending(runner, "").should be_nil
    end
  end

  it "runs BibTeX only when citations, databases or the .bbl change" do
    with_job do |runner, dir|
      File.write(dir.join("refs.bib"), "")
      File.write(dir.join("paper.aux"), "\\citation{a}\n\\bibstyle{plain}\n\\bibdata{refs}\n")
      Bib.pending(runner, "").should eq Bib::Tool::Bibtex # no .bbl yet

      pretend_run(Bib::Tool::Bibtex, runner, dir)
      Bib.pending(runner, "").should be_nil

      File.write(dir.join("paper.aux"), "\\citation{a}\n\\citation{b}\n\\bibstyle{plain}\n\\bibdata{refs}\n")
      Bib.pending(runner, "").should eq Bib::Tool::Bibtex # new citation

      pretend_run(Bib::Tool::Bibtex, runner, dir)
      File.touch(dir.join("refs.bib"), Time.utc + 1.minute)
      Bib.pending(runner, "").should eq Bib::Tool::Bibtex # database edited
    end
  end

  it "follows citations in included .aux files" do
    with_job do |runner, dir|
      File.write(dir.join("paper.aux"), "\\bibdata{refs}\n\\@input{chapter.aux}\n")
      File.write(dir.join("chapter.aux"), "\\citation{a}\n")
      pretend_run(Bib::Tool::Bibtex, runner, dir)
      Bib.pending(runner, "").should be_nil

      File.write(dir.join("chapter.aux"), "\\citation{a}\n\\citation{c}\n")
      Bib.pending(runner, "").should eq Bib::Tool::Bibtex
    end
  end

  it "runs Biber when biblatex asks or the .bcf changes" do
    with_job do |runner, dir|
      bcf = %(<bcf:datasource type="file" datatype="bibtex">refs.bib</bcf:datasource>\n<bcf:citekey>a</bcf:citekey>)
      File.write(dir.join("paper.bcf"), bcf)
      Bib.pending(runner, "").should eq Bib::Tool::Biber # no .bbl yet

      pretend_run(Bib::Tool::Biber, runner, dir)
      Bib.pending(runner, "").should be_nil
      Bib.pending(runner, "Package biblatex Warning: Please (re)run Biber on the file").should eq Bib::Tool::Biber

      File.write(dir.join("paper.bcf"), bcf + %(\n<bcf:citekey nocite="1">*</bcf:citekey>))
      Bib.pending(runner, "").should eq Bib::Tool::Biber # \nocite{*} gives no warning
    end
  end

  it "uses BibTeX when biblatex is configured with backend=bibtex" do
    with_job do |runner, dir|
      File.write(dir.join("paper.bcf"), "")
      Bib.pending(runner, "Please (re)run BibTeX on the file(s):").should eq Bib::Tool::Bibtex
    end
  end

  it "finds styles BibTeX could not open" do
    log = "I couldn't open style file IEEEtranN.bst\n---line 3 of file paper.aux"
    Bib.missing_styles(log).should eq ["IEEEtranN.bst"]
  end
end

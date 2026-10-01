require "./spec_helper"

private def scan(text : String) : Pomtex::Seed::ScanResult
  Pomtex::Seed::Scanner.scan_source(text) { |_| nil }
end

describe Pomtex::Seed::Scanner do
  it "collects packages, classes and libraries" do
    result = scan <<-'TEX'
      \documentclass[11pt]{scrartcl}
      \usepackage[margin=2cm,
                  top=1cm]{geometry}
      \usepackage{amsmath, booktabs}
      \RequirePackage{xcolor}
      \usetikzlibrary{cd, arrows.meta}
      \usetheme{Madrid}
      \bibliographystyle{alpha}
      TEX
    result.files.should eq Set{
      "scrartcl.cls", "geometry.sty", "amsmath.sty", "booktabs.sty", "xcolor.sty",
      "tikzlibrarycd.code.tex", "tikzlibraryarrows.meta.code.tex", "beamerthemeMadrid.sty", "alpha.bst",
    }
    result.suggested_engine.should eq "pdflatex"
  end

  it "ignores commented-out packages but keeps escaped percent signs" do
    result = scan "\\usepackage{a} % \\usepackage{b}\n50\\% \\usepackage{c}\n%\\usepackage{d}\n"
    result.files.should eq Set{"a.sty", "c.sty"}
  end

  it "skips macro arguments it cannot evaluate" do
    scan("\\usepackage{\\mypkg}").files.should be_empty
  end

  it "detects fonts and the Unicode engine" do
    result = scan "\\usepackage{fontspec}\n\\setmainfont{TeX Gyre Pagella}[Scale=1]\n\\newfontfamily\\code[Scale=0.9]{Fira Mono}"
    result.fonts.should eq Set{"TeX Gyre Pagella", "Fira Mono"}
    result.suggested_engine.should eq "xelatex"
  end

  it "requests babel language definitions" do
    scan("\\usepackage[shorthands=off, english, main=turkish]{babel}").files.should eq Set{
      "babel.sty", "english.ldf", "turkish.ldf",
    }
    scan("\\usepackage[safe=none,silent]{babel}").files.should eq Set{"babel.sty"}
  end

  it "expands tcolorbox library styles once tcolorbox.sty defines them" do
    result = scan("\\usepackage[most]{tcolorbox}\n\\tcbuselibrary{theorems}")
    result.files.should eq Set{"tcolorbox.sty", "tcbtheorems.code.tex"} # `most` is not known yet

    Pomtex::Seed::Scanner.scan_source(<<-'STY', result) { nil }
      \tcb@add@library@style{many}{skins,breakable}
      \tcb@add@library@style{most}{many,listingsutf8}
      STY
    result.files.should eq Set{
      "tcolorbox.sty", "tcbtheorems.code.tex", "tcbskins.code.tex", "tcbbreakable.code.tex", "tcblistingsutf8.code.tex",
    }
  end

  it "follows only top-level loads in package code" do
    source = <<-'STY'
      \RequirePackage{pdfcol}
      \ifpdftex
        \RequirePackage{listingsutf8}[2011/11/10]
      \fi
      \gdef\pgfplots@glob@TMPa{\RequirePackage{luatexbase}}%
      \pgfutil@ifl@t@r\fmtversion{2020/10/01}{\AddToHook{x}{}}{%
        \RequirePackage{everyshi}
      }
      \InputIfFileExists{tcolorbox.cfg}{}{}
      STY
    result = Pomtex::Seed::Scanner.scan_source(source, top_level_only: true) { nil }
    result.files.should eq Set{"pdfcol.sty", "listingsutf8.sty"}
    Pomtex::Seed::Scanner.scan_source(source) { nil }.files.size.should eq 4
  end

  it "honours the magic program comment and lua markers" do
    scan("% !TEX program = LuaLaTeX\n\\documentclass{article}").suggested_engine.should eq "lualatex"
    scan("\\directlua{tex.print(1)}").suggested_engine.should eq "lualatex"
  end

  it "requests non-local \\input files and follows local ones" do
    with_tmpdir do |dir|
      File.write(dir.join("main.tex"), "\\documentclass{article}\\input{chapter}\\input{glyphtounicode}")
      File.write(dir.join("chapter.tex"), "\\usepackage{listings}\\include{sub/part}")
      Dir.mkdir_p(dir.join("sub"))
      File.write(dir.join("sub", "part.tex"), "\\usepackage{mystyle}")
      File.write(dir.join("mystyle.sty"), "\\RequirePackage{enumitem}")

      result = Pomtex::Seed::Scanner.scan(dir.join("main.tex"))
      result.files.should eq Set{"article.cls", "listings.sty", "glyphtounicode.tex", "enumitem.sty"}
      result.sources.map(&.basename).should eq ["main.tex", "chapter.tex", "part.tex", "mystyle.sty"]
    end
  end
end

describe "Pomtex::Seed::Scanner assets" do
  it "resolves graphics, bibliographies and listings like LaTeX does" do
    with_tmpdir do |dir|
      Dir.mkdir_p(dir.join("fig"))
      Dir.mkdir_p(dir.join("chapters"))
      Dir.mkdir_p(dir.join("code"))
      File.write(dir.join("main.tex"), <<-'TEX')
        \documentclass{article}
        \usepackage{graphicx}
        \graphicspath{{fig/}{img/}}
        \begin{document}
        \includegraphics[width=3cm]{logo}
        \input{chapters/one}
        \bibliography{refs,extra}
        \lstinputlisting[language=C]{code/main.c}
        \includegraphics{\jobname-missing}
        % \includegraphics{commented}
        \end{document}
        TEX
      File.write(dir.join("chapters", "one.tex"), "\\includegraphics{plot.png}\n\\addbibresource{chapters/more.bib}")
      File.write(dir.join("fig", "logo.pdf"), "")
      File.write(dir.join("chapters", "plot.png"), "")
      File.write(dir.join("refs.bib"), "")
      File.write(dir.join("chapters", "more.bib"), "")
      File.write(dir.join("code", "main.c"), "")
      File.write(dir.join("commented.png"), "")

      assets = Pomtex::Seed::Scanner.scan(dir.join("main.tex")).assets.map(&.relative_to(dir).to_s)
      # extra.bib does not exist, so it is not watched
      assets.sort.should eq ["chapters/more.bib", "chapters/plot.png", "code/main.c", "fig/logo.pdf", "refs.bib"]
    end
  end
end

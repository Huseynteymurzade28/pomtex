require "./spec_helper"
require "../src/help"

HELP = <<-TEXT
  pomtex 1.0.0 — the pomegranate TeX engine: a featherlight rind, arils on demand.

  Usage:
    pomtex build <file.tex>        compile, fetching missing packages on the fly
    pomtex remove <aril>...        uproot arils
    pomtex completions <shell>     print completions for bash, fish or zsh

  Options:
      -e ENGINE, --engine=ENGINE       pdflatex | xelatex | lualatex (default: auto-detect)
          --offline                    Never touch the network
          --debounce=MS                watch: quiet period before rebuilding
      -v, --verbose                    Explain every decision

  Environment:
      POMTEX_HOME                      where pomtex keeps its data
  TEXT

describe Pomtex::Help do
  it "reads commands, options and variables from the help text" do
    Pomtex::Help.commands(HELP).map(&.name).should eq ["build", "remove", "completions"]
    Pomtex::Help.commands(HELP).first.args.should eq "<file.tex>"
    Pomtex::Help.options(HELP).should eq [
      Pomtex::Help::Option.new('e', "engine", "ENGINE", "pdflatex | xelatex | lualatex (default: auto-detect)"),
      Pomtex::Help::Option.new(nil, "offline", nil, "Never touch the network"),
      Pomtex::Help::Option.new(nil, "debounce", "MS", "watch: quiet period before rebuilding"),
      Pomtex::Help::Option.new('v', "verbose", nil, "Explain every decision"),
    ]
    Pomtex::Help.variables(HELP).should eq [Pomtex::Help::Variable.new("POMTEX_HOME", "where pomtex keeps its data")]
  end

  it "completes every command and option in each shell" do
    fish = Pomtex::Help.completion("fish", HELP)
    fish.should contain "-a remove -d 'uproot arils'"
    fish.should contain "-s e -l engine -x -a 'pdflatex xelatex lualatex'"
    fish.should contain "__fish_seen_subcommand_from remove' -a '(pomtex list --names 2>/dev/null)'"

    bash = Pomtex::Help.completion("bash", HELP)
    bash.should contain %(local commands="build remove completions")
    bash.should contain "--engine= --offline --debounce= -v --verbose"

    zsh = Pomtex::Help.completion("zsh", HELP)
    zsh.should contain "'(-e --engine)'{-e+,--engine=}'[pdflatex | xelatex | lualatex (default: auto-detect)]:engine:(pdflatex xelatex lualatex)'"
    zsh.should contain "completions) compadd bash fish zsh ;;"

    expect_raises(Pomtex::Error, /unknown shell/) { Pomtex::Help.completion("tcsh", HELP) }
  end

  it "renders a man page" do
    man = Pomtex::Help.man(HELP)
    man.should contain "pomtex \\- the pomegranate TeX engine: a featherlight rind, arils on demand\n"
    man.should contain "\\fBbuild\\fR \\fI<file.tex>\\fR\n"
    man.should contain "\\fB\\-e\\fR, \\fB\\-\\-engine\\fR=\\fIENGINE\\fR\n"
    man.should contain ".SH ENVIRONMENT\n.TP\n.B POMTEX_HOME\n"
  end
end

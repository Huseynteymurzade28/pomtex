require "./spec_helper"
require "../src/core/update_check"

describe Pomtex::Core::UpdateCheck do
  it "compares versions numerically" do
    check = Pomtex::Core::UpdateCheck
    check.newer?("0.2.0", "0.1.3").should be_true
    check.newer?("0.10.0", "0.9.1").should be_true
    check.newer?("v1.0", "0.9.9").should be_true
    check.newer?("0.2.0", "0.2.0").should be_false
    check.newer?("0.1.9", "0.2.0").should be_false
    check.newer?("0.2.0-rc1", "0.2.0").should be_false
  end

  it_unix "points non-package installs at the release page" do
    Pomtex::Core::UpdateCheck.upgrade_hint("/nonexistent/pomtex").should eq "https://github.com/Huseynteymurzade28/pomtex/releases/latest"
  end

  {% if flag?(:win32) %}
    it "points Windows installs at install.ps1" do
      Pomtex::Core::UpdateCheck.upgrade_hint("C:/nonexistent/pomtex.exe").should eq "irm https://raw.githubusercontent.com/Huseynteymurzade28/pomtex/main/install.ps1 | iex"
    end
  {% end %}

  it_unix "recognises Homebrew installs" do
    Pomtex::Core::UpdateCheck.upgrade_hint("/opt/homebrew/Cellar/pomtex/0.3.2/bin/pomtex").should eq "brew upgrade pomtex"
  end
end

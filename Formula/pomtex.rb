class Pomtex < Formula
  desc "On-demand LaTeX: portable TeX kernel that installs CTAN packages when needed"
  homepage "https://github.com/Huseynteymurzade28/pomtex"
  url "https://github.com/Huseynteymurzade28/pomtex/archive/refs/tags/v0.3.2.tar.gz"
  sha256 "89e17b70290dc859d45dcb3324cb3f870876f4c54ead174d5730f58cc2b62f0d"
  license "MIT"
  head "https://github.com/Huseynteymurzade28/pomtex.git", branch: "main"

  depends_on "crystal" => :build
  depends_on "bdw-gc"
  depends_on "openssl@3"
  depends_on "pcre2"
  depends_on "xz"

  uses_from_macos "zlib"

  def install
    system "crystal", "build", "src/pomtex.cr", "-o", "pomtex", "--release", "--no-debug"
    bin.install "pomtex"
    generate_completions_from_executable(bin/"pomtex", "completions")
    (man1/"pomtex.1").write Utils.safe_popen_read(bin/"pomtex", "manpage")
  end

  def caveats
    <<~EOS
      The first build downloads the portable TeX kernel (about 65 MB) into
      ~/.cache/pomtex; packages are fetched from CTAN as documents need them.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/pomtex --version")
    (testpath/"hello.tex").write <<~TEX
      \\documentclass{article}
      \\usepackage{booktabs}
      \\begin{document}
      Hello.
      \\end{document}
    TEX
    assert_match "booktabs.sty", shell_output("#{bin}/pomtex scan --offline hello.tex 2>&1")
  end
end

require "path"

# Paths, constants and seed metadata shared by every pomtex component.
#
# Layout under the cache root (default `~/.cache/pomtex`, honours `$XDG_CACHE_HOME`):
#
#     rind/         the portable TeX kernel (TinyTeX-1), bin/x86_64-linux/...
#     texmf/        the user texmf tree that arils are unpacked into
#     downloads/    in-flight and verified archives
#     index/        the file -> package index built from texlive.tlpdb
#     arils/        one manifest per installed aril
module Pomtex
  VERSION = "0.2.0"

  module Config
    extend self

    PLATFORM = "x86_64-linux"
    REPO     = "Huseynteymurzade28/pomtex"

    # TeX Live network repository; every aril is `<mirror>/archive/<name>.tar.xz`.
    DEFAULT_MIRROR = "https://mirror.ctan.org/systems/texlive/tlnet"

    # The rind: a TinyTeX-1 bundle, which ships pdftex/xetex/luatex binaries and prebuilt formats.
    RIND_REPO             = "rstudio/tinytex-releases"
    RIND_PINNED_VERSION   = "v2026.10"
    RIND_ARCHIVE_TEMPLATE = "TinyTeX-1-linux-x86_64-%s.tar.xz"
    RIND_TOP_DIR          = ".TinyTeX"

    DEFAULT_JOBS          =  6
    MAX_GUARD_ROUNDS      =  8
    MAX_RERUN_PASSES      =  3
    MAX_PREFETCH_ROUNDS   = 10
    MAX_BIBLIOGRAPHY_RUNS =  2
    DEFAULT_DEBOUNCE      = 350.milliseconds
    WATCH_POLL_PERIOD     = 200.milliseconds

    # Packages that are never worth fetching as arils: meta packages and pure binaries.
    SKIP_PACKAGE_PREFIXES = {"collection-", "scheme-", "texlive.infra", "00texlive"}

    # Seed metadata: well-known file -> package mappings, used before the index is
    # available (first run, --offline) so that the most common documents still resolve.
    SEED_HINTS = {
      "tikz.sty"      => "pgf",
      "pgf.sty"       => "pgf",
      "amsmath.sty"   => "amsmath",
      "amssymb.sty"   => "amsfonts",
      "amsthm.sty"    => "amscls",
      "graphicx.sty"  => "graphics",
      "hyperref.sty"  => "hyperref",
      "xcolor.sty"    => "xcolor",
      "geometry.sty"  => "geometry",
      "booktabs.sty"  => "booktabs",
      "fontspec.sty"  => "fontspec",
      "biblatex.sty"  => "biblatex",
      "listings.sty"  => "listings",
      "siunitx.sty"   => "siunitx",
      "pgfplots.sty"  => "pgfplots",
      "tcolorbox.sty" => "tcolorbox",
      "beamer.cls"    => "beamer",
      "enumitem.sty"  => "enumitem",
      "microtype.sty" => "microtype",
      "cleveref.sty"  => "cleveref",
      "minted.sty"    => "minted",
      "ecrm1000.tfm"  => "ec",
    }

    # Packages whose presence forces a Unicode engine.
    XETEX_TRIGGERS = {"fontspec", "unicode-math", "polyglossia", "xeCJK", "xunicode"}

    def cache_root : Path
      if custom = ENV["POMTEX_HOME"]?.presence
        return Path[custom].expand(home: true)
      end
      base = ENV["XDG_CACHE_HOME"]?.presence || Path.home.join(".cache").to_s
      Path[base].expand(home: true).join("pomtex")
    end

    def rind_dir : Path
      cache_root.join("rind")
    end

    def rind_bin_dir : Path
      rind_dir.join("bin", PLATFORM)
    end

    def texmf_dir : Path
      cache_root.join("texmf")
    end

    def downloads_dir : Path
      cache_root.join("downloads")
    end

    def index_dir : Path
      cache_root.join("index")
    end

    def index_file : Path
      index_dir.join("files.idx")
    end

    # One `<name>.list` per installed aril: a `maps:` header, then its files.
    def arils_dir : Path
      cache_root.join("arils")
    end

    def mirror : String
      (ENV["POMTEX_MIRROR"]?.presence || DEFAULT_MIRROR).rchop('/')
    end

    def aril_url(package : String) : String
      "#{mirror}/archive/#{package}.tar.xz"
    end

    def tlpdb_url : String
      "#{mirror}/tlpkg/texlive.tlpdb.xz"
    end

    def rind_url(version : String) : String
      ENV["POMTEX_RIND_URL"]?.presence ||
        "https://github.com/#{RIND_REPO}/releases/download/#{version}/#{RIND_ARCHIVE_TEMPLATE % version}"
    end

    def ensure_dirs : Nil
      {cache_root, texmf_dir, downloads_dir, index_dir, arils_dir}.each { |dir| Dir.mkdir_p(dir) }
    end

    # Meta packages and other platforms' binaries are never planted. Binary
    # packages for this platform (e.g. biber.x86_64-linux) are, on request.
    def skip_package?(name : String) : Bool
      return false if name.ends_with?(".#{PLATFORM}")
      name.includes?('.') || SKIP_PACKAGE_PREFIXES.any? { |prefix| name.starts_with?(prefix) }
    end

    # Executables planted from binary arils.
    def aril_bin_dir : Path
      texmf_dir.join("bin", PLATFORM)
    end
  end
end

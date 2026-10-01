require "../config"

module Pomtex::Core
  # A usable TeX installation: either the user's system TeX or the pomtex rind.
  struct Toolchain
    enum Origin
      System
      Rind
    end

    ENGINES = {"pdflatex", "xelatex", "lualatex"}

    getter origin : Origin
    getter bin_dir : Path

    def initialize(@origin, @bin_dir)
    end

    def executable(name : String) : String?
      candidate = bin_dir.join(name)
      File::Info.executable?(candidate) ? candidate.to_s : nil
    end

    def kpsewhich : String
      executable("kpsewhich") || raise Error.new("kpsewhich missing from #{bin_dir}")
    end

    def engines : Array(String)
      ENGINES.select { |engine| executable(engine) }.to_a
    end

    def has_engine?(engine : String) : Bool
      !executable(engine).nil?
    end

    # Asks kpathsea which of `files` it can already see (with the aril tree mounted
    # through `env`). Returns the subset of names that resolved.
    def locate(files : Enumerable(String), env : Hash(String, String)) : Set(String)
      lookup(files, env).keys.to_set
    end

    # Like `locate`, but maps each name kpathsea resolved to its full path.
    def lookup(files : Enumerable(String), env : Hash(String, String)) : Hash(String, String)
      found = {} of String => String
      names = files.to_a.uniq
      return found if names.empty?

      names.each_slice(200) do |slice|
        output = IO::Memory.new
        Process.run(kpsewhich, slice, env: env, output: output, error: Process::Redirect::Close)
        output.to_s.each_line do |line|
          path = line.strip
          next if path.empty?
          base = File.basename(path)
          # `\input{chapter}` asks for "chapter" but kpathsea answers with chapter.tex.
          slice.each { |name| found[name] ||= path if name == base || "#{name}.tex" == base }
        end
      end
      found
    end

    def to_s(io : IO) : Nil
      io << origin.to_s.downcase << " TeX (" << bin_dir << ")"
    end
  end

  # Looks for an existing pdflatex/kpsewhich on the system, then for the rind.
  module Detector
    extend self

    def system_toolchain : Toolchain?
      pdflatex = Process.find_executable("pdflatex")
      kpsewhich = Process.find_executable("kpsewhich")
      return nil unless pdflatex && kpsewhich

      # Resolve symlinks (e.g. /usr/bin/pdflatex -> pdftex) only for the directory.
      bin = Path[pdflatex].parent
      return nil unless Path[kpsewhich].parent == bin || File::Info.executable?(bin.join("kpsewhich"))
      Toolchain.new(Toolchain::Origin::System, bin)
    end

    def rind_toolchain : Toolchain?
      bin = Config.rind_bin_dir
      return nil unless File::Info.executable?(bin.join("pdflatex")) && File::Info.executable?(bin.join("kpsewhich"))
      Toolchain.new(Toolchain::Origin::Rind, bin)
    end

    def rind_present? : Bool
      !rind_toolchain.nil?
    end

    # `prefer_rind` forces the portable kernel even when a system TeX exists.
    def detect(prefer_rind : Bool = false) : Toolchain?
      prefer_rind = true if ENV["POMTEX_USE_RIND"]?.presence
      if prefer_rind
        rind_toolchain || system_toolchain
      else
        system_toolchain || rind_toolchain
      end
    end
  end
end

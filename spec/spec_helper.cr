require "spec"
require "file_utils"
require "../src/config"
require "../src/ui"
require "../src/core/detector"
require "../src/core/cache_lock"
require "../src/seed/scanner"
require "../src/seed/resolver"
require "../src/seed/extractor"
require "../src/engine/runner"
require "../src/engine/runtime_guard"

def with_tmpdir(&)
  dir = Path[Dir.tempdir].join("pomtex-spec-#{Random.new.hex(6)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

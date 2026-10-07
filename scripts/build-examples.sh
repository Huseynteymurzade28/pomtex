#!/bin/sh
# Compiles every document in examples/ with the pomtex rind, then fonts.tex once
# more under LuaLaTeX so all three engines run. Fails if any build fails or
# leaves no PDF. Set POMTEX_HOME to start from an empty texmf/.
set -u

POMTEX=${POMTEX:-bin/pomtex}
failed=""

build() { # <file.tex> <pdf> [pomtex options...]
  tex=$1 pdf=$2
  shift 2
  echo "::group::$tex $*"
  rm -f "$pdf"
  if "$POMTEX" build --rind "$@" "$tex" && test -s "$pdf"; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "::error file=$tex::build failed or produced no PDF ($*)"
    failed="$failed $tex($*)"
  fi
}

for tex in $(grep -l '^\\documentclass' examples/*/*.tex); do
  build "$tex" "${tex%.tex}.pdf"
done
build examples/fonts/fonts.tex examples/fonts/lualatex/fonts.pdf -e lualatex -o examples/fonts/lualatex

if [ -n "$failed" ]; then
  echo "failed:$failed" >&2
  exit 1
fi
echo "all examples built"

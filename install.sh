#!/bin/sh
# Install the latest pomtex release.
#
#   curl -fsSL https://raw.githubusercontent.com/Huseynteymurzade28/pomtex/main/install.sh | sh
#
# On Debian/Ubuntu and Fedora/openSUSE this installs the .deb or .rpm with the
# system package manager (needs sudo). Elsewhere, or with POMTEX_LOCAL=1, it
# unpacks the static binary into ~/.local (override with PREFIX=/some/dir).
# POMTEX_VERSION=0.3.1 pins a release instead of the latest one.
set -eu

REPO="Huseynteymurzade28/pomtex"

say() { printf 'pomtex: %s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

fetch() {
  if has curl; then
    curl -fsSL -o "$2" "$1"
  elif has wget; then
    wget -qO "$2" "$1"
  else
    die "curl or wget is required"
  fi
}

# Follows the /releases/latest redirect, which avoids the GitHub API rate limit.
latest_version() {
  if has curl; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
  else
    url=$(wget -q --max-redirect=5 -S --spider "https://github.com/$REPO/releases/latest" 2>&1 |
      sed -n 's/^ *[Ll]ocation: *//p' | tail -n 1)
  fi
  tag=${url##*/}
  tag=$(printf '%s' "$tag" | tr -d '\r')
  case $tag in
    v[0-9]*) printf '%s\n' "${tag#v}" ;;
    *) die "could not determine the latest release (got '$url')" ;;
  esac
}

verify() {
  # $1 = file, $2 = its .sha256 (format: "<hash>  <name>")
  expected=$(cut -d' ' -f1 "$2")
  if has sha256sum; then
    actual=$(sha256sum "$1" | cut -d' ' -f1)
  elif has shasum; then
    actual=$(shasum -a 256 "$1" | cut -d' ' -f1)
  else
    say "warning: no sha256sum, skipping checksum verification"
    return 0
  fi
  [ "$expected" = "$actual" ] || die "checksum mismatch for $(basename "$1")"
}

download() {
  # $1 = asset name; downloads it and its checksum into $tmp and verifies it.
  base="https://github.com/$REPO/releases/download/v$version"
  say "downloading $1"
  fetch "$base/$1" "$tmp/$1"
  fetch "$base/$1.sha256" "$tmp/$1.sha256"
  verify "$tmp/$1" "$tmp/$1.sha256"
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif has sudo; then
    sudo "$@"
  elif has doas; then
    doas "$@"
  else
    die "need root to run '$*' (or rerun with POMTEX_LOCAL=1)"
  fi
}

install_deb() {
  pkg="pomtex_${version}-1_${debarch}.deb"
  download "$pkg"
  as_root apt-get install -y "$tmp/$pkg"
}

install_rpm() {
  pkg="pomtex-${version}-1.${arch}.rpm"
  download "$pkg"
  if has zypper; then
    as_root zypper --non-interactive install --allow-unsigned-rpm "$tmp/$pkg"
  elif has dnf; then
    as_root dnf install -y "$tmp/$pkg"
  else
    as_root rpm -U --replacepkgs "$tmp/$pkg"
  fi
}

install_local() {
  prefix=${PREFIX:-$HOME/.local}
  name="pomtex-$version-linux-$arch"
  download "$name.tar.gz"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
  src="$tmp/$name"
  mkdir -p "$prefix/bin" "$prefix/share/man/man1" \
    "$prefix/share/bash-completion/completions" \
    "$prefix/share/fish/vendor_completions.d" \
    "$prefix/share/zsh/site-functions"
  cp "$src/pomtex" "$prefix/bin/pomtex.new" && chmod 755 "$prefix/bin/pomtex.new"
  mv -f "$prefix/bin/pomtex.new" "$prefix/bin/pomtex"
  cp "$src/share/pomtex.1" "$prefix/share/man/man1/pomtex.1"
  cp "$src/share/pomtex.bash" "$prefix/share/bash-completion/completions/pomtex"
  cp "$src/share/pomtex.fish" "$prefix/share/fish/vendor_completions.d/pomtex.fish"
  cp "$src/share/pomtex.zsh" "$prefix/share/zsh/site-functions/_pomtex"
  say "installed to $prefix/bin/pomtex"
  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) say "note: $prefix/bin is not on your PATH; add it in your shell profile" ;;
  esac
}

main() {
  case $(uname -s) in
    Linux) ;;
    Darwin) die "on macOS, install with Homebrew: brew install Huseynteymurzade28/pomtex/pomtex" ;;
    *) die "unsupported system: $(uname -s)" ;;
  esac
  case $(uname -m) in
    x86_64 | amd64) arch=x86_64 debarch=amd64 ;;
    aarch64 | arm64) arch=aarch64 debarch=arm64 ;;
    *) die "unsupported architecture: $(uname -m) (pomtex runs on x86_64 and aarch64)" ;;
  esac

  version=${POMTEX_VERSION:-$(latest_version)}
  version=${version#v}
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT INT TERM

  if [ "${POMTEX_LOCAL:-0}" = 1 ] || [ -n "${PREFIX:-}" ]; then
    install_local
  elif has pacman; then
    say "on Arch Linux, prefer the AUR: yay -S pomtex-bin"
    install_local
  elif has apt-get && has dpkg; then
    install_deb
  elif has rpm && { has zypper || has dnf || has yum; }; then
    install_rpm
  else
    install_local
  fi

  has xz || say "warning: xz is not installed; pomtex needs it to unpack TeX Live packages"
  say "done: $("${prefix:-/usr}/bin/pomtex" --version 2>/dev/null || echo "pomtex $version")"
}

main "$@"

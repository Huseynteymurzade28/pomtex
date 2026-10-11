# Install the latest pomtex release on Windows (x86_64).
#
#   irm https://raw.githubusercontent.com/Huseynteymurzade28/pomtex/main/install.ps1 | iex
#
# Unpacks pomtex.exe into %LOCALAPPDATA%\Programs\pomtex (override with
# POMTEX_INSTALL_DIR) and adds that directory to the user PATH. Run it again to
# update. POMTEX_VERSION=0.4.0 pins a release instead of the latest one, and
# POMTEX_ZIP=<path> installs from a local release zip.
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue' # Invoke-WebRequest crawls with a progress bar
  $repo = 'Huseynteymurzade28/pomtex'

  function Say($message) { Write-Host "pomtex: $message" }

  $dir = if ($env:POMTEX_INSTALL_DIR) { $env:POMTEX_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\pomtex' }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "pomtex-install-$PID"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    if ($env:POMTEX_ZIP) {
      $zip = $env:POMTEX_ZIP
    } else {
      $tag = if ($env:POMTEX_VERSION) { "v$($env:POMTEX_VERSION.TrimStart('v'))" } else {
        (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing).tag_name
      }
      $name = "pomtex-$($tag.TrimStart('v'))-windows-x86_64.zip"
      $base = "https://github.com/$repo/releases/download/$tag"
      $zip = Join-Path $tmp $name
      Say "downloading $name"
      Invoke-WebRequest "$base/$name" -OutFile $zip -UseBasicParsing
      Invoke-WebRequest "$base/$name.sha256" -OutFile "$zip.sha256" -UseBasicParsing
      $expected = ((Get-Content "$zip.sha256" -Raw).Trim() -split '\s+')[0]
      if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $expected) { throw "checksum mismatch for $name" }
    }

    Expand-Archive $zip -DestinationPath (Join-Path $tmp 'unpacked') -Force
    $exe = Get-ChildItem (Join-Path $tmp 'unpacked') -Recurse -Filter 'pomtex.exe' | Select-Object -First 1
    if (-not $exe) { throw "no pomtex.exe in $zip" }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item (Join-Path $exe.DirectoryName '*') $dir -Recurse -Force
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = if ($userPath) { $userPath -split ';' } else { @() }
  if ($entries -notcontains $dir) {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $dir) -join ';'), 'User')
    Say "added $dir to your PATH; open a new terminal to use it"
  }
  if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$env:Path;$dir" }

  Say "installed $(& (Join-Path $dir 'pomtex.exe') --version) to $dir"
}

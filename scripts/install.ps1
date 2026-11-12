# UltraTerm Computer Use installer for Windows:  irm https://github.com/your-org/ultraterm-computer-use/releases/latest/download/install.ps1 | iex
# Downloads the release npm tarball (native runtimes for win-x64 and win-arm64), checks its SHA-256, installs it under
# %LOCALAPPDATA%\UltraTermComputerUse, and puts an ultraterm-computer-use.cmd shim on your user Path.
# Uses the Node 18+ already on this machine, or fetches the official Node 22 LTS into the tool's own folder.
# Also runs under PowerShell 7 on Linux for testing, with UTCU_HOME / UTCU_BIN_DIR overrides.
# Environment: UTCU_HOME, UTCU_BIN_DIR, UTCU_VERSION (pin a version, e.g. 0.6.1), UTCU_RELEASE_BASE (test override).
$ErrorActionPreference = 'Stop'

function Get-RemoteFile {
  param([string]$Url, [string]$Destination)
  try {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
  } catch {
    throw "download failed: $Url ($($_.Exception.Message))"
  }
}

function Test-Checksum {
  param([string]$Path, [string]$Name, [hashtable]$Sums)
  if (-not $Sums.ContainsKey($Name)) { throw "no checksum for $Name in SHA256SUMS" }
  $got = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $Sums[$Name]) { throw "checksum mismatch for $Name; nothing was installed" }
}

function Test-NodeVersion {
  param([string]$Node, [int]$MinMajor)
  try {
    $v = & $Node -p 'process.versions.node' 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if ("$v" -match '^(\d+)\.') { return ([int]$Matches[1] -ge $MinMajor) }
    return $false
  } catch { return $false }
}

function Test-NpmVersion {
  param([string]$Npm)
  try {
    $v = (& $Npm --version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($v -match '^\d+\.\d+')
  } catch { return $false }
}

function Install-UltraTermComputerUse {
  $repo = 'your-org/ultraterm-computer-use'
  $nodeMinMajor = 18
  $isWin = if ($PSVersionTable.PSEdition -eq 'Core') { $IsWindows } else { $true }
  if (-not $isWin -and $IsMacOS) {
    throw 'On macOS use install.sh (it points at the signed .pkg) or install.sh --npm; nothing was installed.'
  }

  $homeDir = $env:UTCU_HOME
  if (-not $homeDir) {
    $homeDir = if ($isWin) { Join-Path $env:LOCALAPPDATA 'UltraTermComputerUse' } else { Join-Path $HOME '.ultraterm-computer-use' }
  }
  $binDir = $env:UTCU_BIN_DIR
  if (-not $binDir) {
    $binDir = if ($isWin) { Join-Path $homeDir 'bin' } else { Join-Path $HOME '.local/bin' }
  }
  $base = if ($env:UTCU_RELEASE_BASE) { $env:UTCU_RELEASE_BASE }
    elseif ($env:UTCU_VERSION) { "https://github.com/$repo/releases/download/v$($env:UTCU_VERSION.TrimStart('v'))" }
    else { "https://github.com/$repo/releases/latest/download" }

  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    throw 'needs tar (bundled with Windows 10 1803+ and most Linux systems); install it, then run this again'
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('utcu-install-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $stage = $null
  try {
    Write-Host 'Downloading UltraTerm Computer Use release info...'
    $sumsPath = Join-Path $tmp 'SHA256SUMS'
    Get-RemoteFile -Url "$base/SHA256SUMS" -Destination $sumsPath
    $sums = @{}
    foreach ($line in Get-Content $sumsPath) {
      if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$') { $sums[$Matches[2]] = $Matches[1].ToLower() }
    }
    if ($env:UTCU_VERSION) {
      $tarName = "ultraterm-computer-use-$($env:UTCU_VERSION.TrimStart('v')).tgz"
    } else {
      $candidates = @($sums.Keys | Where-Object { $_ -match '^ultraterm-computer-use-[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?\.tgz$' })
      if ($candidates.Count -ne 1) { throw "SHA256SUMS lists $($candidates.Count) release tarballs; set UTCU_VERSION to pick one" }
      $tarName = $candidates[0]
    }
    $tgz = Join-Path $tmp $tarName
    Get-RemoteFile -Url "$base/$tarName" -Destination $tgz
    Test-Checksum -Path $tgz -Name $tarName -Sums $sums

    & tar -xzf $tgz -C $tmp 'package/package.json'
    if ($LASTEXITCODE -ne 0) { throw 'cannot unpack the download' }
    $pkgJson = Join-Path $tmp 'package/package.json'
    if (-not (Test-Path $pkgJson)) { throw 'the download is not an UltraTerm Computer Use release' }
    $version = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
    if (-not $version) { throw 'cannot read the release version' }
    if ($tarName -ne "ultraterm-computer-use-$version.tgz") { throw "release name $tarName does not match its version $version" }

    # Node: the one on PATH when it is new enough, else the official build, kept inside the tool's own folder.
    $nodeBin = 'node'
    $npmBin = 'npm'
    $nodeOk = $false
    if (Get-Command node -ErrorAction SilentlyContinue) { $nodeOk = Test-NodeVersion -Node 'node' -MinMajor $nodeMinMajor }
    if (-not $nodeOk) {
      if ($isWin) {
        $os = 'win'; $ext = 'zip'
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
          'AMD64' { 'x64' }
          'ARM64' { 'arm64' }
          default { throw "unsupported CPU $env:PROCESSOR_ARCHITECTURE" }
        }
      } else {
        $os = 'linux'; $ext = 'tar.gz'
        $machine = (& uname -m).Trim()
        $arch = switch ($machine) {
          'x86_64' { 'x64' }
          'aarch64' { 'arm64' }
          'arm64' { 'arm64' }
          default { throw "unsupported CPU $machine" }
        }
      }
      $runtimeDir = Join-Path $homeDir 'runtime'
      $nodeDir = $null
      if (Test-Path $runtimeDir) {
        foreach ($d in Get-ChildItem -Path $runtimeDir -Directory -Filter "node-*-$os-$arch") {
          $probe = if ($isWin) { Join-Path $d.FullName 'node.exe' } else { Join-Path $d.FullName 'bin/node' }
          if ((Test-Path $probe) -and (Test-NodeVersion -Node $probe -MinMajor $nodeMinMajor)) { $nodeDir = $d.FullName; break }
        }
      }
      if (-not $nodeDir) {
        Write-Host "Node $nodeMinMajor or newer not found; fetching the official Node 22 LTS for $os-$arch..."
        $nbase = 'https://nodejs.org/dist/latest-v22.x'
        $nsumsPath = Join-Path $tmp 'SHASUMS256.txt'
        Get-RemoteFile -Url "$nbase/SHASUMS256.txt" -Destination $nsumsPath
        $nname = $null
        $nsums = @{}
        foreach ($line in Get-Content $nsumsPath) {
          if ($line -match '^([0-9a-fA-F]{64})\s+(\S+)$') {
            $nsums[$Matches[2]] = $Matches[1].ToLower()
            if ($Matches[2].EndsWith("-$os-$arch.$ext")) { $nname = $Matches[2] }
          }
        }
        if (-not $nname) { throw "no official Node build for $os-$arch" }
        $npath = Join-Path $tmp $nname
        Get-RemoteFile -Url "$nbase/$nname" -Destination $npath
        Test-Checksum -Path $npath -Name $nname -Sums $nsums
        $nver = ($nname -replace '^node-v', '') -replace '-.*$', ''
        New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
        $nodeDir = Join-Path $runtimeDir "node-$nver-$os-$arch"
        $nodeTmp = "$nodeDir.tmp"
        if (Test-Path $nodeTmp) { Remove-Item -Recurse -Force $nodeTmp }
        if ($isWin) {
          $expandDir = Join-Path $tmp 'node-expand'
          Expand-Archive -Path $npath -DestinationPath $expandDir
          $inner = Get-ChildItem -Path $expandDir -Directory | Select-Object -First 1
          if (-not $inner) { throw 'cannot unpack Node' }
          Move-Item -Path $inner.FullName -Destination $nodeTmp
        } else {
          New-Item -ItemType Directory -Path $nodeTmp | Out-Null
          & tar -xzf $npath -C $nodeTmp --strip-components=1
          if ($LASTEXITCODE -ne 0) { throw 'cannot unpack Node' }
        }
        if (Test-Path $nodeDir) { Remove-Item -Recurse -Force $nodeDir }
        Move-Item -Path $nodeTmp -Destination $nodeDir
      }
      $nodeBin = if ($isWin) { Join-Path $nodeDir 'node.exe' } else { Join-Path $nodeDir 'bin/node' }
      $npmBin = if ($isWin) { Join-Path $nodeDir 'npm.cmd' } else { Join-Path $nodeDir 'bin/npm' }
      if (-not (Test-NodeVersion -Node $nodeBin -MinMajor $nodeMinMajor)) { throw 'the downloaded Node does not run on this machine' }
      $env:PATH = (Split-Path -Parent $nodeBin) + [IO.Path]::PathSeparator + $env:PATH
    }

    if (-not (Test-NpmVersion -Npm $npmBin)) {
      $cand = Get-Command npm -ErrorAction SilentlyContinue
      if ($cand -and (Test-NpmVersion -Npm $cand.Source)) { $npmBin = $cand.Source }
      else { throw 'no working npm found next to Node or on PATH; install Node 18+ with npm' }
    }

    Write-Host "Installing UltraTerm Computer Use $version..."
    $appDir = Join-Path $homeDir 'app'
    New-Item -ItemType Directory -Force -Path $appDir | Out-Null
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $stage = Join-Path $appDir ('.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    $env:npm_config_update_notifier = 'false'
    $env:npm_config_fund = 'false'
    $env:npm_config_audit = 'false'
    & $npmBin install --prefix $stage --no-audit --no-fund --loglevel=error $tgz
    if ($LASTEXITCODE -ne 0) { throw "npm install failed (exit $LASTEXITCODE); nothing was changed" }
    $launcher = Join-Path $stage 'node_modules/ultraterm-computer-use/bin/ultraterm-computer-use'
    if (-not (Test-Path $launcher)) { throw 'the package did not install its launcher; nothing was changed' }
    $got = (& $nodeBin $launcher --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $got -ne $version) { throw "the new copy reports '$got', not $version; nothing was changed" }

    $rel = Join-Path $appDir "release-$version"
    if (Test-Path $rel) { Remove-Item -Recurse -Force $rel }
    Move-Item -Path $stage -Destination $rel
    $stage = $null
    $launcher = Join-Path $rel 'node_modules/ultraterm-computer-use/bin/ultraterm-computer-use'

    if ($isWin) {
      $shim = Join-Path $binDir 'ultraterm-computer-use.cmd'
    } else {
      $shim = Join-Path $binDir 'ultraterm-computer-use'
    }
    if (Test-Path $shim) {
      $existing = Get-Content $shim -Raw
      if ($existing -notmatch 'UTCU_NPM_SHIM') {
        if ($existing -match 'ULTRATERM_COMPUTER_USE_MANAGED_SHIM') {
          throw "the signed macOS installer already manages $shim; remove that shim first or set UTCU_BIN_DIR to another folder"
        }
        throw "refusing to replace existing command at $shim; remove it first or set UTCU_BIN_DIR to another folder"
      }
    }
    $nodeRef = if ($nodeBin -eq 'node') { 'node' } else { $nodeBin }
    if ($isWin) {
      $cmd = "@echo off`r`nrem UTCU_NPM_SHIM`r`n`"$nodeRef`" `"$launcher`" %*`r`nexit /b %ERRORLEVEL%`r`n"
      Set-Content -Path $shim -Value $cmd -Encoding Ascii -NoNewline
    } else {
      $sh = "#!/bin/sh`n# UTCU_NPM_SHIM`nexec `"$nodeRef`" `"$launcher`" `"`$@`"`n"
      Set-Content -Path $shim -Value $sh -Encoding Ascii -NoNewline
      & chmod 755 $shim
      if ($LASTEXITCODE -ne 0) { throw "cannot mark the shim executable at $shim" }
    }

    # Keep only the release that the shim points at.
    foreach ($d in Get-ChildItem -Path $appDir -Directory -Filter 'release-*') {
      if ($d.FullName -ne $rel) { Remove-Item -Recurse -Force $d.FullName }
    }

    if ($isWin) {
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      if (-not $userPath) { $userPath = '' }
      $parts = @($userPath -split ';' | Where-Object { $_ })
      if ($parts -notcontains $binDir) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
        Write-Host "Added $binDir to your user Path; open a new terminal to pick it up."
      }
      $got = (& $shim --version 2>&1 | Out-String).Trim()
      $code = $LASTEXITCODE
    } else {
      $got = (& $shim --version 2>&1 | Out-String).Trim()
      $code = $LASTEXITCODE
      if (($env:PATH -split [IO.Path]::PathSeparator) -notcontains $binDir) {
        Write-Host "Add $binDir to your PATH:  export PATH=`"$binDir`:`$PATH`""
      }
    }
    if ($code -ne 0 -or $got -ne $version) { throw "the installed command reports '$got', not $version" }
    Write-Host "UltraTerm Computer Use $got installed ($shim)."
    $health = (& $shim doctor 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "the health check (doctor) failed: $health" }
    Write-Host $health
    Write-Host 'Next: ultraterm-computer-use list-apps'
  } finally {
    if ($stage -and (Test-Path $stage)) { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

Install-UltraTermComputerUse
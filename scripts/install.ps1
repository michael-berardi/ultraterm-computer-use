# UltraTerm Computer Use installer for Windows:  irm https://github.com/your-org/ultraterm-computer-use/releases/latest/download/install.ps1 | iex
# Downloads the release npm tarball (native runtimes for win-x64 and win-arm64), checks its SHA-256, installs it under
# %LOCALAPPDATA%\UltraTermComputerUse, and puts an ultraterm-computer-use.cmd shim on your user Path.
# Uses the Node 18+ already on this machine, or fetches the official Node 22 LTS into the tool's own folder.
# Also runs under PowerShell 7 on Linux for testing, with UTCU_HOME / UTCU_BIN_DIR overrides.
# Environment: UTCU_HOME, UTCU_BIN_DIR, UTCU_VERSION (pin a version, e.g. 0.10.1), UTCU_RELEASE_BASE (test override).
# Everything runs inside one function and ends with a single call: under `irm | iex` nothing is left behind in the
# user's session, errors are thrown (never `exit`, which would close the user's shell), and the user's
# $ErrorActionPreference / $ProgressPreference are restored.
function Install-UltraTermComputerUse {
  $prevEap = $ErrorActionPreference
  $prevProgress = $ProgressPreference
  $prevEnv = @{}
  foreach ($n in 'PATH', 'npm_config_update_notifier', 'npm_config_fund', 'npm_config_audit') { $prevEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'   # the 5.1 progress bar makes downloads and Expand-Archive very slow
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  }

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

  # Run a native program with its output captured. Windows PowerShell 5.1 turns the first stderr line of a native
  # command into a terminating error under 'Stop', so the preference is relaxed here and the exit code is checked.
  function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $text = (& $File @Arguments 2>&1 | ForEach-Object { "$_" } | Out-String).Trim()
      $code = $LASTEXITCODE
    } catch {
      $text = "$($_.Exception.Message)"
      $code = 1
    } finally {
      $ErrorActionPreference = $prev
    }
    [pscustomobject]@{ Code = $code; Output = $text }
  }

  function Test-NodeVersion {
    param([string]$Node, [int]$MinMajor)
    $r = Invoke-Native -File $Node -Arguments @('-p', 'process.versions.node')
    if ($r.Code -ne 0) { return $false }
    if ($r.Output -match '^(\d+)\.') { return ([int]$Matches[1] -ge $MinMajor) }
    return $false
  }

  function Test-NpmVersion {
    param([string]$Npm)
    $r = Invoke-Native -File $Npm -Arguments @('--version')
    if ($r.Code -ne 0) { return $false }
    return ($r.Output -match '^\d+\.\d+')
  }

  # How a shim names a file: relative to the shim (%~dp0) when the shim lives in <home>\bin and the file is under
  # <home>, so a non-ASCII profile path never has to be written into the shim; absolute otherwise.
  function Get-ShimRef {
    param([string]$Path, [string]$HomeDir, [string]$BinDir, [string]$Sep)
    $h = $HomeDir.TrimEnd('\', '/')
    if (($BinDir.TrimEnd('\', '/') -ieq ($h + $Sep + 'bin')) -and $Path.StartsWith($h + $Sep, [StringComparison]::OrdinalIgnoreCase)) {
      $rest = $Path.Substring($h.Length + 1).Replace('/', '\')
      return '%~dp0..\' + $rest
    }
    return $Path
  }

  # True when a raw (unexpanded) Path value already lists Entry, literally or after %VAR% expansion;
  # case-insensitive, ignoring a trailing backslash.
  function Test-PathHasEntry {
    param([string]$PathValue, [string]$Entry)
    $want = $Entry.TrimEnd('\')
    foreach ($p in ($PathValue -split ';')) {
      if (-not $p) { continue }
      if ($p.TrimEnd('\') -ieq $want) { return $true }
      if ([Environment]::ExpandEnvironmentVariables($p).TrimEnd('\') -ieq $want) { return $true }
    }
    return $false
  }

  function Get-CmdShimText {
    param([string]$NodeRef, [string]$LauncherRef)
    return "@echo off`r`nrem UTCU_NPM_SHIM`r`n`"$NodeRef`" `"$LauncherRef`" %*`r`nexit /b %ERRORLEVEL%`r`n"
  }

  # Refuse to touch a command this installer did not write (it carries the UTCU_NPM_SHIM marker when it did).
  function Assert-ShimOurs {
    param([string]$Shim)
    if (-not (Test-Path -LiteralPath $Shim)) { return }
    $existing = Get-Content -LiteralPath $Shim -Raw -ErrorAction SilentlyContinue
    if ($existing -and $existing -match 'UTCU_NPM_SHIM') { return }
    if ($existing -and $existing -match 'ULTRATERM_COMPUTER_USE_MANAGED_SHIM') {
      throw "the signed macOS installer already manages $Shim; remove that shim first or set UTCU_BIN_DIR to another folder"
    }
    throw "refusing to replace existing command at $Shim (not written by this installer); remove it first or set UTCU_BIN_DIR to another folder"
  }

  $tmp = $null
  $stage = $null
  $nodeExpand = $null
  $nodeTmp = $null
  try {
    $repo = 'your-org/ultraterm-computer-use'
    $nodeMinMajor = 18
    # An unstamped source copy would download from an account anyone can register (the stamp never rewrites this pattern).
    if (-not $env:UTCU_RELEASE_BASE -and $repo -like 'your-org/*') {
      throw 'this install.ps1 is a source template, not a release asset; use the install.ps1 attached to a GitHub release'
    }
    $isWin = if ($PSVersionTable.PSEdition -eq 'Core') { $IsWindows } else { $true }
    if (-not $isWin -and $IsMacOS) {
      throw 'On macOS use install.sh (it points at the signed .pkg) or install.sh --npm; nothing was installed.'
    }
    $sep = if ($isWin) { '\' } else { '/' }

    $homeDir = $env:UTCU_HOME
    if (-not $homeDir) {
      $homeDir = if ($isWin) { Join-Path $env:LOCALAPPDATA 'UltraTermComputerUse' } else { Join-Path $HOME '.ultraterm-computer-use' }
    }
    $binDir = $env:UTCU_BIN_DIR
    if (-not $binDir) {
      $binDir = if ($isWin) { Join-Path $homeDir 'bin' } else { Join-Path $HOME '.local/bin' }
    }
    # Absolute, normalised paths: later comparisons must not depend on how the override was spelled.
    $homeDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($homeDir).TrimEnd('\', '/')
    $binDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($binDir).TrimEnd('\', '/')
    $base = if ($env:UTCU_RELEASE_BASE) { $env:UTCU_RELEASE_BASE }
      elseif ($env:UTCU_VERSION) { "https://github.com/$repo/releases/download/v$($env:UTCU_VERSION.TrimStart('v'))" }
      else { "https://github.com/$repo/releases/latest/download" }

    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
      throw 'needs tar (bundled with Windows 10 1803+ and most Linux systems); install it, then run this again'
    }

    $shim = if ($isWin) { Join-Path $binDir 'ultraterm-computer-use.cmd' } else { Join-Path $binDir 'ultraterm-computer-use' }
    Assert-ShimOurs -Shim $shim

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('utcu-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
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

    $r = Invoke-Native -File 'tar' -Arguments @('-xzf', $tgz, '-C', $tmp, 'package/package.json')
    if ($r.Code -ne 0) { throw "cannot unpack the download: $($r.Output)" }
    $pkgJson = Join-Path $tmp 'package/package.json'
    if (-not (Test-Path $pkgJson)) { throw 'the download is not an UltraTerm Computer Use release' }
    $version = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
    if (-not $version) { throw 'cannot read the release version' }
    if ($tarName -ne "ultraterm-computer-use-$version.tgz") { throw "release name $tarName does not match its version $version" }

    # Node: the one on PATH when it is new enough, else the official build, kept inside the tool's own folder.
    # The absolute node path is always what the shim runs: hosts started from a GUI often have no node on PATH.
    $nodeBin = $null
    $nodeOk = $false
    $found = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found -and $found.Source) {
      $nodeBin = $found.Source
      $nodeOk = Test-NodeVersion -Node $nodeBin -MinMajor $nodeMinMajor
    }
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
        $machine = (Invoke-Native -File 'uname' -Arguments @('-m')).Output
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
        # Unpack straight into a folder under the tool's home (never %TEMP%), so the final move is a same-drive rename.
        $nodeTmp = Join-Path $runtimeDir ('.node-' + [guid]::NewGuid().ToString('N'))
        if ($isWin) {
          $nodeExpand = Join-Path $runtimeDir ('.expand-' + [guid]::NewGuid().ToString('N'))
          Expand-Archive -Path $npath -DestinationPath $nodeExpand
          $inner = Get-ChildItem -Path $nodeExpand -Directory | Select-Object -First 1
          if (-not $inner) { throw 'cannot unpack Node' }
          Move-Item -Path $inner.FullName -Destination $nodeTmp
        } else {
          New-Item -ItemType Directory -Path $nodeTmp | Out-Null
          $r = Invoke-Native -File 'tar' -Arguments @('-xzf', $npath, '-C', $nodeTmp, '--strip-components=1')
          if ($r.Code -ne 0) { throw "cannot unpack Node: $($r.Output)" }
        }
        if (Test-Path $nodeDir) { Remove-Item -Recurse -Force $nodeDir }
        Move-Item -Path $nodeTmp -Destination $nodeDir
        $nodeTmp = $null
      }
      $nodeBin = if ($isWin) { Join-Path $nodeDir 'node.exe' } else { Join-Path $nodeDir 'bin/node' }
      if (-not (Test-NodeVersion -Node $nodeBin -MinMajor $nodeMinMajor)) { throw 'the downloaded Node does not run on this machine' }
    }
    $nodeBin = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($nodeBin)
    $nodeFolder = Split-Path -Parent $nodeBin
    $env:PATH = $nodeFolder + [IO.Path]::PathSeparator + $env:PATH

    # npm: on Windows always npm.cmd (a bare `npm` resolves to npm.ps1, which the default Restricted policy blocks).
    $npmName = if ($isWin) { 'npm.cmd' } else { 'npm' }
    $npmBin = Join-Path $nodeFolder $npmName
    if (-not (Test-NpmVersion -Npm $npmBin)) {
      $cand = Get-Command $npmName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($cand -and (Test-NpmVersion -Npm $cand.Source)) { $npmBin = $cand.Source }
      else { throw "no working $npmName found next to Node or on PATH; install Node 18+ with npm" }
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
    $r = Invoke-Native -File $npmBin -Arguments @('install', '--prefix', $stage, '--no-audit', '--no-fund', '--loglevel=error', $tgz)
    if ($r.Code -ne 0) { throw "npm install failed (exit $($r.Code)); nothing was changed`n$($r.Output)" }
    $launcher = Join-Path $stage 'node_modules/ultraterm-computer-use/bin/ultraterm-computer-use'
    if (-not (Test-Path $launcher)) { throw 'the package did not install its launcher; nothing was changed' }
    $r = Invoke-Native -File $nodeBin -Arguments @($launcher, '--version')
    if ($r.Code -ne 0 -or $r.Output -ne $version) { throw "the new copy reports '$($r.Output)', not $version; nothing was changed" }

    # Each install gets its own folder, so re-running the same version never removes the live release.
    $rel = Join-Path $appDir ("release-$version-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Move-Item -Path $stage -Destination $rel
    $stage = $null
    $launcher = Join-Path $rel 'node_modules/ultraterm-computer-use/bin/ultraterm-computer-use'

    if ($isWin) {
      $nodeRef = Get-ShimRef -Path $nodeBin -HomeDir $homeDir -BinDir $binDir -Sep $sep
      $launcherRef = Get-ShimRef -Path ($launcher.Replace('/', '\')) -HomeDir $homeDir -BinDir $binDir -Sep $sep
      $cmd = Get-CmdShimText -NodeRef $nodeRef -LauncherRef $launcherRef
      # OEM code page, not ASCII: -Encoding Ascii turns a non-ASCII profile path into '?'.
      $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
      if ($oem.GetString($oem.GetBytes($cmd)) -ne $cmd) {
        throw 'the install path has characters the console code page cannot hold; set UTCU_HOME and UTCU_BIN_DIR to plain ASCII folders'
      }
      [IO.File]::WriteAllText($shim, $cmd, $oem)
    } else {
      $sh = "#!/bin/sh`n# UTCU_NPM_SHIM`nexec `"$nodeBin`" `"$launcher`" `"`$@`"`n"
      [IO.File]::WriteAllText($shim, $sh, (New-Object Text.UTF8Encoding($false)))
      $r = Invoke-Native -File 'chmod' -Arguments @('755', $shim)
      if ($r.Code -ne 0) { throw "cannot mark the shim executable at $shim" }
    }

    # Keep only the release that the shim points at.
    foreach ($d in Get-ChildItem -Path $appDir -Directory -Filter 'release-*') {
      if ($d.FullName -ne $rel) { Remove-Item -Recurse -Force $d.FullName -ErrorAction SilentlyContinue }
    }

    if ($isWin) {
      # The raw user Path is read without expanding %VAR% entries and written back with its own registry type.
      $envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
      try {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        $userPath = ''
        if ($envKey.GetValueNames() -contains 'Path') {
          $kind = $envKey.GetValueKind('Path')
          $userPath = [string]$envKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        if (-not (Test-PathHasEntry -PathValue $userPath -Entry $binDir)) {
          $newPath = if ($userPath) { $userPath.TrimEnd(';') + ';' + $binDir } else { $binDir }
          $envKey.SetValue('Path', $newPath, $kind)
          # Setting and clearing a user variable broadcasts the change so new terminals pick the Path up.
          [Environment]::SetEnvironmentVariable('UTCU_PATH_REFRESH', '1', 'User')
          [Environment]::SetEnvironmentVariable('UTCU_PATH_REFRESH', $null, 'User')
          Write-Host "Added $binDir to your user Path; open a new terminal to pick it up."
        }
      } finally { if ($envKey) { $envKey.Close() } }
    } elseif (($env:PATH -split [IO.Path]::PathSeparator) -notcontains $binDir) {
      Write-Host "Add $binDir to your PATH:  export PATH=`"$binDir`:`$PATH`""
    }
    $r = Invoke-Native -File $shim -Arguments @('--version')
    if ($r.Code -ne 0 -or $r.Output -ne $version) { throw "the installed command reports '$($r.Output)', not $version" }
    Write-Host "UltraTerm Computer Use $($r.Output) installed ($shim)."
    $r = Invoke-Native -File $shim -Arguments @('doctor')
    if ($r.Code -ne 0) { throw "the health check (doctor) failed: $($r.Output)" }
    Write-Host $r.Output
    Write-Host 'Next: ultraterm-computer-use list-apps'
  } finally {
    foreach ($p in @($stage, $nodeTmp, $nodeExpand)) {
      if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
    }
    if ($tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    foreach ($n in $prevEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $prevEnv[$n], 'Process') }
    $ProgressPreference = $prevProgress
    $ErrorActionPreference = $prevEap
  }
}

Install-UltraTermComputerUse

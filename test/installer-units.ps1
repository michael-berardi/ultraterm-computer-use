# Unit tests for the platform-neutral helpers inside scripts/install.ps1, run under PowerShell 7 (any OS).
# Usage: pwsh -NoProfile -File test/installer-units.ps1 <path-to-install.ps1>
param([string]$Script)
$ErrorActionPreference = 'Stop'
$tokens = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { throw "install.ps1 does not parse: $($errs[0].Message)" }
foreach ($name in 'Get-ShimRef', 'Get-CmdShimText', 'Assert-ShimOurs') {
  $def = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $def) { throw "install.ps1 has no function $name" }
  . ([scriptblock]::Create($def.Extent.Text))
}
$fails = 0
function Check($ok, $what) { if ($ok) { Write-Host "ok   $what" } else { Write-Host "FAIL $what"; $script:fails++ } }

# Shim paths: relative to the shim when it lives in <home>\bin, so a non-ASCII profile never enters the file.
$r = Get-ShimRef -Path '/h/Jos' -HomeDir '/h/u' -BinDir '/h/u/bin' -Sep '/'
Check ($r -eq '/h/Jos') 'path outside home stays absolute'
$h = 'C:/Users/Jos' + [char]0xE9
$r = Get-ShimRef -Path "$h/app/release-1/node_modules/x" -HomeDir $h -BinDir "$h/bin" -Sep '/'
Check ($r -eq '%~dp0..\app\release-1\node_modules\x') "home path becomes %~dp0-relative ($r)"
Check ($r -cmatch '^[\x00-\x7F]*$') 'relative reference is pure ASCII for a non-ASCII profile'
$r = Get-ShimRef -Path "$h/app/x" -HomeDir "$h/" -BinDir "$($h.ToUpper())/BIN/" -Sep '/'
Check ($r -eq '%~dp0..\app\x') 'trailing separators and case are ignored'
$r = Get-ShimRef -Path "$h/app/x" -HomeDir $h -BinDir 'D:/tools' -Sep '/'
Check ($r -eq "$h/app/x") 'BIN_DIR override elsewhere keeps the absolute path'

$t = Get-CmdShimText -NodeRef '%~dp0..\runtime\node.exe' -LauncherRef '%~dp0..\app\l'
Check ($t -match "(?m)^rem UTCU_NPM_SHIM`r$") 'cmd shim carries the marker line'
Check ($t.EndsWith("exit /b %ERRORLEVEL%`r`n")) 'cmd shim passes the exit code'

# Marker handling: never touch a file the installer did not write.
$d = Join-Path ([IO.Path]::GetTempPath()) ('utcu-units-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $d | Out-Null
try {
  $f = Join-Path $d 'tool'
  Assert-ShimOurs -Shim $f
  Check $true 'missing shim is fine'
  Set-Content $f "#!/bin/sh`n# UTCU_NPM_SHIM`n"
  Assert-ShimOurs -Shim $f
  Check $true 'shim with the marker is ours'
  Set-Content $f "#!/bin/sh`necho user tool`n"
  $threw = $false; try { Assert-ShimOurs -Shim $f } catch { $threw = $_.Exception.Message -match 'refusing' }
  Check $threw 'foreign file is refused with one line'
  Set-Content $f "# ULTRATERM_COMPUTER_USE_MANAGED_SHIM`n"
  $threw = $false; try { Assert-ShimOurs -Shim $f } catch { $threw = $_.Exception.Message -match 'signed macOS installer' }
  Check $threw 'signed-installer shim is refused with its own message'
  Set-Content $f ''
  $threw = $false; try { Assert-ShimOurs -Shim $f } catch { $threw = $true }
  Check $threw 'empty foreign file is refused'
} finally { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
if ($fails -gt 0) { throw "$fails installer unit check(s) failed" }
Write-Host 'installer units OK'

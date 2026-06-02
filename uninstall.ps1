# uninstall.ps1 -- agmsg PowerShell uninstaller wrapper
# Detects Git for Windows and delegates to uninstall.sh.
#
# Usage:
#   .\uninstall.ps1                   # Interactive uninstall
#   .\uninstall.ps1 --yes             # Remove all without confirmation
#   .\uninstall.ps1 --keep-data       # Remove skill but keep DB and teams
#   .\uninstall.ps1 --help            # Show this help
#
# Prerequisites:
#   - Git for Windows (WSL bash is NOT supported)

. "$PSScriptRoot\_gitbash.ps1"

# --- Parse arguments (manual loop; PS param() mangles --flags) ---
$showHelp = $false
$bashArgParts = @()

$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        # Accept both POSIX double-dash (matches uninstall.sh) and single-dash,
        # which PowerShell users habitually type.
        { $_ -eq '--yes' -or $_ -eq '-y' -or $_ -eq '-yes' } {
            $bashArgParts += '--yes'
            $i += 1
        }
        { $_ -eq '--keep-data' -or $_ -eq '-keep-data' } {
            $bashArgParts += '--keep-data'
            $i += 1
        }
        { $_ -eq '-h' -or $_ -eq '--help' } {
            $showHelp = $true
            $i += 1
        }
        default {
            Write-Host "Unknown option: $($args[$i])" -ForegroundColor Red
            exit 1
        }
    }
}

# --- Help ---
if ($showHelp) {
    Write-Host @'

  agmsg -- PowerShell Uninstaller Wrapper

  Usage:
    .\uninstall.ps1                   Interactive uninstall
    .\uninstall.ps1 --yes             Remove all without confirmation
    .\uninstall.ps1 -y                Same as --yes
    .\uninstall.ps1 --keep-data       Remove skill but keep DB and team configs
    .\uninstall.ps1 --help            Show this help

  Prerequisites:
    - Git for Windows  (winget install Git.Git  /  choco install git)
    WSL bash is NOT supported.

  This wrapper detects Git Bash and delegates to uninstall.sh.
  See: https://agmsg.cc/

'@
    exit 0
}

# --- Detect Git Bash ---
$bashExe = Find-GitBash
if (-not $bashExe) {
    Show-GitBashNotFound
    exit 1
}

# --- Check sqlite3 (uninstall.sh uses it to strip hooks/commands from settings;
#     without it, cleanup silently skips those steps and leaves stale entries) ---
$sqlite3Check = & $bashExe -lc 'command -v sqlite3' 2>$null
if (-not $sqlite3Check) {
    Show-Sqlite3NotFound
    exit 1
}

# --- Convert repo path to MSYS ---
$msysRepo = Get-MsysPath -BashExe $bashExe -WindowsPath $PSScriptRoot

# --- Delegate to uninstall.sh ---
$bashArgs = $bashArgParts -join ' '
Invoke-AgmsgBash -BashExe $bashExe -MsysRepoPath $msysRepo -ScriptName 'uninstall.sh' -BashArgs $bashArgs
exit $LASTEXITCODE

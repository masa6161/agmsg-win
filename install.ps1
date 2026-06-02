# install.ps1 -- agmsg PowerShell installer wrapper
# Detects Git for Windows, checks dependencies, and delegates to install.sh.
#
# Usage:
#   .\install.ps1                     # Installs with default command name 'agmsg'
#   .\install.ps1 --cmd m             # Install with custom command name
#   .\install.ps1 --update            # Update scripts in place
#   .\install.ps1 --help              # Show this help
#
# Prerequisites:
#   - Git for Windows (WSL bash is NOT supported)
#   - sqlite3 (reachable from Git Bash)

. "$PSScriptRoot\_gitbash.ps1"

# --- Parse arguments (manual loop; PS param() mangles --flags) ---
$cmdName = ''
$updateOnly = $false
$showHelp = $false
$bashArgParts = @()

$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        # Accept both POSIX double-dash (matches install.sh) and single-dash,
        # which PowerShell users habitually type.
        { $_ -eq '--cmd' -or $_ -eq '-cmd' } {
            if ($i + 1 -ge $args.Count) {
                Write-Host 'Error: --cmd requires a value' -ForegroundColor Red
                exit 1
            }
            $cmdName = $args[$i + 1]
            # Escape single quotes for bash
            $escapedCmd = $cmdName -replace "'", "'\''"
            $bashArgParts += "--cmd '$escapedCmd'"
            $i += 2
        }
        { $_ -eq '--update' -or $_ -eq '-update' } {
            $updateOnly = $true
            $bashArgParts += '--update'
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

  agmsg -- PowerShell Installer Wrapper

  Usage:
    .\install.ps1                     Install with default command name 'agmsg'
    .\install.ps1 --cmd <name>        Install with custom command name
    .\install.ps1 --update            Update scripts in place (preserve DB/teams)
    .\install.ps1 --help              Show this help

  Prerequisites:
    - Git for Windows  (winget install Git.Git  /  choco install git)
    - sqlite3          (choco install sqlite)
    WSL bash is NOT supported.

  This wrapper detects Git Bash and delegates to install.sh.
  See: https://agmsg.cc/

'@
    exit 0
}

# --- Bare-invocation rule: inject --cmd agmsg if no --cmd and no --update ---
# Decided before Git Bash detection because it depends only on parsed args,
# which also lets the dry-run hook below verify argument assembly without bash.
if (-not $cmdName -and -not $updateOnly) {
    $bashArgParts += "--cmd 'agmsg'"
}

# --- Dry-run hook (testability): print assembled bash args and exit ---
# Set AGMSG_PS_DRYRUN=1 to inspect argument assembly without detecting Git Bash
# or invoking install.sh. Used by tests/windows/Install.Tests.ps1.
if ($env:AGMSG_PS_DRYRUN -eq '1') {
    Write-Output "BASHARGS=$($bashArgParts -join ' ')"
    exit 0
}

# --- Detect Git Bash ---
$bashExe = Find-GitBash
if (-not $bashExe) {
    Show-GitBashNotFound
    exit 1
}

# --- Check sqlite3 (through bash, not PS -- it may be on MSYS2 PATH only) ---
$sqlite3Check = & $bashExe -lc 'command -v sqlite3' 2>$null
if (-not $sqlite3Check) {
    Show-Sqlite3NotFound
    exit 1
}

# --- Convert repo path to MSYS ---
$msysRepo = Get-MsysPath -BashExe $bashExe -WindowsPath $PSScriptRoot

# --- Delegate to install.sh ---
$bashArgs = $bashArgParts -join ' '
Invoke-AgmsgBash -BashExe $bashExe -MsysRepoPath $msysRepo -ScriptName 'install.sh' -BashArgs $bashArgs
exit $LASTEXITCODE

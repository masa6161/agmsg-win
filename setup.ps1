# setup.ps1 -- agmsg remote one-liner bootstrap for Windows
# Clones the repo to a temp directory, runs install.ps1, and cleans up.
#
# Usage (default install):
#   iex (irm https://raw.githubusercontent.com/masa6161/agmsg-win/main/setup.ps1)
#
# Usage (with arguments):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/masa6161/agmsg-win/main/setup.ps1))) --cmd m
#
# Prerequisites:
#   - git   (winget install Git.Git)
#   - Git for Windows bash + sqlite3 (checked by install.ps1)
#
# NOTE: This script is designed to run via `iex` in the CALLER's PowerShell
# session, so it never calls `exit` (which would terminate that session). It
# signals failure through $LASTEXITCODE and returns instead.

# Resolve git to a real executable (CommandType Application) so a session alias
# or function named "git" cannot shadow it -- important for an iex bootstrap.
$gitCmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $gitCmd) {
    Write-Host ''
    Write-Host '  git is required but was not found.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Install it with one of:'
    Write-Host '    winget install Git.Git'
    Write-Host '    choco install git'
    Write-Host ''
    $global:LASTEXITCODE = 1
    return
}

# Resolve a PowerShell host executable the same way (avoid alias/function
# shadowing). Prefer Windows PowerShell (always present on Windows); fall back to
# the currently running host (e.g. pwsh) if powershell.exe is unavailable.
$psCmd  = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$psPath = if ($psCmd) { $psCmd.Source } else { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }

$exitCode = 0
$tempDir  = Join-Path $env:TEMP "agmsg-setup-$([guid]::NewGuid())"

try {
    Write-Host ''
    Write-Host '  agmsg -- Setup'
    Write-Host '  ---------------'
    Write-Host ''
    Write-Host '  Cloning masa6161/agmsg-win to temp directory...'
    Write-Host ''

    & $gitCmd.Source clone --depth 1 https://github.com/masa6161/agmsg-win.git $tempDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  Failed to clone repository.' -ForegroundColor Red
        $exitCode = 1
    }
    else {
        # Pass through all args received by this script to install.ps1.
        $passedArgs = @()
        foreach ($a in $args) { $passedArgs += $a }

        # -NoProfile keeps the child run free of user profile side effects;
        # -ExecutionPolicy Bypass lets the cloned install.ps1 run under Restricted.
        $installerPath = Join-Path $tempDir 'install.ps1'
        & $psPath -NoProfile -ExecutionPolicy Bypass -File $installerPath @passedArgs
        $exitCode = $LASTEXITCODE
    }
}
finally {
    # Always clean up temp directory. git packs objects read-only on Windows,
    # which can make Remove-Item fail; clear the ReadOnly attribute first.
    if (Test-Path $tempDir) {
        Get-ChildItem -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReadOnly } |
            ForEach-Object { $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly) }
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
}

# Signal result without calling `exit` (see header note about iex).
$global:LASTEXITCODE = $exitCode

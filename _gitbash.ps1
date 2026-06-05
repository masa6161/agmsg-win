# _gitbash.ps1 -- Shared helpers for agmsg PowerShell wrappers (dot-source only)
# Usage: . "$PSScriptRoot\_gitbash.ps1"

function Find-GitBash {
    <#
    .SYNOPSIS
        Locate Git for Windows bash.exe, rejecting WSL launchers.
    .DESCRIPTION
        Search order:
          1. PATH scan  (reject System32/WindowsApps WSL; accept \Git\)
          2. Registry   (HKLM GitForWindows InstallPath)
          3. uname probe (Scoop / portable -- non-WSL bash reporting MINGW/MSYS)
          4. Hard-coded  C:\Program Files\Git\bin\bash.exe
        Returns the full path to bash.exe, or $null if not found.
    #>
    [CmdletBinding()]
    param()

    # --- 1. PATH scan ---
    $allBash = @()
    try {
        $allBash = @(Get-Command bash.exe -All -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty Source)
    } catch {}

    $unameCandidates = @()
    foreach ($candidate in $allBash) {
        # Reject WSL launchers
        if ($candidate -match '\\Windows\\System32\\' -or $candidate -match '\\WindowsApps\\') {
            continue
        }
        # Accept Git for Windows (case-insensitive by default in -match)
        if ($candidate -match '\\Git\\') {
            if (Test-Path $candidate) {
                return $candidate
            }
        }
        # Save for uname probe later
        $unameCandidates += $candidate
    }

    # --- 2. Registry ---
    # Include HKCU for per-user (non-admin) Git for Windows installs, whose
    # binaries typically live under %LOCALAPPDATA%\Programs\Git and which do not
    # write to HKLM. Without these, a per-user install with bash.exe off PATH
    # would be reported as missing.
    $regPaths = @(
        'HKLM:\SOFTWARE\GitForWindows',
        'HKLM:\SOFTWARE\WOW6432Node\GitForWindows',
        'HKCU:\SOFTWARE\GitForWindows',
        'HKCU:\SOFTWARE\WOW6432Node\GitForWindows'
    )
    foreach ($rp in $regPaths) {
        try {
            $installPath = (Get-ItemProperty -Path $rp -Name InstallPath -ErrorAction Stop).InstallPath
            $bashPath = Join-Path $installPath 'bin\bash.exe'
            if (Test-Path $bashPath) {
                return $bashPath
            }
        } catch {}
    }

    # --- 3. uname probe (Scoop / portable installs) ---
    foreach ($candidate in $unameCandidates) {
        if (-not (Test-Path $candidate)) { continue }
        try {
            $uname = & $candidate -c 'uname -s' 2>$null
            if ($uname -match '^(MINGW|MSYS)') {
                return $candidate
            }
        } catch {}
    }

    # --- 4. Hard-coded fallback ---
    $fallback = 'C:\Program Files\Git\bin\bash.exe'
    if (Test-Path $fallback) {
        return $fallback
    }

    return $null
}

function Get-MsysPath {
    <#
    .SYNOPSIS
        Convert a Windows path to an MSYS/Cygwin path (/c/Users/...).
    .PARAMETER BashExe
        Full path to the Git Bash bash.exe.
    .PARAMETER WindowsPath
        The Windows path to convert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BashExe,
        [Parameter(Mandatory)] [string] $WindowsPath
    )

    # Primary: invoke cygpath.exe directly (lives at Git\usr\bin\, NOT Git\bin\).
    # This is fast and, crucially, does NOT start a shell -- so a user's
    # ~/.bash_profile / ~/.bashrc cannot print to stdout and corrupt the captured
    # path. (We observed a login shell emitting a screen-clear escape sequence.)
    try {
        $gitRoot = Split-Path (Split-Path $BashExe)
        $cygpath = Join-Path $gitRoot 'usr\bin\cygpath.exe'
        if (Test-Path $cygpath) {
            $result = & $cygpath -u $WindowsPath 2>$null
            if ($LASTEXITCODE -eq 0 -and $result) {
                return $result.Trim()
            }
        }
    } catch {}

    # Secondary: cygpath via a NON-login bash (-c, not -lc) so profile scripts do
    # not run and pollute stdout. Single quotes in the path are escaped for bash.
    try {
        $escaped = $WindowsPath -replace "'", "'\''"
        $result = & $BashExe -c "cygpath -u '$escaped'" 2>$null
        if ($LASTEXITCODE -eq 0 -and $result) {
            return $result.Trim()
        }
    } catch {}

    # Last resort: regex fallback (drive letter lowercased -> /c/...)
    $converted = [regex]::Replace($WindowsPath, '^([A-Za-z]):\\', { param($m) '/' + $m.Groups[1].Value.ToLower() + '/' })
    $converted = $converted -replace '\\', '/'
    return $converted
}

function Invoke-AgmsgBash {
    <#
    .SYNOPSIS
        Delegate execution to a bash script in the repo via Git Bash login shell.
    .PARAMETER BashExe
        Full path to Git Bash bash.exe.
    .PARAMETER MsysRepoPath
        MSYS-style path to the repository root.
    .PARAMETER ScriptName
        The script to run (e.g. install.sh, uninstall.sh).
    .PARAMETER BashArgs
        Argument string to pass to the script.
    .OUTPUTS
        None. Caller should read $LASTEXITCODE after invocation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BashExe,
        [Parameter(Mandatory)] [string] $MsysRepoPath,
        [Parameter(Mandatory)] [string] $ScriptName,
        [string] $BashArgs = ''
    )

    # Defense-in-depth: MSYS2 runtime sets MSYSTEM via /etc/msystem on login, but
    # we pre-set it in case the profile is customized or stripped. Save and
    # restore the caller's original value so we do not pollute their PowerShell
    # session (the variable would otherwise persist after this function returns).
    $hadMsystem = Test-Path Env:\MSYSTEM
    $oldMsystem = if ($hadMsystem) { $env:MSYSTEM } else { $null }
    try {
        $env:MSYSTEM = 'MINGW64'

        # Pass the repo path and script name as bash POSITIONAL parameters
        # ($1, $2) rather than interpolating them into the command string. A path
        # containing an apostrophe, space, or other shell metacharacter (all valid
        # in Windows paths -- e.g. C:\Users\O'Brien\... or a clone under
        # "Alice's tools\") then cannot break out of the quoting or inject shell
        # syntax, because bash quotes "$1"/"$2" for us. $BashArgs is a pre-escaped
        # bash token string assembled by the caller (e.g. --cmd 'name' with
        # embedded apostrophes already escaped as '\'') and is appended after the
        # script name so bash still word-splits it.
        $script = 'cd "$1" && ./"$2"'
        if ($BashArgs) {
            $script = "$script $BashArgs"
        }

        # Arg after the command becomes $0; the next two become $1 and $2.
        & $BashExe -lc $script 'agmsg' $MsysRepoPath $ScriptName
        # $LASTEXITCODE is set automatically; caller reads it directly. Do NOT
        # return it -- that would capture bash stdout into the output stream.
    } finally {
        if ($hadMsystem) {
            $env:MSYSTEM = $oldMsystem
        } else {
            Remove-Item Env:\MSYSTEM -ErrorAction SilentlyContinue
        }
    }
}

function Show-GitBashNotFound {
    <#
    .SYNOPSIS
        Display guidance when Git for Windows is not found.
    #>
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '  Git for Windows is required but was not found.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Install it with one of:'
    Write-Host '    winget install Git.Git'
    Write-Host '    choco install git'
    Write-Host ''
    Write-Host '  (WSL bash is not supported -- agmsg scripts use MSYS2 conventions.)'
    Write-Host ''
}

function Show-Sqlite3NotFound {
    <#
    .SYNOPSIS
        Display guidance when sqlite3 is not found in Git Bash.
    #>
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-Host '  sqlite3 is required but was not found in Git Bash.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Install it with one of:'
    Write-Host '    choco install sqlite'
    Write-Host '  Or add sqlite3.exe to your Git Bash PATH.'
    Write-Host ''
}

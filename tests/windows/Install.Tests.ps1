# Install.Tests.ps1 -- Pester v5 tests for the agmsg Windows PowerShell wrapper layer.
#
# Run:  Invoke-Pester tests/windows/Install.Tests.ps1 -Output Detailed
#
# Scope: deterministic unit tests for Find-GitBash / Get-MsysPath, plus
# subprocess (dry-run) tests for install.ps1 argument assembly. End-to-end
# install/uninstall and "missing Git Bash / missing sqlite3 exit 1" paths are
# covered by tests/windows/checklist.md (they require a controlled environment
# that cannot be simulated on a machine that already has Git Bash + sqlite3).

BeforeAll {
    $script:RepoRoot    = (Resolve-Path "$PSScriptRoot\..\..").Path
    $script:GitBashLib  = Join-Path $RepoRoot '_gitbash.ps1'
    $script:InstallPs1  = Join-Path $RepoRoot 'install.ps1'
    . $GitBashLib

    # Host used to launch install.ps1 as a child process. Windows PowerShell is
    # always present on Windows; fall back to pwsh if that is what is running.
    $script:PsHost = if (Get-Command powershell.exe -ErrorAction SilentlyContinue) {
        'powershell.exe'
    } else {
        'pwsh'
    }
}

Describe 'Find-GitBash' {

    It 'returns the Git\bin\bash.exe path when present on PATH (case 1)' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Program Files\Git\bin\bash.exe' } } `
            -ParameterFilter { $Name -eq 'bash.exe' }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Program Files\Git\bin\bash.exe' }

        Find-GitBash | Should -Be 'C:\Program Files\Git\bin\bash.exe'
    }

    It 'rejects System32\bash.exe (WSL launcher) (case 2)' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Windows\System32\bash.exe' } } `
            -ParameterFilter { $Name -eq 'bash.exe' }
        Mock Get-ItemProperty { throw 'no registry' }
        Mock Test-Path { $false }   # nothing else resolves

        $result = Find-GitBash
        $result | Should -Not -Match 'System32'
        $result | Should -BeNullOrEmpty
    }

    It 'rejects WindowsApps\bash.exe (WSL UWP alias) (case 3)' {
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Users\u\AppData\Local\Microsoft\WindowsApps\bash.exe' } } `
            -ParameterFilter { $Name -eq 'bash.exe' }
        Mock Get-ItemProperty { throw 'no registry' }
        Mock Test-Path { $false }

        $result = Find-GitBash
        $result | Should -Not -Match 'WindowsApps'
        $result | Should -BeNullOrEmpty
    }

    It 'falls back to the registry InstallPath when PATH has no Git Bash (case 4)' {
        # Use an existing drive (C:) for the fake InstallPath so Join-Path can
        # resolve the drive qualifier; only the leaf path is mocked via Test-Path.
        Mock Get-Command { } -ParameterFilter { $Name -eq 'bash.exe' }   # nothing on PATH
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallPath = 'C:\Apps\Git' }
        } -ParameterFilter { $Name -eq 'InstallPath' }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Apps\Git\bin\bash.exe' }

        Find-GitBash | Should -Be 'C:\Apps\Git\bin\bash.exe'
    }

    It 'accepts a non-standard/portable bash via uname probe when it reports MINGW (case 5)' {
        # A portable install whose path contains neither \Git\ nor a WSL marker.
        $stub = Join-Path $TestDrive 'portable-bash.cmd'
        Set-Content -Path $stub -Value '@echo MINGW64_NT-10.0-TEST' -Encoding Ascii

        Mock Get-Command { [pscustomobject]@{ Source = $stub } } `
            -ParameterFilter { $Name -eq 'bash.exe' }
        Mock Get-ItemProperty { throw 'no registry' }

        # Test-Path on the real stub is genuinely true; registry throws; the
        # uname probe runs the stub which prints MINGW... -> accepted.
        Find-GitBash | Should -Be $stub
    }

    It 'falls back to the hard-coded path as a last resort (case 6)' {
        Mock Get-Command { } -ParameterFilter { $Name -eq 'bash.exe' }
        Mock Get-ItemProperty { throw 'no registry' }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Program Files\Git\bin\bash.exe' }

        Find-GitBash | Should -Be 'C:\Program Files\Git\bin\bash.exe'
    }

    It 'falls back to the HKCU registry for a per-user (non-admin) Git install (F3)' {
        Mock Get-Command { } -ParameterFilter { $Name -eq 'bash.exe' }   # nothing on PATH
        # HKLM keys absent (default throws); per-user install registers under HKCU.
        Mock Get-ItemProperty { throw 'no key' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ InstallPath = 'C:\Users\u\AppData\Local\Programs\Git' }
        } -ParameterFilter { $Path -eq 'HKCU:\SOFTWARE\GitForWindows' }
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'C:\Users\u\AppData\Local\Programs\Git\bin\bash.exe' }

        Find-GitBash | Should -Be 'C:\Users\u\AppData\Local\Programs\Git\bin\bash.exe'
    }
}

Describe 'Get-MsysPath' {

    It 'regex fallback lowercases the drive letter (C:\X -> /c/X) (case 12)' {
        # A non-existent bash forces both cygpath strategies to fail, exercising
        # the last-resort regex conversion.
        $result = Get-MsysPath -BashExe 'C:\does-not-exist\bash.exe' -WindowsPath 'C:\Users\Foo\Bar'
        $result | Should -Be '/c/Users/Foo/Bar'
    }

    It 'regex fallback lowercases a non-C drive (D:\X -> /d/X)' {
        $result = Get-MsysPath -BashExe 'C:\does-not-exist\bash.exe' -WindowsPath 'D:\tools\agmsg'
        $result | Should -Be '/d/tools/agmsg'
    }
}

Describe 'install.ps1 argument assembly (dry-run)' {

    BeforeAll {
        $env:AGMSG_PS_DRYRUN = '1'
    }
    AfterAll {
        Remove-Item Env:\AGMSG_PS_DRYRUN -ErrorAction SilentlyContinue
    }

    It 'forwards --cmd <name> to install.sh (case 9)' {
        $out = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 --cmd myname 2>&1 | Out-String
        $out | Should -Match "BASHARGS=--cmd 'myname'"
    }

    It 'injects --cmd agmsg on bare invocation (case 10)' {
        $out = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 2>&1 | Out-String
        $out | Should -Match "BASHARGS=--cmd 'agmsg'"
    }

    It 'does not inject --cmd when --update is given' {
        $out = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 --update 2>&1 | Out-String
        $out | Should -Match 'BASHARGS=--update'
        $out | Should -Not -Match "--cmd 'agmsg'"
    }

    It 'accepts single-dash -cmd (F9)' {
        $out = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 -cmd single 2>&1 | Out-String
        $out | Should -Match "BASHARGS=--cmd 'single'"
    }

    It 'accepts single-dash -update (F9)' {
        $out = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 -update 2>&1 | Out-String
        $out | Should -Match 'BASHARGS=--update'
    }
}

Describe 'Invoke-AgmsgBash' {

    BeforeAll { $script:Bash = Find-GitBash }

    It 'sets MSYSTEM=MINGW64 during the call and restores the prior value (case 11, F6)' {
        if (-not $Bash) { Set-ItResult -Skipped -Because 'Git Bash not available' ; return }
        $dir = Join-Path $TestDrive 'msystest'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'probe.sh') -Value "#!/bin/bash`necho MSYSTEM_IS=`$MSYSTEM" -Encoding Ascii
        $msysDir   = Get-MsysPath -BashExe $Bash -WindowsPath $dir
        $msysProbe = Get-MsysPath -BashExe $Bash -WindowsPath (Join-Path $dir 'probe.sh')
        & $Bash -lc 'chmod +x "$1"' 'agmsg' $msysProbe | Out-Null

        $env:MSYSTEM = 'SENTINEL_VALUE'
        $out = Invoke-AgmsgBash -BashExe $Bash -MsysRepoPath $msysDir -ScriptName 'probe.sh' 2>&1 | Out-String
        $out | Should -Match 'MSYSTEM_IS=MINGW64'     # set during the call
        $env:MSYSTEM | Should -Be 'SENTINEL_VALUE'    # caller's value restored afterward
    }

    It 'removes MSYSTEM afterward when it was unset before the call (F6)' {
        if (-not $Bash) { Set-ItResult -Skipped -Because 'Git Bash not available' ; return }
        $dir = Join-Path $TestDrive 'msystest2'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'probe.sh') -Value "#!/bin/bash`necho ok" -Encoding Ascii
        $msysDir   = Get-MsysPath -BashExe $Bash -WindowsPath $dir
        $msysProbe = Get-MsysPath -BashExe $Bash -WindowsPath (Join-Path $dir 'probe.sh')
        & $Bash -lc 'chmod +x "$1"' 'agmsg' $msysProbe | Out-Null

        Remove-Item Env:\MSYSTEM -ErrorAction SilentlyContinue
        Invoke-AgmsgBash -BashExe $Bash -MsysRepoPath $msysDir -ScriptName 'probe.sh' *> $null
        (Test-Path Env:\MSYSTEM) | Should -BeFalse
    }

    # Regression: a repo path containing an apostrophe used to close the bash
    # single-quote string and fail with "unexpected EOF" (Codex adversarial
    # review). Positional-parameter passing must reach the target script intact.
    It 'reaches the target script when the repo path contains an apostrophe' {
        if (-not $Bash) { Set-ItResult -Skipped -Because 'Git Bash not available' ; return }
        $apos = [char]39
        $dir  = Join-Path $TestDrive ('O' + $apos + 'Brien dir')
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'probe.sh') -Value "#!/bin/bash`necho REACHED" -Encoding Ascii
        $msysDir   = Get-MsysPath -BashExe $Bash -WindowsPath $dir
        $msysProbe = Get-MsysPath -BashExe $Bash -WindowsPath (Join-Path $dir 'probe.sh')
        & $Bash -lc 'chmod +x "$1"' 'agmsg' $msysProbe | Out-Null

        $out = Invoke-AgmsgBash -BashExe $Bash -MsysRepoPath $msysDir -ScriptName 'probe.sh' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'REACHED'
    }

    It 'reaches the target script when the repo path contains spaces and shell metacharacters' {
        if (-not $Bash) { Set-ItResult -Skipped -Because 'Git Bash not available' ; return }
        $dir = Join-Path $TestDrive 'a b & (c) dir'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir 'probe.sh') -Value "#!/bin/bash`necho REACHED" -Encoding Ascii
        $msysDir   = Get-MsysPath -BashExe $Bash -WindowsPath $dir
        $msysProbe = Get-MsysPath -BashExe $Bash -WindowsPath (Join-Path $dir 'probe.sh')
        & $Bash -lc 'chmod +x "$1"' 'agmsg' $msysProbe | Out-Null

        $out = Invoke-AgmsgBash -BashExe $Bash -MsysRepoPath $msysDir -ScriptName 'probe.sh' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'REACHED'
    }

    It 'forwards a --cmd value containing an apostrophe to the script intact' {
        if (-not $Bash) { Set-ItResult -Skipped -Because 'Git Bash not available' ; return }
        $dir = Join-Path $TestDrive 'cmdval'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # probe echoes all forwarded args so we can assert the parsed value.
        Set-Content -Path (Join-Path $dir 'probe.sh') -Value "#!/bin/bash`necho ARGS:`$@" -Encoding Ascii
        $msysDir   = Get-MsysPath -BashExe $Bash -WindowsPath $dir
        $msysProbe = Get-MsysPath -BashExe $Bash -WindowsPath (Join-Path $dir 'probe.sh')
        & $Bash -lc 'chmod +x "$1"' 'agmsg' $msysProbe | Out-Null

        # Mirror install.ps1's escaping of the --cmd value (apostrophe -> '\'').
        $name      = "O" + [char]39 + "Brien"
        $escaped   = $name -replace "'", "'\''"
        $bashArgs  = "--cmd '$escaped'"
        $out = Invoke-AgmsgBash -BashExe $Bash -MsysRepoPath $msysDir -ScriptName 'probe.sh' -BashArgs $bashArgs 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match "ARGS:--cmd O'Brien"
    }
}

Describe 'Guidance messages' {

    It 'Show-GitBashNotFound lists winget and choco (case 7 guidance)' {
        $out = Show-GitBashNotFound 6>&1 | Out-String
        $out | Should -Match 'winget install Git.Git'
        $out | Should -Match 'choco install git'
        $out | Should -Match 'WSL'
    }

    It 'Show-Sqlite3NotFound mentions sqlite (case 8 guidance)' {
        $out = Show-Sqlite3NotFound 6>&1 | Out-String
        $out | Should -Match 'sqlite'
    }
}

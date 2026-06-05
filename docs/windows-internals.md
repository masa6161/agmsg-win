# Windows Internals

Developer documentation for the agmsg-win PowerShell wrapper layer.

## Design Principle

agmsg-win adds a **PowerShell wrapper layer** on top of upstream agmsg without modifying the original shell scripts. All install/uninstall/runtime logic lives in the upstream `.sh` files; the `.ps1` wrappers handle Windows-specific detection and setup, then delegate to bash.

This separation means upstream changes are absorbed automatically — the wrappers only care about finding Git Bash and invoking scripts through it.

## Architecture

```
User (PowerShell)
  │
  ├─ install.ps1 ──┐
  ├─ uninstall.ps1 ─┤
  └─ setup.ps1 ─────┤
                     │  dot-source
                     ▼
               _gitbash.ps1
               ├─ Find-GitBash      → locate bash.exe
               ├─ Get-MsysPath      → C:\... → /c/...
               └─ Invoke-AgmsgBash  → bash -lc (safe delegation)
                     │
                     ▼
               Git Bash (login shell)
                     │
                     ▼
               install.sh / uninstall.sh  (upstream, unmodified)
```

## `_gitbash.ps1` — Shared Helpers

All wrappers dot-source this file. It provides five functions.

### `Find-GitBash`

Locates Git for Windows `bash.exe` through a 4-stage cascade, explicitly rejecting WSL launchers.

| Stage | Method | Detail |
|---|---|---|
| 1 | PATH scan | `Get-Command bash.exe -All`. Rejects paths containing `\Windows\System32\` (WSL) or `\WindowsApps\` (UWP WSL alias). Accepts paths containing `\Git\`. Non-Git, non-WSL candidates are saved for stage 3. |
| 2 | Registry | Reads `InstallPath` from `HKLM:\SOFTWARE\GitForWindows`, its WOW6432Node variant, and the HKCU equivalents (per-user / non-admin installs). Constructs `<InstallPath>\bin\bash.exe` and tests existence. |
| 3 | uname probe | For PATH candidates that passed WSL rejection but didn't match `\Git\` (e.g. Scoop, portable installs): runs `bash -c 'uname -s'` and accepts if output starts with `MINGW` or `MSYS`. |
| 4 | Hard-coded fallback | `C:\Program Files\Git\bin\bash.exe` if it exists. |

Returns `$null` if all stages fail.

**Why reject WSL?** agmsg scripts depend on MSYS2 conventions: `cygpath`, MSYS-style `$HOME`, `/etc/profile`, and sqlite3 accessible within the same environment. WSL bash is a different userland and these assumptions don't hold.

### `Get-MsysPath`

Converts a Windows path (e.g. `C:\Users\kondo\agmsg-win`) to an MSYS path (`/c/Users/kondo/agmsg-win`). Three strategies, tried in order:

| Strategy | Method | Why |
|---|---|---|
| 1 | Direct `cygpath.exe` | Locates `<Git root>\usr\bin\cygpath.exe` and invokes it directly — no shell startup, so `~/.bash_profile` output cannot corrupt the result. |
| 2 | `bash -c` (non-login) | `bash -c "cygpath -u '...'"` — uses `-c` instead of `-lc` to avoid profile scripts that might print to stdout. |
| 3 | Regex fallback | `^([A-Za-z]):\\` → `/<lowercase>/`, backslashes → forward slashes. Pure string manipulation, no external process. |

### `Invoke-AgmsgBash`

Safely delegates execution to a bash script in the repository.

**Positional parameter passing:** The repo path and script name are passed as bash positional parameters (`$1`, `$2`) rather than interpolated into the command string:

```powershell
& $BashExe -lc 'cd "$1" && ./"$2"' 'agmsg' $MsysRepoPath $ScriptName
```

This prevents shell injection from Windows paths containing apostrophes, spaces, or metacharacters (e.g. `C:\Users\O'Brien\tools\`). The third argument (`'agmsg'`) occupies `$0`.

**MSYSTEM management:** Sets `$env:MSYSTEM = 'MINGW64'` before invocation and restores the original value (or removes it) in a `finally` block, so the caller's PowerShell session is not polluted.

### `Show-GitBashNotFound` / `Show-Sqlite3NotFound`

Guidance messages with install instructions (winget / choco).

## Wrapper Scripts

### `install.ps1`

Parses `--cmd`, `--update`, `--help` (accepts both `--` and `-` prefixes). Without `--cmd` or `--update`, injects `--cmd agmsg` as the default. Supports a `$env:AGMSG_PS_DRYRUN` test hook that prints assembled bash args and exits without invoking Git Bash.

### `uninstall.ps1`

Parses `--yes`, `--keep-data`, `--help`. Delegates to `uninstall.sh`. Includes a pre-flight `sqlite3` check — `uninstall.sh` uses sqlite3 to strip hooks/commands from settings, and without it cleanup silently skips those steps.

### `setup.ps1`

Remote one-liner bootstrap: clones the repo to a temp directory, runs `install.ps1`, and cleans up.

Key design decisions:
- **No `exit`**: Uses `return` + `$global:LASTEXITCODE` so `iex` doesn't terminate the caller's session.
- **Alias-safe**: Resolves `git` and `powershell.exe` via `Get-Command -CommandType Application` to avoid function/alias shadowing.
- **ReadOnly cleanup**: Clears ReadOnly attributes on `.git` pack files before `Remove-Item` (git marks these read-only on Windows).
- **`-ExecutionPolicy Bypass`**: The child `install.ps1` invocation uses this flag so the one-liner works even under `Restricted` policy.

## `compat.sh` — Platform Shim

`scripts/lib/compat.sh` provides POSIX-compatible wrappers for constructs that behave differently under MSYS2:

| Function | Replaces | MSYS2 issue |
|---|---|---|
| `compat_get_ppid` | `ps -o ppid=` | MSYS2 `ps` lacks `-o` format; uses `ps -l` with header-based column detection. |
| `compat_get_cmdline` | `ps -o args=` | Uses `/proc/<pid>/cmdline` (NUL-separated), falling back to `ps -l` COMMAND column. |
| `compat_uuidgen` | `uuidgen` | Falls back to `sqlite3 randomblob()` when `uuidgen` is unavailable. All paths pipe through `tr -d '\r'` to strip CRLF. |
| `compat_file_mtime` | `stat -f %m` / `stat -c %Y` | macOS uses `-f`, Linux/MSYS2 uses `-c`. |

Platform detection (`_agmsg_detect_platform`) uses `uname -s` to distinguish `msys` / `macos` / `linux`.

## `delivery.sh` — Hook Hardening

On MSYS2/Windows, two modifications ensure hooks execute through Git Bash:

1. **`bash` command prefix**: Hook commands are prefixed with `bash ` (e.g. `bash '/path/to/check-inbox.sh' ...`) so that even if the host tries PowerShell, `bash` on PATH handles it.
2. **`"shell":"bash"` JSON key**: Added to each hook entry so Claude Code explicitly routes to bash rather than falling back to PowerShell.

Both are conditional on `_agmsg_platform = "msys"` and have no effect on macOS/Linux.

## CRLF Handling

Two layers prevent CRLF issues:

1. **`.gitattributes`**: `* text=auto eol=lf` ensures all text files are checked out with LF on Windows.
2. **Runtime `tr -d '\r'`**: sqlite3 on MSYS2 emits CRLF in query output regardless of `.gitattributes`. All scripts that capture sqlite3 output pipe through `tr -d '\r'`.

## Test Coverage

`tests/windows/Install.Tests.ps1` (Pester v5) covers the PowerShell wrapper layer:

- `Find-GitBash`: PATH scan, WSL rejection (System32 + WindowsApps), registry fallback, uname probe, hard-coded fallback, HKCU per-user install
- `Get-MsysPath`: cygpath delegation, regex fallback with drive letter lowercasing
- `install.ps1`: Argument assembly (dry-run mode), `--cmd` forwarding, bare invocation default, single-dash acceptance
- `Invoke-AgmsgBash`: MSYSTEM save/restore, apostrophe-in-path safety, metacharacter-in-path safety, `--cmd` with apostrophe value
- Guidance messages: `Show-GitBashNotFound`, `Show-Sqlite3NotFound`

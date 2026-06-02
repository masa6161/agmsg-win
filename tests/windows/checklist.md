# Windows Manual E2E Verification Checklist

Manual end-to-end checks for the PowerShell installer wrappers.
Run these from the repository root in a **PowerShell** session (not Git Bash).

## Prerequisites

- Git for Windows installed (provides `git` and Git Bash)
- sqlite3 reachable from Git Bash (`choco install sqlite` or equivalent)
- PowerShell 5.1+ (ships with Windows 10/11)

---

## Checklist

### 1. Happy-path install

- [ ] **Git for Windows + sqlite3 present: `.\install.ps1 --cmd agmsg` succeeds**
  - **Steps:**
    1. Open PowerShell in the repo root.
    2. Run `.\install.ps1 --cmd agmsg`.
  - **Expected:** Install completes without errors. Skill is installed to `~/.agents/skills/agmsg/`. Exit code is 0.

### 2. Bare invocation (no args)

- [ ] **`.\install.ps1` (no args) installs `agmsg` without prompting or hanging**
  - **Steps:**
    1. If a previous install exists, run `.\uninstall.ps1 --yes` first.
    2. Run `.\install.ps1` with no arguments.
  - **Expected:** The wrapper injects `--cmd agmsg` automatically. Install completes with no interactive prompt. Skill is installed to `~/.agents/skills/agmsg/`. Exit code is 0.

### 3. Uninstall

- [ ] **After install: `.\uninstall.ps1 --yes` removes everything**
  - **Steps:**
    1. Ensure a previous `.\install.ps1` install is present.
    2. Run `.\uninstall.ps1 --yes`.
  - **Expected:** Skill directory, slash commands, hooks, and AGENTS.md sections are removed. Exit code is 0.

### 4. Missing Git for Windows

- [ ] **No Git for Windows (WSL may be present): `.\install.ps1` prints guidance, exits 1, never runs WSL bash**
  - **Steps:**
    1. Temporarily rename or hide the Git for Windows installation directory (e.g. rename `C:\Program Files\Git` to `C:\Program Files\Git.bak`).
    2. Ensure WSL launchers (`C:\Windows\System32\bash.exe`, `%LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe`) remain on PATH.
    3. Open a **new** PowerShell session (so PATH is refreshed).
    4. Run `.\install.ps1`.
  - **Expected:** The wrapper prints guidance mentioning `winget install Git.Git` / `choco install git` and notes that WSL bash is not supported. Exit code is 1. WSL bash is never invoked.
  - **Cleanup:** Restore the Git directory to its original name.

### 5. One-liner install

- [ ] **`iex (irm .../setup.ps1)` works end-to-end**
  - **Steps:**
    1. Uninstall any previous agmsg installation.
    2. Open a fresh PowerShell session.
    3. Run:
       ```powershell
       iex (irm https://raw.githubusercontent.com/masa6161/agmsg-win/main/setup.ps1)
       ```
  - **Expected:** The repo is cloned to a temp directory, `install.ps1` is invoked, skill is installed to `~/.agents/skills/agmsg/`, and the temp directory is cleaned up. Exit code is 0.

### 6. One-liner with args

- [ ] **`& ([scriptblock]::Create(...)) --cmd m` works**
  - **Steps:**
    1. Uninstall any previous agmsg installation.
    2. Open a fresh PowerShell session.
    3. Run:
       ```powershell
       & ([scriptblock]::Create((irm https://raw.githubusercontent.com/masa6161/agmsg-win/main/setup.ps1))) --cmd m
       ```
  - **Expected:** Skill is installed to `~/.agents/skills/m/`. Exit code is 0.

### 7. ExecutionPolicy Restricted

- [ ] **One-liner under `ExecutionPolicy Restricted` still completes (inner Bypass)**
  - **Steps:**
    1. Uninstall any previous agmsg installation.
    2. Set a restrictive policy:
       ```powershell
       Set-ExecutionPolicy -Scope CurrentUser Restricted
       ```
    3. Open a **new** PowerShell session.
    4. Run the one-liner:
       ```powershell
       iex (irm https://raw.githubusercontent.com/masa6161/agmsg-win/main/setup.ps1)
       ```
  - **Expected:** Install completes successfully. `setup.ps1` uses `-ExecutionPolicy Bypass` for the inner `install.ps1` call, so no policy error occurs.
  - **Cleanup:** Restore your preferred policy, e.g.:
    ```powershell
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    ```

### 8. Linux/macOS regression

- [ ] **`bats tests/` still passes (no `.sh` files changed)**
  - **Steps:**
    1. On a Linux or macOS machine (or in Git Bash on Windows with `bats-core` installed), run:
       ```bash
       bats tests/
       ```
  - **Expected:** All existing bats tests pass. No `.sh` files were modified by this change.

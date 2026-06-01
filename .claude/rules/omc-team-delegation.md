# OMC team delegation

`/omc-teams`が明示的に呼び出された場合，tmuxペーンを使用したmulti-Agentの並列起動を**必ず使用する**こと

- tmuxおよびバックエンドを提供する各種CLIツールはすべて使用可能であるため、これらを使用して並列起動を行うことが前提
- 何らかの問題があってこれができなくても，claude code内のサブエージェント呼び出しで代替しないこと
- もしtmuxペーンの準備が失敗した場合は，明示的に失敗を報告すること（例: "tmux ペーンの準備に失敗しました。環境がサポートされていない可能性があります。"）

## Windows/psmux 環境の前提条件

omc の `buildWorkerStartCommand` は `MSYSTEM` 環境変数が設定されている場合 bash 構文（`env KEY=val bash -lc ...`）を生成する。psmux のデフォルトシェルが PowerShell だとこの構文が ParserError になるため、**psmux の default-shell を Git Bash に設定する必要がある**。

設定ファイル: `~/.psmux.conf`
```
set -g default-shell "C:/Program Files/Git/bin/bash.exe"
```

この設定により `/omc-teams` の全機能（leader, mailbox, lifecycle API, タスク管理）が正常に動作する。

### トラブルシューティング

ペーンで以下のエラーが出る場合は psmux の default-shell が PowerShell のままである:
```
ParserError: Unexpected token 'OMC_TEAM_WORKER=...' in expression or statement.
```
→ `~/.psmux.conf` の設定を確認し、`tmux kill-server` 後に再試行する
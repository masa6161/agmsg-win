#!/usr/bin/env bash
set -euo pipefail

# Usage: history.sh <team> [agent_id] [limit]
# Shows message history. If agent_id given, shows only that agent's messages.

TEAM="${1:?Usage: history.sh <team> [agent_id] [limit]}"
AGENT="${2:-}"
LIMIT="${3:-20}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

if [ ! -f "$DB" ]; then
  echo "No messages (DB not initialized)"
  exit 0
fi

if [ -n "$AGENT" ]; then
  WHERE="WHERE team='$TEAM' AND (from_agent='$AGENT' OR to_agent='$AGENT')"
else
  WHERE="WHERE team='$TEAM'"
fi

# Emit a raw 0x1f between columns via the CLI -separator. Building the
# separator as a value with char(31) is unsafe: SQLite 3.43+ escapes control
# characters (0x1f renders as "^_") when they appear in a column value, which
# breaks the read split. tr -d '\r' drops sqlite3's CRLF line terminators on
# Windows (and any CR inside the body) so no field carries a trailing \r.
RESULT=$(sqlite3 -separator $'\x1f' "$DB" "
  SELECT from_agent, to_agent, replace(replace(body, char(10), '\n'), char(9), '\t'), created_at, CASE WHEN read_at IS NULL THEN '●' ELSE '○' END
  FROM messages $WHERE ORDER BY created_at DESC LIMIT $LIMIT;
" | tr -d '\r')

if [ -z "$RESULT" ]; then
  echo "No message history."
  exit 0
fi

# Reverse order (oldest first) and display
REVERSED=$(echo "$RESULT" | tail -r 2>/dev/null || echo "$RESULT" | tac 2>/dev/null || echo "$RESULT" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}')
while IFS=$'\x1f' read -r from to body ts status; do
  echo "  $status [$ts] $from → $to: $body"
done <<< "$REVERSED"

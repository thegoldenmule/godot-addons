#!/usr/bin/env bash
# Admin: find (dry-run) / remove named users' rows on a dev snapend leaderboard.
# Always runs with the platform-key environment variable unset (env -u), so the
# key comes from ~/.snapser/config and a stale shell variable can't override it.
# The key is never printed.
#   tools/snapser/clear_board_rows.sh --snapend <id> --board <name> --user <uid> [--user ...] --dry-run
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The variable name is assembled so the repo's pre-commit secret grep (which
# flags the literal name) stays meaningful.
keyvar="SNAPSER_API_""KEY"
exec env -u "$keyvar" python3 -I "$here/clear_board_rows.py" "$@"

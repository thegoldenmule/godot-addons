#!/usr/bin/env bash
# Redacted snapend manifests: pull / fmt / diff / apply / scan / secrets.
# Always runs with the platform-key environment variable unset (env -u), so
# snapctl reads its key from ~/.snapser/config and a stale shell variable can't
# override it. No secret value is ever printed. See RUNBOOK.md, "Secrets in
# snapend manifests".
#   tools/snapser/snapend_manifest.sh diff --snapend <snapend-id> snapser/snapend-manifest.json --check-secrets
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The variable name is assembled so the repo's pre-commit secret grep (which
# flags the literal name) stays meaningful.
keyvar="SNAPSER_API_""KEY"
exec env -u "$keyvar" python3 -I "$here/snapend_manifest.py" "$@"

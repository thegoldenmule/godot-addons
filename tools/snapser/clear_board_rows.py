#!/usr/bin/env python3
"""Find (and, once a delete path exists, remove) named users' rows on one
leaderboard of one DEVELOPMENT snapend. Run it through clear_board_rows.sh,
which always unsets the platform-key environment variable (env -u), so the key
comes from ~/.snapser/config.

  clear_board_rows.sh --snapend <id> --board <name> (--user <uid> [--user ...] | --all-rows)
                      [--dry-run] [--session-file <kit session json>] [--count N]

  --all-rows targets every row in the board's top --top (default 100). Use it
  for a pre-ship dev board where every row is test data and the user ids were
  not recorded.

What it does
  1. Reads the platform key from ~/.snapser/config [default] snapser_api_key.
     The key is never printed, logged or written anywhere.
  2. Platform API (GET /v1/snapser-api/snapends/<id>, header api-key): the
     snapend must exist on this account and be DEVELOPMENT, or it refuses.
  3. Reads the board with a snapend user session: an anonymous login with the
     handle from --session-file (a snapser_kit session json, e.g. the smoke
     identity; the file is never modified), or with a fixed "admin reader"
     handle per snapend (created once, never writes scores).
     For each --user: GET .../leaderboards/<board>?range=around&user_id=<uid>,
     then report that user's row (rank, score, and display name from Profiles).
  4. --dry-run: list what would be deleted, then exit 0.
     Without --dry-run: REFUSES (exit 3). Snapser exposes no API that deletes a
     single leaderboard row:
       - the leaderboards swagger has Get/Set/Increment only;
       - the platform key is not accepted by snapend gateways ("API key not
         found", code 16);
       - snapctl 1.10 / 1.15 has no user or row commands.
     It prints the console steps and the comma-joined user ids instead.

Exit: 0 ok / dry-run, 2 bad args or refused snapend, 3 delete not possible.
"""
import argparse
import configparser
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PLATFORM = "https://gateway.snapser.com/snapser"
GATEWAY = "https://gateway.snapser.com"
READER_HANDLE = "snapkit-admin-reader-%s"


def _http(method, url, headers=None, body=None, timeout=20):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode()
            return r.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return e.code, json.loads(text)
        except ValueError:
            return e.code, {"raw": text[:200]}


def _api_key():
    cfg = configparser.ConfigParser()
    cfg.read(os.path.expanduser("~/.snapser/config"))
    key = cfg.get("default", "snapser_api_key", fallback="").strip()
    if not key:
        sys.exit("clear_board_rows: no [default] snapser_api_key in ~/.snapser/config")
    return key


def _check_snapend(key, snapend):
    st, body = _http("GET", "%s/v1/snapser-api/snapends/%s" % (PLATFORM, snapend), {"api-key": key})
    if st != 200 or not isinstance(body, dict):
        print("REFUSED: snapend %s not visible to this account (HTTP %s)" % (snapend, st))
        sys.exit(2)
    env = body.get("environment") or body.get("snapend", {}).get("environment") or body.get("cluster", {}).get("environment")
    name = body.get("name") or body.get("snapend", {}).get("name") or body.get("cluster", {}).get("name")
    state = body.get("state") or body.get("snapend", {}).get("state") or body.get("cluster", {}).get("state")
    print("snapend %s: name=%s environment=%s state=%s" % (snapend, name, env, state))
    if str(env).upper() not in ("DEVELOPMENT", "DEV"):
        print("REFUSED: only DEVELOPMENT snapends are allowed (got %s)" % env)
        sys.exit(2)


def _session(snapend, session_file):
    """A read session. With --session-file, log in anonymously with that file's
    handle: the same user on a parallel session. The file is never modified, and
    its token is never refreshed (a refresh would invalidate the token the owner
    of the file holds)."""
    gw = "%s/%s" % (GATEWAY, snapend)
    if session_file:
        with open(os.path.expanduser(session_file)) as f:
            handle = json.load(f).get("username", "")
        if not handle:
            sys.exit("clear_board_rows: session file has no anonymous handle (username)")
        who = "session-file"
    else:
        handle = READER_HANDLE % snapend
        who = "admin-reader"
    st, body = _http("PUT", gw + "/v1/auth/login/anon", None, {"username": handle, "create_user": True})
    user = (body or {}).get("user", {}) if st == 200 else {}
    if not user.get("session_token"):
        sys.exit("clear_board_rows: anonymous login failed on %s (HTTP %s)" % (snapend, st))
    print("reader: %s user %s%s" % (who, user["id"], " (created now)" if user.get("created") else ""))
    return gw, user["id"], user["session_token"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--snapend", required=True)
    ap.add_argument("--board", required=True)
    ap.add_argument("--user", action="append", dest="users", default=[])
    ap.add_argument("--all-rows", action="store_true")
    ap.add_argument("--top", type=int, default=100)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--session-file")
    ap.add_argument("--count", type=int, default=3)
    a = ap.parse_args()
    if not a.users and not a.all_rows:
        ap.error("give --user <uid> (repeatable) or --all-rows")

    key = _api_key()
    _check_snapend(key, a.snapend)
    del key  # nothing below needs the platform key
    gw, uid, tok = _session(a.snapend, a.session_file)
    auth = {"Token": tok, "User-Id": uid}

    if a.all_rows:
        q = urllib.parse.urlencode({"range": "top", "count": a.top})
        st, body = _http("GET", "%s/v1/leaderboards/leaderboards/%s?%s" % (gw, urllib.parse.quote(a.board), q), auth)
        if st != 200:
            sys.exit("clear_board_rows: cannot read %s (HTTP %s %s)" % (a.board, st, (body or {}).get("api_error_code", "")))
        rows = (body or {}).get("user_scores", [])
        print("board %s: %d row(s) in the top %d" % (a.board, len(rows), a.top))
        a.users = [r.get("user_id") for r in rows if r.get("user_id")]

    found = []
    for target in a.users:
        q = urllib.parse.urlencode({"range": "around", "user_id": target, "count": a.count})
        st, body = _http("GET", "%s/v1/leaderboards/leaderboards/%s?%s" % (gw, urllib.parse.quote(a.board), q), auth)
        row = None
        if st == 200:
            for us in (body or {}).get("user_scores", []):
                if us.get("user_id") == target:
                    row = us
        if row is None:
            code = (body or {}).get("api_error_code", "")
            print("  %s: no row on %s (HTTP %s %s)" % (target, a.board, st, code))
            continue
        name = ""
        st2, prof = _http("GET", "%s/v1/profiles/batch/profiles?%s" % (gw, urllib.parse.urlencode({"user_id": target})), auth)
        if st2 == 200:
            p = ((prof or {}).get("profiles") or {}).get(target) or {}
            name = (p.get("profile") or p).get("display_name", "") if isinstance(p, dict) else ""
        found.append(target)
        print("  %s: rank %s score %s name %r" % (target, row.get("rank"), row.get("score"), name))

    verb = "WOULD DELETE" if a.dry_run else "TO DELETE"
    print("%s on %s/%s: %d row(s): %s" % (verb, a.snapend, a.board, len(found), ", ".join(found) or "none"))
    if a.dry_run or not found:
        return 0
    print("NOT DELETED: Snapser has no API to delete one leaderboard row (see --help). Do it in the console:")
    print("  - Snapend %s -> Leaderboards tool -> board %s -> remove the rows above, or" % (a.snapend, a.board))
    print("  - Snapend %s -> User Manager -> Bulk User Data -> Reset, user ids:" % a.snapend)
    print("    " + ",".join(found))
    print("    (dev snapends only; resets ALL of those users' snap data except Auth)")
    return 3


if __name__ == "__main__":
    sys.exit(main())

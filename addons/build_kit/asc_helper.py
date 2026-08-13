#!/usr/bin/env python3
"""App Store Connect API helper for the Build Kit Godot addon.

Stdlib-only on purpose (no `cryptography` dependency): the ES256 JWT signature
is produced by shelling out to /usr/bin/openssl (always present on macOS) and
converting its DER output to the raw r||s form JWT requires.

Prints exactly ONE JSON object on stdout — the GDScript side parses the last
line that starts with '{'.

Usage:
  asc_helper.py --key-path AuthKey.p8 --key-id K --issuer-id I check-app <bundle_id>
  asc_helper.py --key-path AuthKey.p8 --key-id K --issuer-id I builds <bundle_id>
"""
import argparse
import base64
import datetime
import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """Minimal ASN.1 parse of SEQUENCE(INTEGER r, INTEGER s) -> 64-byte r||s."""

    def read_len(buf, i):
        n = buf[i]
        i += 1
        if n & 0x80:
            count = n & 0x7F
            n = int.from_bytes(buf[i : i + count], "big")
            i += count
        return n, i

    assert der[0] == 0x30, "not a DER sequence"
    _, i = read_len(der, 1)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02, "expected DER integer"
        i += 1
        n, i = read_len(der, i)
        value = der[i : i + n].lstrip(b"\x00")
        i += n
        out += value.rjust(32, b"\x00")
    return out


def make_token(key_path: str, key_id: str, issuer_id: str) -> str:
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    signing_input = (
        b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + b64url(json.dumps(payload, separators=(",", ":")).encode())
    )
    with tempfile.NamedTemporaryFile() as tf:
        tf.write(signing_input.encode())
        tf.flush()
        der = subprocess.run(
            ["/usr/bin/openssl", "dgst", "-sha256", "-sign", key_path, tf.name],
            capture_output=True,
            check=True,
        ).stdout
    return signing_input + "." + b64url(der_to_raw(der))


def get(token: str, path: str) -> dict:
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def post(token: str, path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        API + path,
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def bundle_id_registered(token: str, identifier: str) -> bool:
    reg = get(token, "/v1/bundleIds?filter[identifier]=" + identifier)
    return any(b["attributes"].get("identifier") == identifier for b in reg.get("data", []))


def find_apps(token: str, bundle_id: str) -> list:
    """App records whose bundle id matches EXACTLY.

    /v1/apps?filter[bundleId] is neither a guaranteed-unique nor a guaranteed-
    exact match, and its result order is unspecified: duplicate and
    since-deleted records for the same bundle id do come back. Taking data[0]
    blindly can resolve to a ghost record carrying no builds — which downstream
    is indistinguishable from "nothing uploaded yet".
    """
    data = get(token, "/v1/apps?filter[bundleId]=" + bundle_id + "&fields[apps]=name,bundleId")
    return [a for a in data.get("data", []) if a["attributes"].get("bundleId") == bundle_id]


def app_builds(token: str, app_id: str) -> list:
    data = get(
        token,
        "/v1/builds?filter[app]="
        + app_id
        + "&sort=-uploadedDate&limit=5&fields[builds]=version,processingState,uploadedDate",
    )
    return [
        {
            "version": b["attributes"]["version"],
            "state": b["attributes"]["processingState"],
            "uploaded": b["attributes"].get("uploadedDate"),
        }
        for b in data.get("data", [])
    ]


def uploaded_at(build: dict) -> datetime.datetime:
    """Sort key for a build's uploadedDate; offsets differ, so don't compare strings."""
    try:
        return datetime.datetime.fromisoformat(build.get("uploaded") or "")
    except ValueError:
        return datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("command", choices=["check-app", "builds", "ensure-bundle-id", "team-info"])
    parser.add_argument("arg")
    args = parser.parse_args()
    try:
        token = make_token(args.key_path, args.key_id, args.issuer_id)
        if args.command == "team-info":
            # Which team does this key belong to? Keys are team-scoped, but the
            # API has no whoami — infer from team assets: a certificate's
            # subject OU is the team id (authoritative); bundle-id seedId is
            # the fallback. Empty team_id = team has no assets yet.
            team = ""
            certs = get(token, "/v1/certificates?limit=1").get("data", [])
            if certs:
                der = base64.b64decode(certs[0]["attributes"]["certificateContent"])
                with tempfile.NamedTemporaryFile(suffix=".der") as tf:
                    tf.write(der)
                    tf.flush()
                    subj = subprocess.run(
                        ["/usr/bin/openssl", "x509", "-inform", "DER", "-in", tf.name,
                         "-noout", "-subject"],
                        capture_output=True, text=True).stdout
                for part in subj.replace("subject=", "").split(","):
                    if part.strip().startswith("OU"):
                        team = part.strip().split("=", 1)[1].strip()
            if not team:
                reg = get(token, "/v1/bundleIds?limit=1").get("data", [])
                if reg:
                    team = reg[0]["attributes"].get("seedId") or ""
            print(json.dumps({"ok": True, "team_id": team}))
        elif args.command == "check-app":
            apps = find_apps(token, args.arg)
            print(
                json.dumps(
                    {
                        "ok": True,
                        "found": len(apps) > 0,
                        "bundle_registered": bundle_id_registered(token, args.arg),
                        "apps": [{"id": a["id"], "name": a["attributes"]["name"]} for a in apps],
                    }
                )
            )
        elif args.command == "ensure-bundle-id":
            # Registering an App ID is an ordinary, reversible developer-portal
            # operation (same as Identifiers → ＋), done with the user's own key.
            if bundle_id_registered(token, args.arg):
                print(json.dumps({"ok": True, "created": False,
                                  "message": "Bundle id already registered."}))
                return
            name = "".join(c for c in args.arg.split(".")[-1].title() if c.isalnum()) or "App"
            post(token, "/v1/bundleIds", {
                "data": {"type": "bundleIds",
                         "attributes": {"identifier": args.arg, "name": name,
                                        "platform": "IOS"}}})
            print(json.dumps({"ok": True, "created": True,
                              "message": "Bundle id %s registered." % args.arg}))
        elif args.command == "builds":
            apps = find_apps(token, args.arg)
            if not apps:
                print(json.dumps({"ok": True, "found": False, "builds": []}))
                return
            # Duplicates can survive exact matching, so let the builds themselves
            # break the tie: the record holding the most recently uploaded build
            # is the live one. Ghost records report nothing and lose.
            app_id, builds = apps[0]["id"], []
            for a in apps:
                found = app_builds(token, a["id"])
                if found and (not builds or uploaded_at(found[0]) > uploaded_at(builds[0])):
                    app_id, builds = a["id"], found
            print(json.dumps({"ok": True, "found": True, "app_id": app_id, "builds": builds}))
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        print(json.dumps({"ok": False, "error": "HTTP %d: %s" % (e.code, body)}))
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 - single JSON error contract
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()

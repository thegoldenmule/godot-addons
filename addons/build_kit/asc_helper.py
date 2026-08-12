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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-path", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("command", choices=["check-app", "builds"])
    parser.add_argument("arg")
    args = parser.parse_args()
    try:
        token = make_token(args.key_path, args.key_id, args.issuer_id)
        if args.command == "check-app":
            data = get(token, "/v1/apps?filter[bundleId]=" + args.arg + "&fields[apps]=name,bundleId")
            apps = data.get("data", [])
            print(
                json.dumps(
                    {
                        "ok": True,
                        "found": len(apps) > 0,
                        "apps": [{"id": a["id"], "name": a["attributes"]["name"]} for a in apps],
                    }
                )
            )
        elif args.command == "builds":
            data = get(token, "/v1/apps?filter[bundleId]=" + args.arg)
            apps = data.get("data", [])
            if not apps:
                print(json.dumps({"ok": True, "found": False, "builds": []}))
                return
            app_id = apps[0]["id"]
            builds = get(
                token,
                "/v1/builds?filter[app]="
                + app_id
                + "&sort=-uploadedDate&limit=5&fields[builds]=version,processingState,uploadedDate",
            )
            print(
                json.dumps(
                    {
                        "ok": True,
                        "found": True,
                        "app_id": app_id,
                        "builds": [
                            {
                                "version": b["attributes"]["version"],
                                "state": b["attributes"]["processingState"],
                                "uploaded": b["attributes"].get("uploadedDate"),
                            }
                            for b in builds.get("data", [])
                        ],
                    }
                )
            )
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        print(json.dumps({"ok": False, "error": "HTTP %d: %s" % (e.code, body)}))
        sys.exit(1)
    except Exception as e:  # noqa: BLE001 - single JSON error contract
        print(json.dumps({"ok": False, "error": str(e)}))
        sys.exit(1)


if __name__ == "__main__":
    main()

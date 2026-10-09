"""Tests for tools/snapser/snapend_manifest.py. Offline: snapctl and the keychain
are fakes, every id is made up, and the private key is generated per run.

  python3 -I -m unittest discover -s tools/snapser/tests -t tools/snapser
"""
import base64
import builtins
import contextlib
import copy
import io
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
sys.path.insert(0, TOOLS)
import snapend_manifest as sm  # noqa: E402

SNAPEND = "fake0001"
OTHER = "fake0002"
KEY_ID = "FAKEKEY001"
WORD = "PRIVATE " + "KEY"


def make_pem(seed=None):
    body = base64.b64encode(seed or os.urandom(96)).decode()
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN %s-----\n%s\n-----END %s-----" % (WORD, "\n".join(lines), WORD)


def tier(pem, key_id=KEY_ID):
    return {
        "anon": {"enabled": True},
        "api_keys": [],
        "apple": {"enabled": True, "key_id": key_id, "private_key": pem,
                  "service_id": "com.example.fake", "team_id": "FAKETEAM01"},
        "google": None,
        "password": {"enabled": True},
        "session_token_validity": 2592000,
    }


def make_live(pem, snapend=SNAPEND, extra_stat=False):
    stats = [{"key": "runs", "type": "counter", "scope": "external", "created_by": "u-1"}]
    if extra_stat:
        stats.append({"key": "wins", "type": "counter", "scope": "external", "created_by": "u-1"})
    content = {
        "version": "v1",
        "id": snapend,
        "name": "fake-dev",
        "environment": "DEVELOPMENT",
        "service_definitions": [{"id": "auth", "version": "v1.0.0"}],
        "settings": [
            {"id": "analytics", "data": {"events": [
                {"name": "run_end", "created_at": "1700000000", "properties": []}]},
             "version": "v1.0.0", "exported_at": "1700000001"},
            {"id": "auth", "data": {"dev": tier(pem), "stage": tier(pem), "prod": tier(pem),
                                    "email_templates": []},
             "version": "v1.0.0", "exported_at": "1700000002"},
            {"id": "remote-config", "data": {"app_configs": [
                {"id": "v1", "config": {}, "revision": 3, "created_at": "1", "updated_at": "2"}]},
             "version": "v1.0.0", "exported_at": "1700000003"},
            {"id": "statistics", "data": {"statistics": stats},
             "version": "v1.0.0", "exported_at": "1700000004"},
            {"id": "storage", "data": {"keys": [{"key": "save_v1", "is_prefix_key": False}]},
             "version": "v1.0.0", "exported_at": "1700000005"},
        ],
    }
    live = copy.deepcopy(content)
    live["applied_configuration"] = json.dumps(content, sort_keys=True)
    return live


class FakeSnapctl(object):
    """In-process snapctl: serves downloads from `live`, records applies."""

    def __init__(self, live, apply_rc=0, apply_echo=True, mutate=None, explode=None):
        self.live = live
        self.applies = []
        self.calls = []
        self.apply_rc = apply_rc
        self.apply_echo = apply_echo
        self.mutate = mutate
        self.explode = explode
        self.counter = 10

    def __call__(self, args):
        self.calls.append(args[:2])
        if self.explode and args[1] == self.explode[0]:
            self.explode[1]()
        if args[:2] == ["snapend", "download"]:
            sid = args[args.index("--snapend-id") + 1]
            out = args[args.index("--out-path") + 1]
            if sid != self.live["id"]:
                return 1, "not found"
            self.counter += 1
            served = copy.deepcopy(self.live)
            for s in served["settings"]:
                s["exported_at"] = str(1800000000 + self.counter)
            with open(os.path.join(out, "snapser-%s-manifest.json" % sid), "w") as f:
                json.dump(served, f)
            return 0, "Snapend download successful."
        if args[:2] == ["snapend", "apply"]:
            path = args[args.index("--manifest-path-filename") + 1]
            st = os.stat(path)
            dst = os.stat(os.path.dirname(path))
            with open(path) as f:
                uploaded = json.load(f)
            self.applies.append({"mode": stat.S_IMODE(st.st_mode), "dir_mode": stat.S_IMODE(dst.st_mode),
                                 "dir": os.path.dirname(path), "manifest": uploaded})
            if self.apply_rc:
                return self.apply_rc, "Remote manifest does not match"
            if uploaded["applied_configuration"] != self.live["applied_configuration"]:
                return 1, "Remote manifest does not match the manifest in the applied_configuration field."
            new = copy.deepcopy(uploaded)
            new.pop("applied_configuration")
            if self.mutate:
                self.mutate(new)
            new["applied_configuration"] = json.dumps(new, sort_keys=True)
            self.live = new
            echo = ""
            if self.apply_echo:
                # A chatty snapctl that echoes the key must still be scrubbed.
                echo = " echo " + json.dumps(uploaded["settings"][1]["data"]["dev"]["apple"]["private_key"])
            return 0, "Snapend apply successful." + echo
        return 2, "unexpected"


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sm-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pem = make_pem()
        # Work dirs land here, so tests can assert they are gone.
        self.work = os.path.join(self.tmp, "work")
        os.mkdir(self.work)
        old = tempfile.tempdir
        tempfile.tempdir = self.work
        self.addCleanup(setattr, tempfile, "tempdir", old)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, "private_keys"))
        patcher = mock.patch.dict(os.environ, {"HOME": self.home})
        patcher.start()
        self.addCleanup(patcher.stop)

    # -- helpers

    def secret_fragments(self, *pems):
        out = []
        for pem in (pems or (self.pem,)):
            out.append(pem)
            out.extend(l for l in pem.splitlines() if not l.startswith("-----"))
        return out

    def assertNoSecret(self, text, *pems):
        for frag in self.secret_fragments(*pems):
            self.assertNotIn(frag, text)

    def run_main(self, argv, runner=None, security=None, *pems):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = sm.main(argv, runner=runner, security_runner=security)
        self.assertNoSecret(out.getvalue() + err.getvalue(), *pems)
        return rc, out.getvalue(), err.getvalue()

    def write_p8(self, pem=None, key_id=KEY_ID):
        path = os.path.join(self.home, "private_keys", "AuthKe" + "y_%s.p8" % key_id)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, ((pem or self.pem) + "\n").encode())
        os.close(fd)
        return path

    def write_sources(self, secrets=None, allowed=(SNAPEND,), envs=("DEVELOPMENT",), dmode=0o700, fmode=0o600):
        d = os.path.join(self.tmp, "cfg")
        os.makedirs(d, exist_ok=True)
        os.chmod(d, dmode)
        p = os.path.join(d, "sources.json")
        if secrets is None:
            secrets = {"apple/%s/private_key" % KEY_ID: {
                "file": "~/private_keys/AuthKe" + "y_%s.p8" % KEY_ID, "strip": True, "expect": "pem"}}
        with open(p, "w") as f:
            json.dump({"version": 1, "allowed_snapends": list(allowed),
                       "allowed_environments": list(envs), "secrets": secrets}, f)
        os.chmod(p, fmode)
        return p

    def write_committed(self, live, name="snapend-manifest.json"):
        obj, _ = sm.canonical(live)
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(sm.dumps(obj))
        return path

    def assertWorkClean(self):
        self.assertEqual(os.listdir(self.work), [])


class RedactTest(Base):
    def test_three_tiers_one_name_deterministic(self):
        live = make_live(self.pem)
        a, found = sm.canonical(live)
        b, _ = sm.canonical(copy.deepcopy(live))
        self.assertEqual(sm.dumps(a), sm.dumps(b))
        self.assertEqual(list(found), ["apple/%s/private_key" % KEY_ID])
        auth = a["settings"][1]["data"]
        for t in ("dev", "stage", "prod"):
            self.assertEqual(auth[t]["apple"]["private_key"], "@@secret:apple/%s/private_key@@" % KEY_ID)
            self.assertEqual(auth[t]["apple"]["key_id"], KEY_ID)
            self.assertEqual(auth[t]["apple"]["team_id"], "FAKETEAM01")
        text = sm.dumps(a)
        self.assertNoSecret(text)
        self.assertNotIn("applied_configuration", text)
        for k in sm.VOLATILE:
            self.assertNotIn('"%s"' % k, text)
        self.assertTrue(text.endswith("}\n"))
        # Key order follows the server's.
        self.assertEqual(list(a)[:4], ["version", "id", "name", "environment"])
        # Redacting a redacted manifest is a no-op.
        c, again = sm.canonical(a)
        self.assertEqual(sm.dumps(c), text)
        self.assertEqual(again, {})

    def test_round_trip(self):
        live = make_live(self.pem)
        red, found = sm.canonical(live)
        self.assertEqual(sm.inject(red, found), sm.strip_volatile(live))

    def test_same_name_different_values_fails(self):
        live = make_live(self.pem)
        live["settings"][1]["data"]["prod"]["apple"]["private_key"] = make_pem()
        with self.assertRaises(sm.ToolError) as cm:
            sm.canonical(live)
        self.assertNoSecret(str(cm.exception))

    def test_per_tier_keys_get_own_names(self):
        live = make_live(self.pem)
        other = make_pem()
        live["settings"][1]["data"]["prod"] = tier(other, "FAKEKEY002")
        _, found = sm.canonical(live)
        self.assertEqual(sorted(found), ["apple/FAKEKEY001/private_key", "apple/FAKEKEY002/private_key"])

    def test_catch_all_fields(self):
        live = make_live(self.pem)
        dev = live["settings"][1]["data"]["dev"]
        dev["google"] = {"enabled": True, "client_id": "fake-client.example", "client_secret": "gsecret-123"}
        steam = {"enabled": True, "app_id": "480"}
        for f in sm.STEAM_FIELDS:
            steam[f] = "steam-" + f
        dev["steam"] = steam
        live["settings"].append({"id": "notifications", "data": {
            "service_account": {"private_key": self.pem, "private_key_id": "pkid-1"},
            "hooks": [{"name": "h1", "webhook_secret": "wh-1", "token": "tok-1", "signing_key": "sk-1"}],
            "loose": {"note": "x " + self.pem},
            "pems": [self.pem]}})
        red, found = sm.canonical(live)
        names = set(found)
        self.assertIn("google/fake-client.example/client_secret", names)
        for f in sm.STEAM_FIELDS:
            self.assertIn("steam/480/%s" % f, names)
        self.assertIn(SNAPEND + "/settings.notifications.data.service_account.private_key", names)
        self.assertIn(SNAPEND + "/settings.notifications.data.service_account.private_key_id", names)
        for k in ("webhook_secret", "token", "signing_key"):
            self.assertIn(SNAPEND + "/settings.notifications.data.hooks.h1." + k, names)
        self.assertIn(SNAPEND + "/settings.notifications.data.loose.note", names)
        self.assertIn(SNAPEND + "/settings.notifications.data.pems.0", names)
        text = sm.dumps(red)
        for v in ("gsecret-123", "pkid-1", "wh-1", "tok-1", "sk-1", "steam-web_api"):
            self.assertNotIn(v, text)
        self.assertNoSecret(text)
        self.assertEqual(sm.scan_obj(red), [])
        self.assertEqual(sm.inject(red, found), sm.strip_volatile(live))

    def test_non_secrets_untouched(self):
        live = make_live(self.pem)
        live["settings"][4]["data"]["keys"][0]["secret_hint"] = "fine"
        red, _ = sm.canonical(live)
        auth = red["settings"][1]["data"]["dev"]
        self.assertEqual(auth["session_token_validity"], 2592000)
        self.assertEqual(auth["password"], {"enabled": True})
        self.assertIsNone(auth["google"])
        self.assertEqual(red["settings"][3]["data"]["statistics"][0]["key"], "runs")
        self.assertEqual(red["settings"][4]["data"]["keys"][0],
                         {"key": "save_v1", "is_prefix_key": False, "secret_hint": "fine"})
        # Empty strings are not secrets.
        live["settings"][1]["data"]["dev"]["apple"]["private_key"] = ""
        live["settings"][1]["data"]["stage"]["apple"]["private_key"] = ""
        live["settings"][1]["data"]["prod"]["apple"]["private_key"] = ""
        red, found = sm.canonical(live)
        self.assertEqual(found, {})

    def test_placeholders_and_inject_refusal(self):
        red, _ = sm.canonical(make_live(self.pem))
        paths = sm.placeholders(red)
        self.assertEqual(len(paths), 3)
        self.assertTrue(all(p.startswith(".settings[auth].data.") for p, _ in paths))
        with self.assertRaises(sm.ToolError) as cm:
            sm.inject(red, {})
        self.assertEqual(cm.exception.code, sm.EXIT_REFUSED)


class ApplyManifestTest(Base):
    def test_splice_and_overlay(self):
        live = make_live(self.pem)
        red, found = sm.canonical(make_live(self.pem, extra_stat=True))
        red["settings"][0]["data"]["events"].append({"name": "new_event", "properties": []})
        t = sm.build_apply_manifest(sm.inject(red, found), live)
        self.assertEqual(t["applied_configuration"], live["applied_configuration"])
        self.assertEqual(list(t)[-1], "applied_configuration")
        for s_t, s_l in zip(t["settings"], live["settings"]):
            self.assertEqual(s_t["exported_at"], s_l["exported_at"])
        ev = t["settings"][0]["data"]["events"]
        self.assertEqual(ev[0]["created_at"], "1700000000")
        self.assertNotIn("created_at", ev[1])
        cfg = t["settings"][2]["data"]["app_configs"][0]
        self.assertEqual((cfg["revision"], cfg["created_at"], cfg["updated_at"]), (3, "1", "2"))
        stats = t["settings"][3]["data"]["statistics"]
        self.assertEqual(stats[0]["created_by"], "u-1")
        self.assertEqual(stats[1]["key"], "wins")
        self.assertEqual(t["settings"][1]["data"]["dev"]["apple"]["private_key"], self.pem)

    def test_live_without_applied_configuration_refused(self):
        live = make_live(self.pem)
        live.pop("applied_configuration")
        with self.assertRaises(sm.ToolError):
            sm.build_apply_manifest({"settings": []}, live)


class ScrubTest(Base):
    def test_scrub_forms(self):
        values = {"apple/K/private_key": self.pem, "x/token": "tok-abcdef"}
        line = [l for l in self.pem.splitlines() if not l.startswith("-----")][0]
        text = "raw %s | json %s | line %s | tok-abcdef | other %s" % (
            self.pem, json.dumps(self.pem), line, make_pem())
        out = sm.scrub(text, values)
        self.assertNoSecret(out)
        self.assertNotIn("tok-abcdef", out)
        self.assertNotIn("BEGIN", out)
        self.assertIn("@@secret:apple/K/private_key@@", out)


class ScanTest(Base):
    def test_scan_obj(self):
        live = make_live(self.pem)
        hits = sm.scan_obj(live)
        paths = [p for p, _ in hits]
        self.assertIn(".settings[auth].data.dev.apple.private_key", paths)
        self.assertTrue(any(p.startswith(".applied_configuration>") for p in paths))
        self.assertNoSecret(repr(hits))
        red, _ = sm.canonical(live)
        self.assertEqual(sm.scan_obj(red), [])
        red["settings"][1]["data"]["dev"]["api_keys"] = [{"name": "server"}]
        self.assertEqual(len(sm.scan_obj(red)), 1)

    def test_scan_cli_paths(self):
        bad = os.path.join(self.tmp, "d", "bad.json")
        os.makedirs(os.path.dirname(bad))
        with open(bad, "w") as f:
            json.dump(make_live(self.pem), f)
        good = self.write_committed(make_live(self.pem))
        rc, out, _ = self.run_main(["scan", good])
        self.assertEqual(rc, 0)
        rc, out, _ = self.run_main(["scan", os.path.dirname(bad)])
        self.assertEqual(rc, 1)
        self.assertIn("bad.json .settings[auth].data.dev.apple.private_key: pem", out)

    def test_scan_staged(self):
        repo = os.path.join(self.tmp, "repo")
        os.mkdir(repo)
        git = ["git", "-C", repo]
        subprocess.run(git + ["init", "-q"], check=True)
        good = os.path.join(repo, "m.json")
        with open(good, "w") as f:
            f.write(sm.dumps(sm.canonical(make_live(self.pem))[0]))
        subprocess.run(git + ["add", "m.json"], check=True)
        cwd = os.getcwd()
        os.chdir(repo)
        try:
            rc, out, _ = self.run_main(["scan", "--staged"])
            self.assertEqual(rc, 0, out)
            with open(os.path.join(repo, "notes.txt"), "w") as f:
                f.write("oops\n" + self.pem + "\n")
            with open(os.path.join(repo, "AuthKe" + "y_X.p8"), "w") as f:
                f.write("x")
            # The working tree has a leak but it is not staged yet.
            rc, out, _ = self.run_main(["scan", "--staged"])
            self.assertEqual(rc, 0)
            subprocess.run(git + ["add", "notes.txt", "AuthKe" + "y_X.p8"], check=True)
            rc, out, _ = self.run_main(["scan", "--staged"])
            self.assertEqual(rc, 1)
            self.assertIn("SECRET notes.txt: pem", out)
            self.assertIn(".p8 file", out)
        finally:
            os.chdir(cwd)


class CommandTest(Base):
    def test_fmt_check_and_rewrite(self):
        path = os.path.join(self.tmp, "raw.json")
        with open(path, "w") as f:
            json.dump(make_live(self.pem), f)
        rc, out, _ = self.run_main(["fmt", "--check", path])
        self.assertEqual(rc, 1)
        rc, out, _ = self.run_main(["fmt", path])
        self.assertEqual(rc, 0)
        self.assertIn("redacted 1 secret(s)", out)
        with open(path) as f:
            self.assertNoSecret(f.read())
        rc, _, _ = self.run_main(["fmt", "--check", path])
        self.assertEqual(rc, 0)

    def test_pull_whole_and_into_only(self):
        fake = FakeSnapctl(make_live(self.pem))
        out = os.path.join(self.tmp, "out.json")
        rc, text, _ = self.run_main(["pull", "--snapend", SNAPEND, "--out", out], fake)
        self.assertEqual(rc, 0)
        self.assertIn("placeholder apple/%s/private_key" % KEY_ID, text)
        with open(out) as f:
            body = f.read()
        self.assertNoSecret(body)
        self.assertWorkClean()
        # A local pending board survives a --only auth pull.
        local = json.loads(body)
        local["settings"][3]["data"]["statistics"].append({"key": "pending", "type": "counter"})
        local["settings"][1]["data"]["dev"]["anon"]["enabled"] = False
        with open(out, "w") as f:
            f.write(sm.dumps(local))
        rc, _, _ = self.run_main(["pull", "--snapend", SNAPEND, "--into", out, "--only", "auth", "--out", out], fake)
        self.assertEqual(rc, 0)
        with open(out) as f:
            merged = json.load(f)
        self.assertEqual(merged["settings"][3]["data"]["statistics"][-1]["key"], "pending")
        self.assertTrue(merged["settings"][1]["data"]["dev"]["anon"]["enabled"])
        rc, _, _ = self.run_main(["pull", "--snapend", OTHER, "--into", out, "--only", "auth", "--out", out],
                                 FakeSnapctl(make_live(self.pem, OTHER)))
        self.assertEqual(rc, 3)

    def test_diff_check_secrets(self):
        live = make_live(self.pem)
        committed = self.write_committed(live)
        src = self.write_sources()
        rc, out, _ = self.run_main(["--sources", src, "diff", "--snapend", SNAPEND, committed, "--check-secrets"],
                                   FakeSnapctl(live))
        self.assertEqual(rc, 1, out)
        self.assertIn("redacted content identical", out)
        self.assertIn("secret apple/%s/private_key: unresolved (missing file)" % KEY_ID, out)
        self.write_p8()
        rc, out, _ = self.run_main(["--sources", src, "diff", "--snapend", SNAPEND, committed, "--check-secrets"],
                                   FakeSnapctl(live))
        self.assertEqual(rc, 0, out)
        self.assertIn("secret apple/%s/private_key: match" % KEY_ID, out)
        other = make_pem()
        self.write_p8(other)
        rc, out, _ = self.run_main(["--sources", src, "diff", "--snapend", SNAPEND, committed, "--check-secrets"],
                                   FakeSnapctl(live), None, self.pem, other)
        self.assertEqual(rc, 1)
        self.assertIn("mismatch", out)
        drift = make_live(self.pem, extra_stat=True)
        rc, out, _ = self.run_main(["diff", "--snapend", SNAPEND, committed], FakeSnapctl(drift))
        self.assertEqual(rc, 1)
        self.assertIn('-            "key": "wins"', out)
        self.assertWorkClean()

    def test_unresolved_beats_match_in_diff(self):
        live = make_live(self.pem)
        committed = self.write_committed(live)
        src = self.write_sources(secrets={})
        rc, out, _ = self.run_main(["--sources", src, "diff", "--snapend", SNAPEND, committed, "--check-secrets"],
                                   FakeSnapctl(live))
        self.assertEqual(rc, 1)
        self.assertIn("unresolved (no source)", out)

    def test_secrets_init_and_check_never_open_p8(self):
        committed = self.write_committed(make_live(self.pem))
        real_open = builtins.open

        def guarded(path, *a, **k):
            if str(path).endswith(".p8"):
                raise AssertionError("opened a .p8")
            return real_open(path, *a, **k)

        src = os.path.join(self.tmp, "cfgdir", "sources.json")
        with mock.patch("builtins.open", guarded):
            rc, out, err = self.run_main(["--sources", src, "secrets", "init", committed, "--write"])
            self.assertEqual(rc, 0, err)
            self.assertIn("MISSING", err)
            self.assertEqual(stat.S_IMODE(os.stat(src).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(src)).st_mode), 0o700)
            rc, out, _ = self.run_main(["--sources", src, "secrets", "check", committed])
            self.assertEqual(rc, 1)
            self.assertIn("MISSING (file not found)", out)
            self.write_p8()
            rc, out, _ = self.run_main(["--sources", src, "secrets", "check", committed])
            self.assertEqual(rc, 0, out)
            self.assertIn("OK (file exists)", out)
            rc, _, _ = self.run_main(["--sources", src, "secrets", "init", committed, "--write"])
            self.assertEqual(rc, 2)
        with open(src) as f:
            doc = json.load(f)
        self.assertEqual(doc["allowed_snapends"], [SNAPEND])
        self.assertEqual(doc["allowed_environments"], ["DEVELOPMENT"])

    def test_loose_modes_refused(self):
        committed = self.write_committed(make_live(self.pem))
        self.write_p8()
        for dmode, fmode in ((0o755, 0o600), (0o700, 0o644)):
            src = self.write_sources(dmode=dmode, fmode=fmode)
            rc, _, err = self.run_main(["--sources", src, "secrets", "check", committed])
            self.assertEqual(rc, 2, err)
            self.assertIn("group/other", err)

    def test_keychain_source(self):
        live = make_live(self.pem)
        live["settings"][1]["data"]["dev"]["google"] = {"client_id": "cid", "client_secret": "gs-777"}
        committed = self.write_committed(live)
        self.write_p8()
        secrets = {"apple/%s/private_key" % KEY_ID: {"file": "~/private_keys/AuthKe" + "y_%s.p8" % KEY_ID,
                                                     "strip": True, "expect": "pem"},
                   "google/cid/client_secret": {"keychain": {"service": "s", "account": "a"}}}
        src = self.write_sources(secrets=secrets)
        seen = []

        def security(args):
            seen.append(args)
            return 0, "gs-777\n"
        rc, out, _ = self.run_main(["--sources", src, "diff", "--snapend", SNAPEND, committed, "--check-secrets"],
                                   FakeSnapctl(live), security)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("gs-777", out)
        self.assertIn("secret google/cid/client_secret: match", out)
        self.assertEqual(seen[0][:2], ["security", "find-generic-password"])


class ApplyTest(Base):
    def setUp(self):
        Base.setUp(self)
        self.live = make_live(self.pem)
        self.committed = self.write_committed(self.live)
        self.write_p8()
        self.src = self.write_sources()

    def apply(self, fake, *extra):
        return self.run_main(["--sources", self.src, "apply", "--snapend", SNAPEND, self.committed] + list(extra),
                             fake)

    def test_noop_skips_without_allow_noop(self):
        fake = FakeSnapctl(self.live)
        rc, out, _ = self.apply(fake, "--yes")
        self.assertEqual(rc, 0)
        self.assertIn("no changes", out)
        self.assertEqual(fake.applies, [])
        self.assertWorkClean()

    def test_noop_reapply_verifies(self):
        fake = FakeSnapctl(self.live)
        rc, out, _ = self.apply(fake, "--yes", "--allow-noop")
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(fake.applies), 1)
        a = fake.applies[0]
        self.assertEqual(a["mode"], 0o600)
        self.assertEqual(a["dir_mode"], 0o700)
        self.assertFalse(os.path.exists(a["dir"]))
        self.assertEqual(a["manifest"]["settings"][1]["data"]["prod"]["apple"]["private_key"], self.pem)
        self.assertIn("verify redacted live == committed: True", out)
        for t in ("dev", "stage", "prod"):
            self.assertIn("verify %s private_key_set: True" % t, out)
        self.assertIn("@@secret:apple/%s/private_key@@" % KEY_ID, out)  # scrubbed echo
        self.assertWorkClean()

    def test_change_applies(self):
        changed = make_live(self.pem, extra_stat=True)
        self.committed = self.write_committed(changed)
        fake = FakeSnapctl(self.live)
        rc, out, _ = self.apply(fake, "--yes")
        self.assertEqual(rc, 0, out)
        self.assertIn('+            "key": "wins"', out)
        self.assertEqual(fake.live["settings"][3]["data"]["statistics"][1]["key"], "wins")

    def test_dry_run_and_confirmation(self):
        self.committed = self.write_committed(make_live(self.pem, extra_stat=True))
        fake = FakeSnapctl(self.live)
        rc, out, _ = self.apply(fake, "--dry-run")
        self.assertEqual((rc, fake.applies), (0, []))
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            rc, _, err = self.apply(fake)
        self.assertEqual(rc, 3)
        self.assertIn("not confirmed", err)
        self.assertEqual(fake.applies, [])
        with mock.patch.object(sys.stdin, "isatty", return_value=True), \
                mock.patch("builtins.input", return_value=SNAPEND):
            rc, _, _ = self.apply(fake)
        self.assertEqual((rc, len(fake.applies)), (0, 1))
        self.assertWorkClean()

    def test_refusals(self):
        fake = FakeSnapctl(self.live)
        # Not allow-listed.
        self.src = self.write_sources(allowed=(OTHER,))
        self.assertEqual(self.apply(fake, "--yes", "--allow-noop")[0], 3)
        # Environment not allowed.
        self.src = self.write_sources(envs=("PRODUCTION",))
        self.assertEqual(self.apply(fake, "--yes", "--allow-noop")[0], 3)
        # File id differs from --snapend.
        self.src = self.write_sources(allowed=(SNAPEND, OTHER))
        rc, _, _ = self.run_main(["--sources", self.src, "apply", "--snapend", OTHER, self.committed, "--yes"], fake)
        self.assertEqual(rc, 3)
        # Unresolved placeholder.
        self.src = self.write_sources(secrets={})
        self.assertEqual(self.apply(fake, "--yes", "--allow-noop")[0], 3)
        # Missing .p8.
        self.src = self.write_sources()
        os.remove(os.path.join(self.home, "private_keys", "AuthKe" + "y_%s.p8" % KEY_ID))
        rc, _, err = self.apply(fake, "--yes", "--allow-noop")
        self.assertEqual(rc, 3)
        self.assertIn("missing file", err)
        # Not a PEM.
        self.write_p8("not a key")
        rc, _, err = self.apply(fake, "--yes", "--allow-noop")
        self.assertEqual(rc, 3)
        self.assertIn("pem check failed", err)
        # Unredacted committed file.
        with open(self.committed, "w") as f:
            json.dump(sm.strip_volatile(self.live), f)
        self.write_p8()
        self.assertEqual(self.apply(fake, "--yes", "--allow-noop")[0], 3)
        self.assertEqual(fake.applies, [])
        self.assertWorkClean()

    def test_apply_failure_cleans_up(self):
        fake = FakeSnapctl(self.live, apply_rc=1)
        rc, _, err = self.apply(fake, "--yes", "--allow-noop")
        self.assertEqual(rc, 4)
        self.assertFalse(os.path.exists(fake.applies[0]["dir"]))
        self.assertWorkClean()

    def test_exception_cleans_up(self):
        def boom():
            raise RuntimeError("network down")
        fake = FakeSnapctl(self.live, explode=("apply", boom))
        with self.assertRaises(RuntimeError):
            self.apply(fake, "--yes", "--allow-noop")
        self.assertWorkClean()

    def test_sigterm_cleans_up(self):
        fake = FakeSnapctl(self.live, explode=("apply", lambda: os.kill(os.getpid(), signal.SIGTERM)))
        rc, _, err = self.apply(fake, "--yes", "--allow-noop")
        self.assertEqual(rc, 130)
        self.assertWorkClean()
        self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_DFL)

    def test_verify_mismatch(self):
        def drop_key(m):
            m["settings"][1]["data"]["prod"]["apple"] = None
        fake = FakeSnapctl(self.live, mutate=drop_key)
        rc, out, _ = self.apply(fake, "--yes", "--allow-noop")
        self.assertEqual(rc, 5)
        self.assertIn("verify prod private_key_set: False", out)
        self.assertWorkClean()


class WrapperTest(Base):
    def test_sh_unsets_key_and_runs_fake_snapctl(self):
        live = make_live(self.pem)
        committed = self.write_committed(live)
        state = os.path.join(self.tmp, "fake-state.json")
        with open(state, "w") as f:
            json.dump(live, f)
        fake = os.path.join(self.tmp, "snapctl")
        with open(fake, "w") as f:
            f.write("#!/usr/bin/env python3\n"
                    "import json, os, sys\n"
                    "a = sys.argv[1:]\n"
                    "leak = ('SNAPSER_API_' + 'KEY') in os.environ\n"
                    "open(%r, 'w').write('leak' if leak else 'clean')\n"
                    "out = a[a.index('--out-path') + 1]\n"
                    "m = json.load(open(%r))\n"
                    "json.dump(m, open(os.path.join(out, 'snapser-%%s-manifest.json' %% m['id']), 'w'))\n"
                    % (os.path.join(self.tmp, "leak.txt"), state))
        os.chmod(fake, 0o700)
        env = dict(os.environ)
        env["SNAPSER_API_" + "KEY"] = "sentinel-not-a-key"
        env[sm.SNAPCTL_ENV] = fake
        env["TMPDIR"] = self.work
        r = subprocess.run([os.path.join(TOOLS, "snapend_manifest.sh"), "diff", "--snapend", SNAPEND, committed],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNoSecret(r.stdout + r.stderr)
        with open(os.path.join(self.tmp, "leak.txt")) as f:
            self.assertEqual(f.read(), "clean")
        self.assertWorkClean()


if __name__ == "__main__":
    unittest.main()

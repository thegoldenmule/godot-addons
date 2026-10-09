#!/usr/bin/env python3
"""Redacted Snapser snapend manifests: commit placeholders, inject secrets at apply.

Run it through snapend_manifest.sh, which unsets the platform-key environment
variable (env -u) so snapctl reads its key from ~/.snapser/config.

A committed manifest is the server's snapend manifest with:
  - `applied_configuration` dropped (it is an opaque blob that mirrors the
    whole manifest, secrets included; apply takes it from live instead);
  - volatile keys dropped everywhere (exported_at, created_at, updated_at,
    created_by, revision, last_run_at);
  - every secret string replaced by a whole-value placeholder
    "@@secret:<name>@@".

Placeholder names:
  apple/<key_id>/private_key               Apple Sign in key (the .p8 body)
  <connector>/<client_id>/client_secret    google, facebook, epic, xbox, discord, x, app_verify
  steam/<app_id>/<field>                   steam keys
  <snapend-id>/<dotted json path>          anything else that looks secret

Secret sources live outside every repo, in ~/.config/snapser-secrets/sources.json
(directory 0700, file 0600; looser modes are refused). The file holds references
only, never values:
  {"version": 1,
   "allowed_snapends": ["<snapend-id>", ...],
   "allowed_environments": ["DEVELOPMENT"],
   "secrets": {
     "apple/<key-id>/private_key": {"file": "~/private_keys/<file>.p8", "strip": true, "expect": "pem"},
     "<name>": {"keychain": {"service": "snapser-secrets", "account": "<name>"}}}}

Commands (exit codes: 0 ok, 1 drift or scan hit, 2 usage/config, 3 refused,
4 apply failed, 5 verify mismatch):
  pull    --snapend ID --out FILE [--into FILE --only SETTING_ID ...]
  fmt     FILE... [--check]
  diff    --snapend ID FILE [--check-secrets]
  apply   --snapend ID FILE [--dry-run] [--yes] [--allow-noop] [--no-verify]
  scan    [PATHS...] [--staged]
  secrets check FILE...
  secrets init  FILE... [--write]

Nothing here ever prints a secret value. Output is limited to placeholder
names, JSON paths, booleans, lengths and sha256-equality results, and every
line snapctl prints is scrubbed before it is shown.
"""
import argparse
import copy
import difflib
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

EXIT_OK, EXIT_DRIFT, EXIT_USAGE, EXIT_REFUSED, EXIT_APPLY, EXIT_VERIFY = 0, 1, 2, 3, 4, 5

VOLATILE = ("exported_at", "created_at", "updated_at", "created_by", "revision", "last_run_at")
APPLIED = "applied_configuration"
IDENTITY = ("id", "key", "name")

PLACEHOLDER_RE = re.compile(r"^@@secret:([A-Za-z0-9_./-]+)@@$")
# Built from parts so a repo-wide secret grep never matches this source.
_PEM_WORD = "PRIVATE " + "KEY"
PEM_ANY_RE = re.compile(r"-----BEGIN [A-Z0-9 ]+-----")
PEM_PRIVATE_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*" + _PEM_WORD + "-----")
PEM_BLOCK_RE = re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?(-----END [A-Z0-9 ]+-----|$)", re.S)

CONNECTORS = ("google", "facebook", "epic", "xbox", "discord", "x", "app_verify")
STEAM_FIELDS = ("api" + "_key", "web_api" + "_key", "publisher_api" + "_key")
CATCH_ALL = frozenset((
    "private_key", "private_key_id", "client_secret", "secret", "token",
    "webhook_secret", "signing_key") + STEAM_FIELDS)
NEVER = frozenset(("key_id", "key", "session_token_validity", "is_prefix_key"))

DEFAULT_SOURCES = "~/.config/snapser-secrets/sources.json"
SOURCES_ENV = "SNAPSER_SECRETS_SOURCES"
SNAPCTL_ENV = "SNAPSER_SNAPCTL"
# The platform-key variable name, assembled so secret greps stay meaningful.
_KEYVAR = "SNAPSER_API_" + "KEY"
P8_PREFIX = "AuthKe" + "y_"


class ToolError(Exception):
    """A handled failure. `code` is the exit code; the message never holds a value."""

    def __init__(self, message, code=EXIT_USAGE):
        Exception.__init__(self, message)
        self.code = code


# ---------------------------------------------------------------- json io

def dumps(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def load_json_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise ToolError("cannot read JSON %s (%s)" % (path, type(e).__name__))


def write_text(path, text, mode=None):
    tmp = path + ".tmp-snapend-manifest"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(tmp, flags, mode if mode is not None else 0o644)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def sha(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- pure transforms

def strip_volatile(obj, top=True):
    """Copy of `obj` without applied_configuration (top level) or volatile keys."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in VOLATILE or (top and k == APPLIED):
                continue
            out[k] = strip_volatile(v, False)
        return out
    if isinstance(obj, list):
        return [strip_volatile(v, False) for v in obj]
    return obj


def is_placeholder(value):
    return isinstance(value, str) and PLACEHOLDER_RE.match(value) is not None


def placeholder(name):
    return "@@secret:%s@@" % name


def is_pem(value):
    return isinstance(value, str) and PEM_ANY_RE.search(value) is not None


def _seg(text):
    s = re.sub(r"[^A-Za-z0-9_.-]", "_", str(text))
    return s or "_"


def _item_label(item, index):
    if isinstance(item, dict):
        for k in IDENTITY:
            v = item.get(k)
            if isinstance(v, (str, int)) and not isinstance(v, bool) and str(v) != "":
                return str(v)
    return str(index)


def _secret_name(parent, key, path, snapend_id):
    """Placeholder name for parent[key], or the snapend-scoped fallback."""
    parent_key = path[-1] if path else None
    if key == "private_key" and parent_key == "apple":
        kid = parent.get("key_id")
        if isinstance(kid, str) and kid:
            return "apple/%s/private_key" % _seg(kid)
    if key == "client_secret" and parent_key in CONNECTORS:
        cid = parent.get("client_id")
        if isinstance(cid, str) and cid:
            return "%s/%s/client_secret" % (parent_key, _seg(cid))
    if key in STEAM_FIELDS and parent_key == "steam":
        aid = parent.get("app_id")
        if isinstance(aid, (str, int)) and not isinstance(aid, bool) and str(aid):
            return "steam/%s/%s" % (_seg(aid), key)
    return "%s/%s" % (_seg(snapend_id or "snapend"), ".".join(_seg(p) for p in path + [key]))


def _is_secret_field(key, value):
    if not isinstance(value, str) or value == "":
        return False
    if is_pem(value):
        return True
    return key in CATCH_ALL and key not in NEVER


def redact(obj, snapend_id=None):
    """Return (redacted copy, {name: value}). Raises ToolError on a name clash.

    A secret is any non-empty string under a catch-all key name, or any string
    holding a PEM header. Existing placeholders are kept as they are.
    """
    if snapend_id is None and isinstance(obj, dict):
        snapend_id = obj.get("id")
    found = {}

    def record(name, value):
        prev = found.get(name)
        if prev is not None and sha(prev) != sha(value):
            raise ToolError("secret name %s maps to different values" % name, EXIT_REFUSED)
        found[name] = value

    def walk(node, path):
        if isinstance(node, dict):
            out = {}
            for k, v in node.items():
                if isinstance(v, str) and not is_placeholder(v) and _is_secret_field(k, v):
                    name = _secret_name(node, k, path, snapend_id)
                    record(name, v)
                    out[k] = placeholder(name)
                else:
                    out[k] = walk(v, path + [k])
            return out
        if isinstance(node, list):
            out = []
            for i, v in enumerate(node):
                if isinstance(v, str) and not is_placeholder(v) and is_pem(v):
                    name = _secret_name({}, _item_label(v, i), path, snapend_id)
                    record(name, v)
                    out.append(placeholder(name))
                else:
                    out.append(walk(v, path + [_item_label(v, i)]))
            return out
        return node

    return walk(obj, []), found


def canonical(obj, snapend_id=None):
    """The committed form of a manifest: (redacted, stripped obj, {name: value})."""
    return redact(strip_volatile(obj), snapend_id)


def placeholders(obj, path=""):
    """[(json path, name)] for every placeholder in obj."""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.extend(placeholders(v, "%s.%s" % (path, k)))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out.extend(placeholders(v, "%s[%s]" % (path, _item_label(v, i))))
    elif is_placeholder(obj):
        out.append((path or ".", PLACEHOLDER_RE.match(obj).group(1)))
    return out


def placeholder_names(obj):
    seen = []
    for _, name in placeholders(obj):
        if name not in seen:
            seen.append(name)
    return seen


def inject(obj, values):
    """Copy of obj with every placeholder replaced. Raises on an unresolved one."""
    missing = [n for n in placeholder_names(obj) if n not in values]
    if missing:
        raise ToolError("unresolved placeholder(s): %s" % ", ".join(missing), EXIT_REFUSED)

    def walk(node):
        if isinstance(node, dict):
            return {k: walk(v) for k, v in node.items()}
        if isinstance(node, list):
            return [walk(v) for v in node]
        if is_placeholder(node):
            return values[PLACEHOLDER_RE.match(node).group(1)]
        return node

    return walk(obj)


def _match_index(items, item):
    if not isinstance(item, dict):
        return None
    for k in IDENTITY:
        if k in item:
            for j, other in enumerate(items):
                if isinstance(other, dict) and other.get(k) == item[k]:
                    return j
            return None
    return None


def overlay_volatile(target, live):
    """Copy volatile keys from live into target, matching list items by id/key/name."""
    if isinstance(target, dict) and isinstance(live, dict):
        for k in VOLATILE:
            if k in live and k not in target:
                target[k] = live[k]
        for k, v in target.items():
            if k in live and k not in VOLATILE:
                overlay_volatile(v, live[k])
    elif isinstance(target, list) and isinstance(live, list):
        for item in target:
            j = _match_index(live, item)
            if j is not None:
                overlay_volatile(item, live[j])
    return target


def build_apply_manifest(injected, live):
    """The manifest to upload: injected content, live volatile fields, live
    applied_configuration verbatim (the server compares it with its own)."""
    if APPLIED not in live:
        raise ToolError("live manifest has no %s" % APPLIED, EXIT_REFUSED)
    t = overlay_volatile(copy.deepcopy(injected), live)
    t.pop(APPLIED, None)
    t[APPLIED] = live[APPLIED]
    return t


def scrub(text, values):
    """Replace every resolved value (raw, JSON-escaped, or a long PEM line) and any
    PEM block in text with placeholders."""
    if not text:
        return text
    pairs = []
    for name, value in values.items():
        if not value:
            continue
        ph = placeholder(name)
        pairs.append((value, ph))
        escaped = json.dumps(value)[1:-1]
        if escaped != value:
            pairs.append((escaped, ph))
        for line in value.splitlines():
            line = line.strip()
            if len(line) >= 16 and not line.startswith("-----"):
                pairs.append((line, ph))
    pairs.sort(key=lambda p: -len(p[0]))
    for raw, ph in pairs:
        text = text.replace(raw, ph)
    return PEM_BLOCK_RE.sub("@@secret:redacted-pem@@", text)


def scan_obj(obj, path=""):
    """[(json path, reason)] for every unredacted secret, applied_configuration included."""
    hits = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = "%s.%s" % (path, k)
            if k == APPLIED and isinstance(v, str):
                try:
                    inner = json.loads(v)
                except ValueError:
                    if is_pem(v):
                        hits.append((p, "pem"))
                    continue
                hits.extend(scan_obj(inner, p + ">"))
            elif isinstance(v, str):
                if is_placeholder(v):
                    continue
                if is_pem(v):
                    hits.append((p, "pem"))
                elif _is_secret_field(k, v):
                    hits.append((p, "secret field '%s'" % k))
            else:
                if k == "api_keys" and isinstance(v, list) and v:
                    # Auth API keys have no redaction rule yet: make a human look.
                    hits.append((p, "non-empty api_keys (no redaction rule; review by hand)"))
                hits.extend(scan_obj(v, p))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            p = "%s[%s]" % (path, _item_label(v, i))
            if isinstance(v, str):
                if not is_placeholder(v) and is_pem(v):
                    hits.append((p, "pem"))
            else:
                hits.extend(scan_obj(v, p))
    return hits


def scan_text(text):
    return PEM_PRIVATE_RE.search(text) is not None


def scan_blob(display, name, data):
    """Hits for one file's bytes: [(display, json path or '-', reason)]."""
    if name.endswith(".p8"):
        return [(display, "-", ".p8 file")]
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return [(display, "-", "pem")] if PEM_PRIVATE_RE.search(data.decode("latin-1")) else []
    if name.endswith(".json"):
        try:
            obj = json.loads(text)
        except ValueError:
            obj = None
        if obj is not None:
            return [(display, p, r) for p, r in scan_obj(obj)]
    return [(display, "-", "pem")] if scan_text(text) else []


def plan_diff(committed_text, live_text, a="committed", b="live"):
    return "".join(difflib.unified_diff(
        live_text.splitlines(True), committed_text.splitlines(True), b, a))


# ---------------------------------------------------------------- secret sources

def sources_path(arg=None):
    return os.path.expanduser(arg or os.environ.get(SOURCES_ENV) or DEFAULT_SOURCES)


def _check_mode(path, what):
    st = os.stat(path)
    if stat.S_IMODE(st.st_mode) & 0o077:
        raise ToolError("%s %s is group/other accessible (mode %o); chmod it to 0%s"
                        % (what, path, stat.S_IMODE(st.st_mode), "700" if what == "directory" else "600"))
    if st.st_uid != os.getuid():
        raise ToolError("%s %s is not owned by you" % (what, path))


def load_sources(path):
    if not os.path.isfile(path):
        raise ToolError("no secret sources file at %s (run: secrets init FILE --write)" % path)
    _check_mode(os.path.dirname(path) or ".", "directory")
    _check_mode(path, "file")
    src = load_json_file(path)
    if not isinstance(src, dict) or src.get("version") != 1 or not isinstance(src.get("secrets"), dict):
        raise ToolError("%s: expected {\"version\": 1, \"secrets\": {...}}" % path)
    return src


def default_security_runner(args):
    r = subprocess.run(args, capture_output=True, text=True)
    return r.returncode, r.stdout


def _pem_ok(value):
    begin = "-----BEGIN " + _PEM_WORD + "-----"
    end = "-----END " + _PEM_WORD + "-----"
    return value.startswith(begin) and value.rstrip().endswith(end)


def resolve(names, sources, security_runner=default_security_runner):
    """Return ({name: value}, {name: problem}). Values stay in memory only."""
    values, problems = {}, {}
    table = sources.get("secrets", {})
    for name in names:
        entry = table.get(name)
        if not isinstance(entry, dict):
            problems[name] = "unresolved (no source)"
            continue
        if "file" in entry:
            path = os.path.expanduser(str(entry["file"]))
            if not os.path.isfile(path):
                problems[name] = "missing file"
                continue
            with open(path, encoding="utf-8") as f:
                value = f.read()
        elif isinstance(entry.get("keychain"), dict):
            kc = entry["keychain"]
            rc, out = security_runner(["security", "find-generic-password",
                                       "-s", str(kc.get("service", "")),
                                       "-a", str(kc.get("account", "")), "-w"])
            if rc != 0:
                problems[name] = "keychain item not found"
                continue
            value = out[:-1] if out.endswith("\n") else out
        else:
            problems[name] = "unresolved (bad source entry)"
            continue
        if entry.get("strip"):
            value = value.strip()
        if entry.get("expect") == "pem" and not _pem_ok(value):
            problems[name] = "pem check failed"
            continue
        if not value:
            problems[name] = "empty value"
            continue
        values[name] = value
    return values, problems


# ---------------------------------------------------------------- snapctl

def default_snapctl_runner(args):
    env = dict(os.environ)
    env.pop(_KEYVAR, None)
    exe = os.environ.get(SNAPCTL_ENV) or "snapctl"
    try:
        r = subprocess.run([exe] + list(args), env=env, capture_output=True, text=True)
    except OSError as e:
        return 127, "snapctl not runnable (%s)" % type(e).__name__
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def _show(text, values, stream=None):
    stream = stream or sys.stdout
    clean = scrub(text, values).strip()
    if clean:
        lines = clean.splitlines()[-15:]
        stream.write("  snapctl: " + "\n  snapctl: ".join(lines) + "\n")


def download_live(snapend_id, workdir, runner, values=None):
    """Download the live manifest into workdir and return it parsed."""
    out = os.path.join(workdir, "dl")
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.mkdir(out, 0o700)
    rc, log = runner(["snapend", "download", "--snapend-id", snapend_id,
                      "--category", "snapend-manifest", "--format", "json",
                      "--out-path", out])
    path = os.path.join(out, "snapser-%s-manifest.json" % snapend_id)
    if rc != 0 or not os.path.isfile(path):
        _show(log, values or {}, sys.stderr)
        raise ToolError("download of %s failed (rc=%s)" % (snapend_id, rc), EXIT_USAGE)
    os.chmod(path, 0o600)
    live = load_json_file(path)
    if not isinstance(live, dict) or live.get("id") != snapend_id:
        raise ToolError("downloaded manifest id does not match %s" % snapend_id, EXIT_REFUSED)
    return live


class Workdir(object):
    """mkdtemp (0700), removed on exit even after SIGINT/SIGTERM."""

    def __enter__(self):
        self.path = tempfile.mkdtemp(prefix="snapend-manifest-")
        os.chmod(self.path, 0o700)
        self._old = signal.getsignal(signal.SIGTERM)

        def on_term(signum, frame):
            raise KeyboardInterrupt()
        try:
            signal.signal(signal.SIGTERM, on_term)
        except ValueError:  # not the main thread
            self._old = None
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)
        if self._old is not None:
            signal.signal(signal.SIGTERM, self._old)
        return False


# ---------------------------------------------------------------- commands

def _load_manifest(path):
    obj = load_json_file(path)
    if not isinstance(obj, dict) or "settings" not in obj:
        raise ToolError("%s does not look like a snapend manifest" % path)
    return obj


def _committed(path):
    """(canonical obj, canonical text, raw obj) of a committed manifest file."""
    raw = _load_manifest(path)
    obj, found = canonical(raw)
    if found:
        raise ToolError("%s holds %d unredacted secret(s); run fmt on it first" % (path, len(found)),
                        EXIT_REFUSED)
    return obj, dumps(obj), raw


def cmd_pull(a, runner, **_):
    with Workdir() as wd:
        live = download_live(a.snapend, wd, runner)
        live_c, found = canonical(live)
    if a.into:
        base = _load_manifest(a.into)
        if base.get("id") != a.snapend:
            raise ToolError("%s is for a different snapend" % a.into, EXIT_REFUSED)
        base_c, extra = canonical(base)
        if extra:
            raise ToolError("%s holds unredacted secrets; run fmt on it first" % a.into, EXIT_REFUSED)
        live_settings = {s.get("id"): s for s in live_c.get("settings", []) if isinstance(s, dict)}
        for sid in a.only:
            if sid not in live_settings:
                raise ToolError("live snapend has no setting %s" % sid)
            settings = base_c.setdefault("settings", [])
            idx = [i for i, s in enumerate(settings) if isinstance(s, dict) and s.get("id") == sid]
            if idx:
                settings[idx[0]] = live_settings[sid]
            else:
                settings.append(live_settings[sid])
        result = base_c
    else:
        result = live_c
    write_text(a.out, dumps(result))
    names = placeholder_names(result)
    print("pull %s -> %s (%s)" % (a.snapend, a.out, "settings %s from live" % ",".join(a.only) if a.into else "whole manifest"))
    for n in names:
        print("  placeholder %s" % n)
    return EXIT_OK


def cmd_fmt(a, **_):
    rc = EXIT_OK
    for path in a.files:
        with open(path, encoding="utf-8") as f:
            before = f.read()
        obj, found = canonical(_load_manifest(path))
        after = dumps(obj)
        if before == after:
            continue
        if a.check:
            print("fmt: %s is not canonical%s" % (path, " (holds %d unredacted secret(s))" % len(found) if found else ""))
            rc = EXIT_DRIFT
        else:
            write_text(path, after)
            print("fmt: rewrote %s%s" % (path, " (redacted %d secret(s))" % len(found) if found else ""))
    return rc


def _secret_report(names, values, problems, live_found):
    """[(name, status)] comparing resolved values with live by sha256."""
    out = []
    for n in names:
        if n in problems:
            out.append((n, "unresolved (%s)" % problems[n]))
        elif n not in live_found:
            out.append((n, "absent-live"))
        elif sha(values[n]) == sha(live_found[n]):
            out.append((n, "match"))
        else:
            out.append((n, "mismatch"))
    for n in live_found:
        if n not in names:
            out.append((n, "live-only"))
    return out


def cmd_diff(a, runner, security_runner, **_):
    obj, text, _raw = _committed(a.file)
    if obj.get("id") != a.snapend:
        raise ToolError("%s id does not equal --snapend" % a.file, EXIT_REFUSED)
    values, problems = {}, {}
    if a.check_secrets:
        values, problems = resolve(placeholder_names(obj), load_sources(sources_path(a.sources)), security_runner)
    with Workdir() as wd:
        live = download_live(a.snapend, wd, runner, values)
        live_c, live_found = canonical(live)
    d = plan_diff(text, dumps(live_c), "committed:" + a.file, "live:" + a.snapend)
    rc = EXIT_OK
    if d:
        sys.stdout.write(d)
        rc = EXIT_DRIFT
    else:
        print("diff %s: redacted content identical" % a.snapend)
    if a.check_secrets:
        for n, status in _secret_report(placeholder_names(obj), values, problems, live_found):
            print("secret %s: %s" % (n, status))
            if status != "match":
                rc = EXIT_DRIFT
    return rc


def _private_key_set(manifest):
    out = {}
    for s in manifest.get("settings", []):
        if isinstance(s, dict) and s.get("id") == "auth":
            for tier, conf in (s.get("data") or {}).items():
                if isinstance(conf, dict) and "anon" in conf:
                    apple = conf.get("apple") or {}
                    out[tier] = bool(isinstance(apple, dict) and apple.get("private_key"))
    return out


def _confirm(a):
    if a.yes:
        return True
    if not sys.stdin.isatty():
        return False
    try:
        typed = input("Type the snapend id (%s) to apply: " % a.snapend)
    except EOFError:
        return False
    return typed.strip() == a.snapend


def cmd_apply(a, runner, security_runner, **_):
    obj, text, _raw = _committed(a.file)
    if obj.get("id") != a.snapend:
        raise ToolError("REFUSED: %s id does not equal --snapend" % a.file, EXIT_REFUSED)
    sources = load_sources(sources_path(a.sources))
    if a.snapend not in (sources.get("allowed_snapends") or []):
        raise ToolError("REFUSED: %s is not in allowed_snapends" % a.snapend, EXIT_REFUSED)
    if obj.get("environment") not in (sources.get("allowed_environments") or []):
        raise ToolError("REFUSED: environment %s is not allowed" % obj.get("environment"), EXIT_REFUSED)
    names = placeholder_names(obj)
    values, problems = resolve(names, sources, security_runner)
    if problems:
        for n in names:
            if n in problems:
                print("secret %s: %s" % (n, problems[n]), file=sys.stderr)
        raise ToolError("REFUSED: %d secret(s) unresolved" % len(problems), EXIT_REFUSED)
    with Workdir() as wd:
        live = download_live(a.snapend, wd, runner, values)
        if live.get("environment") not in (sources.get("allowed_environments") or []):
            raise ToolError("REFUSED: live environment %s is not allowed" % live.get("environment"), EXIT_REFUSED)
        live_c, live_found = canonical(live)
        d = plan_diff(text, dumps(live_c), "committed:" + a.file, "live:" + a.snapend)
        report = _secret_report(names, values, {}, live_found)
        changed = [r for r in report if r[1] != "match"]
        print("plan for %s:" % a.snapend)
        if d:
            sys.stdout.write(d)
        for n, status in report:
            print("  secret %s: %s" % (n, {"match": "unchanged", "mismatch": "changed",
                                            "absent-live": "new", "live-only": "removed"}.get(status, status)))
        if not d and not changed:
            print("  no changes")
            if not a.allow_noop:
                return EXIT_OK
        if a.dry_run:
            print("dry run: nothing applied")
            return EXIT_OK
        if not _confirm(a):
            raise ToolError("REFUSED: not confirmed (pass --yes or type the id at a terminal)", EXIT_REFUSED)
        target = build_apply_manifest(inject(obj, values), live)
        path = os.path.join(wd, "snapser-%s-manifest.json" % a.snapend)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(target, indent=2, ensure_ascii=False))
        rc, log = runner(["snapend", "apply", "--manifest-path-filename", path, "--blocking"])
        _show(log, values)
        os.remove(path)
        if rc != 0:
            raise ToolError("apply failed (rc=%s)" % rc, EXIT_APPLY)
        print("apply %s: ok" % a.snapend)
        if a.no_verify:
            return EXIT_OK
        after = download_live(a.snapend, wd, runner, values)
        after_c, after_found = canonical(after)
        ok = dumps(after_c) == text
        print("verify redacted live == committed: %s" % ok)
        for tier, isset in sorted(_private_key_set(after).items()):
            print("verify %s private_key_set: %s" % (tier, isset))
        for n, status in _secret_report(names, values, {}, after_found):
            print("verify secret %s: %s" % (n, status))
            ok = ok and status == "match"
        if not ok:
            d2 = plan_diff(text, dumps(after_c), "committed:" + a.file, "live:" + a.snapend)
            sys.stdout.write(d2)
            return EXIT_VERIFY
    return EXIT_OK


def _git(args, cwd=None):
    r = subprocess.run(["git"] + args, cwd=cwd, capture_output=True)
    if r.returncode != 0:
        raise ToolError("git %s failed" % args[0])
    return r.stdout


def _iter_paths(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs[:] = sorted(d for d in dirs if d != ".git")
                for f in sorted(files):
                    if f.endswith(".json") or f.endswith(".p8"):
                        yield os.path.join(root, f)
        else:
            yield p


def cmd_scan(a, **_):
    hits = []
    if a.staged:
        names = _git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"]).split(b"\0")
        for raw in names:
            if not raw:
                continue
            name = raw.decode("utf-8", "replace")
            data = _git(["show", ":" + name])
            hits.extend(scan_blob(name, name, data))
    for path in _iter_paths(a.paths):
        if not os.path.isfile(path):
            raise ToolError("scan: no such file %s" % path)
        with open(path, "rb") as f:
            hits.extend(scan_blob(path, path, f.read()))
    for display, jpath, reason in hits:
        print("SECRET %s%s: %s" % (display, "" if jpath == "-" else " " + jpath, reason))
    if hits:
        print("scan: %d hit(s). Redact with snapend_manifest.sh fmt, never commit them." % len(hits))
        return EXIT_DRIFT
    print("scan: clean")
    return EXIT_OK


def _all_names(files):
    out = []
    for path in files:
        obj, _ = canonical(_load_manifest(path))
        for n in placeholder_names(obj):
            if n not in out:
                out.append(n)
    return out


def cmd_secrets(a, **_):
    if a.action == "init":
        ids, envs = [], []
        for path in a.files:
            m = _load_manifest(path)
            if m.get("id") not in ids:
                ids.append(m.get("id"))
            if m.get("environment") not in envs:
                envs.append(m.get("environment"))
        secrets = {}
        for n in _all_names(a.files):
            parts = n.split("/")
            if len(parts) == 3 and parts[0] == "apple" and parts[2] == "private_key":
                p8 = "~/private_keys/%s%s.p8" % (P8_PREFIX, parts[1])
                exists = os.path.exists(os.path.expanduser(p8))
                secrets[n] = {"file": p8, "strip": True, "expect": "pem"}
                print("secrets init: %s -> %s (%s)" % (n, p8, "exists" if exists else "MISSING"),
                      file=sys.stderr)
            else:
                secrets[n] = {"keychain": {"service": "snapser-secrets", "account": n}}
                print("secrets init: %s -> keychain (add it with: security add-generic-password "
                      "-s snapser-secrets -a %s -w)" % (n, n), file=sys.stderr)
        doc = {"version": 1, "allowed_snapends": ids,
               "allowed_environments": [e for e in envs if e == "DEVELOPMENT"] or ["DEVELOPMENT"],
               "secrets": secrets}
        text = dumps(doc)
        if not a.write:
            sys.stdout.write(text)
            return EXIT_OK
        path = sources_path(a.sources)
        if os.path.exists(path) and not a.force:
            raise ToolError("%s exists; pass --force to replace it" % path)
        d = os.path.dirname(path)
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
        write_text(path, text, 0o600)
        os.chmod(path, 0o600)
        print("secrets init: wrote %s (%d secret reference(s))" % (path, len(secrets)))
        return EXIT_OK
    # check: references only; files are tested for existence and never opened.
    sources = load_sources(sources_path(a.sources))
    rc = EXIT_OK
    for path in a.files:
        m = _load_manifest(path)
        if m.get("id") not in (sources.get("allowed_snapends") or []):
            print("secrets check: %s snapend %s is not in allowed_snapends" % (path, m.get("id")))
            rc = EXIT_DRIFT
    for n in _all_names(a.files):
        entry = sources["secrets"].get(n)
        if not isinstance(entry, dict):
            status = "MISSING (no source)"
        elif "file" in entry:
            status = "OK (file exists)" if os.path.exists(os.path.expanduser(str(entry["file"]))) \
                else "MISSING (file not found)"
        elif isinstance(entry.get("keychain"), dict):
            status = "OK (keychain reference; not read)"
        else:
            status = "MISSING (bad source entry)"
        print("secret %s: %s" % (n, status))
        if not status.startswith("OK"):
            rc = EXIT_DRIFT
    return rc


def build_parser():
    p = argparse.ArgumentParser(prog="snapend_manifest.sh", description=__doc__.split("\n")[0])
    p.add_argument("--sources", help="secret sources file (default %s or $%s)" % (DEFAULT_SOURCES, SOURCES_ENV))
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    s = sub.add_parser("pull", help="download live, redact, write FILE")
    s.add_argument("--snapend", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--into", help="start from this committed file instead of the whole live manifest")
    s.add_argument("--only", action="append", default=[], metavar="SETTING_ID",
                   help="with --into: settings entries to take from live")

    s = sub.add_parser("fmt", help="rewrite files in committed form (redacts any secret)")
    s.add_argument("files", nargs="+")
    s.add_argument("--check", action="store_true")

    s = sub.add_parser("diff", help="redacted diff of FILE against live")
    s.add_argument("--snapend", required=True)
    s.add_argument("file")
    s.add_argument("--check-secrets", action="store_true")

    s = sub.add_parser("apply", help="inject secrets and apply FILE to its snapend")
    s.add_argument("--snapend", required=True)
    s.add_argument("file")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--yes", action="store_true")
    s.add_argument("--allow-noop", action="store_true")
    s.add_argument("--no-verify", action="store_true")

    s = sub.add_parser("scan", help="find unredacted secrets in files or the git index")
    s.add_argument("paths", nargs="*")
    s.add_argument("--staged", action="store_true")

    s = sub.add_parser("secrets", help="check or initialise the secret sources file")
    s.add_argument("action", choices=("check", "init"))
    s.add_argument("files", nargs="+")
    s.add_argument("--write", action="store_true", help="init: write the sources file (0600)")
    s.add_argument("--force", action="store_true", help="init --write: replace an existing file")
    return p


COMMANDS = {"pull": cmd_pull, "fmt": cmd_fmt, "diff": cmd_diff, "apply": cmd_apply,
            "scan": cmd_scan, "secrets": cmd_secrets}


def main(argv=None, runner=None, security_runner=None):
    parser = build_parser()
    try:
        a = parser.parse_args(argv)
    except SystemExit as e:
        return EXIT_USAGE if e.code else EXIT_OK
    if a.cmd == "pull" and a.only and not a.into:
        print("pull: --only needs --into", file=sys.stderr)
        return EXIT_USAGE
    if a.cmd == "scan" and not a.paths and not a.staged:
        print("scan: give PATHS or --staged", file=sys.stderr)
        return EXIT_USAGE
    try:
        return COMMANDS[a.cmd](a, runner=runner or default_snapctl_runner,
                               security_runner=security_runner or default_security_runner)
    except ToolError as e:
        print("snapend_manifest: %s" % e, file=sys.stderr)
        return e.code
    except KeyboardInterrupt:
        print("snapend_manifest: interrupted; temp files removed", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())

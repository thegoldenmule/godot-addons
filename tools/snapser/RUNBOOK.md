# Snapser runbook (snapser_kit games)

Operational steps for a game that uses `addons/snapser_kit`. This repo is
**public**. Never commit snapend IDs, application IDs, gateway URLs, API keys or
`.p8` files here. Those belong in each game's repo.

## Files

| File | Where | What |
|---|---|---|
| `snapend-manifest.template.json` | here | Standard DEVELOPMENT snapend at the snap versions deployed 2026-10-08: auth v1.14.1, statistics v1.13.0, leaderboards v1.12.0, storage v1.14.0, profiles v1.13.0, analytics v1.12.0, remote-config v1.13.0. Anonymous login is **enabled** in dev, stage and prod; apple/google are present but `null`. Also includes: storage `save_v1` (private, external JSON blob), profiles `display_name`, the six standard analytics events, and an empty remote-config `v1`. **Statistics and leaderboards are empty on purpose: each game must declare its own.** Placeholders: `__SNAPEND_ID__`, `__SNAPEND_NAME__`. |
| `snapend-manifest.quests.fragment.json` | here | Optional quests service definition + empty settings, for games that use quests. |
| `smoke/run_smoke.sh`, `smoke/smoke.gd` | here | Live smoke test against one game's snapend. |
| `check_declarations.sh` | here | Offline check that the config's `"declared"` section, boards and cloud-save blob match `snapser/snapend-manifest.json`. |
| `clear_board_rows.sh` | here | Admin. Lists named users' rows on a dev snapend board (`--dry-run`). Uses the platform key only to confirm the snapend is DEVELOPMENT. **It can't delete:** Snapser has no row-delete API, so it prints the console steps. |
| `snapend_manifest.sh` | here | Redacted manifests. `pull`, `fmt`, `diff`, `apply`, `scan` and `secrets`: commit placeholders, inject secrets only at apply time. See "Secrets in snapend manifests" below. |
| `snapser/snapend-manifest.json` | game repo | That game's snapend as code, committed **redacted** (placeholders for secrets; see "Secrets in snapend manifests"). |
| `game/snapser_kit.config.json` | game repo | Committed client config: `game_id`, `gateway_url`, boards, cloud-save keys, link providers, optional `"quests": true`. |

## Provision a game's dev snapend

1. Copy the template into the game repo as `snapser/snapend-manifest.json`.
2. Add the game's content. **Snapser rejects anything undeclared with a 404:**
   - a stat key gets `4000 "Statistic key not found"`;
   - an analytics event gets `2000 "Event not found"`;
   - a storage key is rejected the same way;
   - a leaderboard name fails too.

   So declare everything the game sends:
   - `statistics.statistics[]`: one entry per key (`^[a-z0-9_]+$`). `scope: external` lets the client write it:
     ```json
     {"key": "matches_played", "type": "counter", "scope": "external", "allow_negative": false, "default_value": ""}
     ```
   - `leaderboards.leaderboards[]`. This is a non-recurring all-time board; for a daily board, use `"duration": "1", "time_unit": "days"`:
     ```json
     {"name": "career_wins", "description": "Lifetime wins (submit the career total)", "type": "global",
      "scope": "external", "sort": "descending", "behavior": "maximum", "tiers": [],
      "duration": "0", "time_unit": "", "start_time": "<unix s, e.g. today 00:00Z>"}
     ```
     A `maximum` board keeps the best submission, so submit the running total, not `+1`. That also makes a retried submit harmless.
   - `analytics.events[]`: add any game-specific events (see below).
   - `storage.keys[]`: keep `save_v1` (or match `cloud_save.blob_key`).
   - Quests (optional): splice in the fragment's `service_definition` and `settings`, and set `"quests": true` in the client config.
3. Apply. **Check the D8 guardrail first:** once a game has shipped an online build, every apply needs approval.
   - **Session impact (observed 2026-10-08):** settings-only applies, including auth settings, did **not** log out a live session.
   - Applies that **add or remove snaps**, and BYOSnap syncs, are untested here. Moveborne saw a BYOSnap sync and apply invalidate every session, so treat them as logging everyone out.
   - Either way, the kit re-logs-in anonymous players silently (401 → re-login → replay).
   - Use the template for `snapctl snapend create` only. Apply to an existing snapend with `snapend_manifest.sh apply`, never with raw `snapctl snapend apply` (see "Secrets in snapend manifests"):
   ```bash
   tools/snapser/snapend_manifest.sh apply --snapend <snapend-id> snapser/snapend-manifest.json --dry-run
   tools/snapser/snapend_manifest.sh apply --snapend <snapend-id> snapser/snapend-manifest.json
   ```
   snapctl reads its key from `~/.snapser/config`. The wrapper unsets the
   platform-key environment variable (env -u), so a stale shell export can't
   override it. Never paste the key anywhere.
4. The committed manifest is the redacted form. If the server normalised
   something on apply, `snapend_manifest.sh diff --snapend <snapend-id> snapser/snapend-manifest.json`
   shows it; take it with `pull` (below). A later apply should be a no-op.
5. Write `game/snapser_kit.config.json` with the gateway URL (`https://gateway.snapser.com/<snapend-id>`) and the boards.
6. Run the smoke test (below). For Web exports, also check CORS from the hosting origin.

## Secrets in snapend manifests

A downloaded snapend manifest carries connector secrets in clear text: the Apple
Sign in `.p8` key under `settings[auth].data.<tier>.apple.private_key`, and again
inside the `applied_configuration` string. **A game repo never commits them.**
`snapser/snapend-manifest.json` is committed in redacted form:

- `applied_configuration` is dropped. It is an opaque copy of the whole manifest,
  secrets included; `apply` takes it from live.
- Volatile keys are dropped everywhere: `exported_at`, `created_at`, `updated_at`,
  `created_by`, `revision`, `last_run_at`.
- Each secret string becomes a whole-value placeholder `"@@secret:<name>@@"`:
  - `apple/<key-id>/private_key`
  - `<connector>/<client-id>/client_secret` (google, facebook, epic, xbox, discord, x, app_verify)
  - `steam/<app-id>/<field>`
  - `<snapend-id>/<dotted json path>` for anything else that looks secret (a
    catch-all on names like `private_key`, `client_secret`, `secret`, `token`,
    `webhook_secret`, `signing_key`, and on any PEM block).

  `key_id`, `key`, `session_token_validity` and `is_prefix_key` are never redacted.

The secrets themselves stay outside every repo. `~/.config/snapser-secrets/sources.json`
(directory `0700`, file `0600`; the tool refuses looser modes) holds **references
only**:

```json
{"version": 1,
 "allowed_snapends": ["<snapend-id>"],
 "allowed_environments": ["DEVELOPMENT"],
 "secrets": {
   "apple/<key-id>/private_key": {"file": "~/private_keys/<the .p8 file>", "strip": true, "expect": "pem"},
   "<name>": {"keychain": {"service": "snapser-secrets", "account": "<name>"}}}}
```

Every command runs through `tools/snapser/snapend_manifest.sh`, which unsets the
platform-key variable. Nothing prints a secret: output is limited to placeholder
names, JSON paths, booleans and sha256 match results, and snapctl's own output is
scrubbed. Exit codes: `0` ok, `1` drift or scan hit, `2` usage or config, `3`
refused, `4` apply failed, `5` verify mismatch.

| Task | Command |
|---|---|
| Take the whole live manifest | `snapend_manifest.sh pull --snapend <snapend-id> --out snapser/snapend-manifest.json` |
| Take only some settings from live, keeping local edits elsewhere | `snapend_manifest.sh pull --snapend <snapend-id> --into snapser/snapend-manifest.json --only auth --out snapser/snapend-manifest.json` |
| Canonicalise (redacts anything secret) | `snapend_manifest.sh fmt snapser/snapend-manifest.json` (`--check` to only report) |
| Compare with live | `snapend_manifest.sh diff --snapend <snapend-id> snapser/snapend-manifest.json --check-secrets` |
| Apply | `snapend_manifest.sh apply --snapend <snapend-id> snapser/snapend-manifest.json [--dry-run] [--yes] [--allow-noop]` |
| Look for leaks | `snapend_manifest.sh scan <paths>` or `scan --staged` (the game repos' pre-commit hook) |
| Write the sources skeleton | `snapend_manifest.sh secrets init <manifests...> --write` |
| Check every placeholder has a source | `snapend_manifest.sh secrets check <manifests...>` |

`secrets init` maps each `apple/<key-id>/private_key` to
`~/private_keys/<AuthKey file for key-id>.p8` and every other name to a keychain
item; add a keychain item with `security add-generic-password -s snapser-secrets -a <name> -w`.
`secrets init` and `secrets check` only test that a `.p8` exists; they never open it.

`apply`:
1. refuses an unresolved placeholder, a missing source file, a value that fails
   its `expect: pem` check, a snapend that is not allow-listed, a file whose `id`
   differs from `--snapend`, or a non-allowed environment;
2. downloads live, prints the redacted plan diff and per-secret
   unchanged/changed/new, and stops there when nothing changed (unless
   `--allow-noop`) or on `--dry-run`;
3. needs `--yes`, or the snapend id typed at a terminal;
4. builds the upload in a private temp dir (`0700`, file `0600`, deleted even on
   Ctrl-C or SIGTERM): committed content with the secrets injected, live's
   volatile fields, and live's `applied_configuration` verbatim (the server
   rejects a mismatch);
5. runs `snapctl snapend apply --blocking`, re-downloads, and checks that the
   redacted live equals the committed file, `private_key_set` per tier, and that
   every secret's hash matches. A mismatch exits `5`.

**Never raw-apply** a committed manifest: its placeholders would replace the
real keys on the snapend.

## Declarations

After editing the manifest, mirror the names in the client config's `"declared"` section and check:

```bash
tools/snapser/check_declarations.sh ../Sovereign-Battleships
```

In debug builds the kit refuses undeclared names locally (`error: "undeclared"`). The server's own 404s (stat 4000, event 2000) map to the same code.

## Analytics events

Snapser analytics properties are typed `string`, `number` or `timestamp`; there is **no boolean**. On the wire, **every property value is a string**, and the body must carry `user_id`. `SnapKitAnalytics` handles both:
- it stringifies numbers (integral floats lose the `.0`);
- it sends bools as `"1"`/`"0"`. `"true"` is rejected with `400 2003 "invalid property value"`. Every event a game sends must be declared in `analytics.events[]` with `"type": "user"` (at most 12 properties). The template declares:

| Event | Props | Sent by |
|---|---|---|
| `session_start` | `build_mode`, `version`, `platform` (string) | kit (start, resume) |
| `session_end` | `duration_s` (number) | kit (pause / close, best effort) |
| `online_state` | `online` (number 0/1), `reason` (string) | kit |
| `run_start` | `mode` | game |
| `run_end` | `mode`, `result`, `score`, `duration_s` | game |
| `screen_view` | `screen` | game |

## Live smoke test

```bash
tools/snapser/smoke/run_smoke.sh ../Sovereign-Battleships            # finds game/snapser_kit.config.json
tools/snapser/smoke/run_smoke.sh path/to/snapser_kit.config.json --stat=hits --board=career_wins --verbose
```

- **Smoke identity:** pass `--session-file=<abs path>` to reuse the same smoke user, especially under an isolated `HOME`, where `user://` moves and the default file would mint a new user and new board rows. At the end the run prints the user id and every board it wrote.
- It uses this repo's kit build, and the gateway **only** from the given config. It refuses if `SNAPSER_GATEWAY_URL` points elsewhere, and refuses non-https or placeholder URLs.
- It keeps one persisted smoke user per game (`user://snapkit_smoke_<game_id>.json` in this project's user dir).
- It checks:
  - anonymous login, refresh, and re-login to the same user
  - remote config, and quests if `"quests": true`
  - stat increment and set (`--stat` must be a **declared** key)
  - display name set and fetch (a random `Smoke Tester xxxx`)
  - leaderboard submit, top, and around-me with **names**
  - cloud save: push, then a simulated second-device write, then push again. This must detect the CAS conflict, merge, and keep the other device's key. Then a pull.
  - analytics flush
- The smoke user is real data on the snapend: its board rows and profile name stay there. Use dev snapends only, and clear test rows in the console before players see a board.
- `SKIP` means the step's client isn't implemented in this kit build, or the config lacks a board.
- Exit codes: `0` means no failures, `1` means a step failed, `2` means it refused or timed out.

## Session facts worth knowing

- **Session lifetime.** Tokens last 30 days (`session_token_validity`). Sessions die after 7 days idle (`session_inactivity_timeout`). Applies and BYOSnap syncs invalidate everything. The kit:
  - refreshes on a warm launch (`PATCH /v1/auth/refresh`);
  - refreshes on local expiry, then falls back to anonymous re-login;
  - re-logs-in on any 401.
- Keep `single_session_per_user` **false**. Otherwise a linked account used on two devices logs the other one out.
- **Linking** (Wave 4): `login/{provider}` with `create_user=true`.
  - If the provider user is new, the kit associates it onto the anonymous user (keep = anon, discard = provider).
  - If the provider account already exists, the kit returns `account_exists`, and the game may `switch_account()`. **The account wins (D36):** its cloud save replaces the device's synced data for every key, except bools, which OR. Guest-only non-bool progress is dropped. "Never discard local progress" holds only for the first sync and for linking a *new* provider account.
  - Cloud-save state (CAS, version, `has_synced`) is per user and resets on any user change, so it's never reused across accounts.
  - Apple sends the authorization code: single-use, never retried.
- **Linking rollout (D35):**
  1. Ship with `"link_providers": []`, which keeps linking off (`link_account` returns `disabled`).
  2. Add the Sign in with Apple capability to the App ID.
  3. Only then add the SIWA entitlement. An entitlement without the capability breaks cloud signing.
  4. Configure the snapend's Apple connector. This apply needs approval post-ship.
  5. Set `link_providers: ["apple"]`.

## Clearing test rows from a board

Leaderboard rows can't be deleted through any API. The leaderboards snap only has Get, Set and Increment. The snapend gateway rejects the platform key ("API key not found", 16). snapctl has no row or user commands.

`clear_board_rows.sh --dry-run` finds the rows:

```bash
tools/snapser/clear_board_rows.sh --snapend <id> --board career_wins --user <uid> [--user …] --dry-run
tools/snapser/clear_board_rows.sh --snapend <id> --board career_wins --all-rows --dry-run   # pre-ship test boards
```

- It reads the key from `~/.snapser/config` (the wrapper unsets the env var) and uses it only to confirm the snapend is DEVELOPMENT. The key is never printed.
- It reads the board as `--session-file` (e.g. the smoke identity) or as a fixed anonymous "admin reader" user that never writes.
- Then delete the rows by hand in the console, using either:
  - the **Leaderboards** tool, or
  - **User Manager → Bulk User Data → Reset**, with the printed user ids. This works on dev snapends only, and resets all of those users' snap data except Auth.

## Test, tool and headless runs stay offline (fail closed)

The kit resolves offline, unless `SNAPSER_TESTS_ONLINE=1` is set, when any of these holds:
- the run is a `--script` / `-s` run;
- a scene or script on the command line, or the main scene, is under the config's `offline_paths` (default `res://tests`, `res://tools`). Paths in `res://`, relative, absolute and `uid://` form all count;
- the process is headless.

This closes the 0.2.0 hole. A test launched with an absolute `--script` path resolved online, logged in to the game's snapend and hung on network calls. A committed gateway therefore never puts headless suites online (DoD 7), and offline or test runs write nothing under `user://`.

`run_smoke.sh` always runs `--import` first, so a stale class cache can't break the script. It also kills a hung run: `SMOKE_IMPORT_TIMEOUT_S` defaults to 240 and `SMOKE_TIMEOUT_S` to 300, and a timeout exits 124.

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
| `snapser/snapend-manifest.json` | game repo | That game's snapend as code (from the template). |
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
   - Use the template for `snapctl snapend create` only. `apply` diffs against `applied_configuration`, so apply to an existing snapend with a freshly downloaded manifest (step 4) plus your edits.
   ```bash
   snapctl snapend apply \
     --manifest-path-filename snapser/snapend-manifest.json --blocking
   ```
   snapctl reads its key from `~/.snapser/config` unless the platform-key
   environment variable is set. If your shell exports a stale one, prefix the
   command with `env -u <that variable>`. Never paste the key anywhere.
4. Round-trip the manifest so the repo matches what the server normalised:
   ```bash
   snapctl snapend download --snapend-id <id> --category snapend-manifest
   ```
   Commit the downloaded manifest in the game repo. A later apply should be a no-op.
5. Write `game/snapser_kit.config.json` with the gateway URL (`https://gateway.snapser.com/<snapend-id>`) and the boards.
6. Run the smoke test (below). For Web exports, also check CORS from the hosting origin.

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
  - If the provider account already exists, the kit returns `account_exists`, and the game may `switch_account()`.
  - Apple sends the authorization code: single-use, never retried.

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

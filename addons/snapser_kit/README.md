# Snapser Kit

A game-agnostic [Snapser](https://snapser.com) client for Godot 4.x. It provides:
- config resolution
- anonymous auth with account linking
- a hardened HTTP transport
- typed snap clients
- local-first cloud save
- one base class, `SnapKitService`, that a game's `Snapser` autoload extends

Web-safe: it uses no threads.

**The client never uses an API key.** The gateway authenticates each player with a session (`Token` / `User-Id` headers) from anonymous or provider login. Platform keys belong to `snapctl` and server tooling only.

## Install

1. Copy `addons/snapser_kit/` (and `addons/editor_tool_kit/`, for self-update) into the game's `addons/`. Enable the plugin.
2. Commit `res://snapser_kit.config.json`. It contains no secrets:
   ```json
   {
     "game_id": "mygame",
     "gateway_url": "https://gateway.snapser.com/<snapend-id>",
     "anon_handle_prefix": "mygame-",
     "leaderboards": { "career_wins": "career_wins" },
     "cloud_save": { "blob_key": "save_v1", "sync_prefixes": ["sax_prog_"], "sync_keys": ["sax_militia_unlocked"] },
     "link_providers": ["apple"],
     "quests": false,
     "declared": {
       "stats": ["hits"], "boards": ["career_wins"],
       "events": ["session_start", "session_end", "online_state", "run_start", "run_end", "screen_view"],
       "blobs": ["save_v1"]
     }
   }
   ```
3. Add the autoload `Snapser` → `res://scripts/snapser.gd`:
   ```gdscript
   extends SnapKitService
   func _ready() -> void:
       start()
   ```

## Connection resolution

The first matching rule wins:
1. `SNAPSER_OFFLINE=1` or `--snapser-offline` forces offline. Tests and capture runs use this.
   - **Test and tool runs are offline automatically.** A run counts as one when a scene or script on the command line, or the main scene, is under `res://tests/` or `res://tools/`. Set `SNAPSER_TESTS_ONLINE=1` to opt a live end-to-end test back in.
   - At runtime, `Snapser.force_offline(reason)` switches the kit offline, for example from a settings toggle. On a bare config, use `SnapKitConfig.force_offline(reason)`.
   - **Offline and test runs write nothing under `user://`:** no session file, no cloud-save state file. That bookkeeping stays in memory until the kit is online.
2. The `SNAPSER_GATEWAY_URL` environment variable.
3. `user://snapser_kit.override.json` (`{"gateway_url": …}` or `{"offline": true}`), read in **debug builds only**.
4. The committed `gateway_url`.
5. If none of these resolves, the game runs offline.

## The API (`SnapKitService`)

Every network call:
- is a coroutine (`await`);
- returns at least `{ok, error}`;
- **never throws**.

When offline, every call returns `{ok:false, error:"offline"}` immediately, so gameplay code never branches on connectivity.

| Area | Calls |
|---|---|
| Status | `is_online()`, `user_id()`, `await wait_until_ready()` (returns online state after boot), `force_offline(reason)`. `is_online()` is **false until boot has logged in**, so screens that check it in `_ready()` should `await Snapser.wait_until_ready()` first. |
| Signals | `online_changed`, `session_ready`, `config_updated`, `cloud_save_conflict`, `cloud_save_applied(keys)`, `boot_finished` |
| Stats | `record_stat(key, value)`, `increment_stat(key, delta)` (keys `^[a-z0-9_]+$`) |
| Leaderboards | `submit_score(board, score)`, `top_scores(board, n)`, `scores_around_me(board, n)` (boards map through `config.leaderboards`) |
| Remote config | `remote_config()` (cached), `refresh_remote_config()` |
| Cloud save | `cloud_save_push()`, `cloud_save_pull()`. Override `_merge(local, remote)`. The default merges bools with OR, numbers with max and arrays with union; anything else takes the newer value. Set `save_store` (duck-typed `export_prefix` / `import_prefix` / optional `changed` signal) or rely on `/root/SaveService`. After a pull or merge, `cloud_save_applied(keys)` lists what changed locally; refresh caches from it. Synced keys are those under `sync_prefixes` plus the exact names in `sync_keys`. A pull adds and overwrites exact keys but never deletes them, and never touches siblings that merely start with the same text. |
| Analytics | `track(event, props)`: queued and batched; never blocks. The kit sends `session_start`, `session_end` and `online_state` itself. |
| Profile | `display_name()` (never empty), `set_display_name(name)`: trims, length-limits (3–16) and filters. Names are **not unique** (D33). |
| Identity | `register_identity_provider(name, bridge)`, `link_account(provider)`, `switch_account(result)`, `linked_providers()` |
| Quests | `quests_fetch_active/assign/increment/claim` (requires `"quests": true`) |

Lower layers are public for advanced use:
- `config` (`SnapKitConfig`)
- `auth` (`SnapKitAuth`)
- `transport` (`SnapKitTransport`)
- `*_client` (`SnapKitStats`, `SnapKitLeaderboards`, `SnapKitStorage`, `SnapKitRemoteConfig`, `SnapKitQuests`, `SnapKitProfiles`, `SnapKitAnalytics`)
- `cloud_save` (`SnapKitCloudSave`)

### Transport contract

`await transport.request(method, path, body = null, opts = {})` always returns `{ok, status, json, error}`.

- **Paths** are gateway-relative and may contain `{user_id}`, which is filled in after the session is ensured.
- **opts:**
  - `auth` (default true)
  - `timeout_s` (default 10)
  - `retries`: default 2 for GET/PUT/DELETE, 0 for POST/PATCH. Retries happen only on timeout, network errors, 429 and 5xx, with jittered backoff.
  - `headers`
  - `no_retry`: disables both the retries and the 401 replay.
- **On a 401** the transport re-logs in once (same anonymous user) and replays once.
- **Errors:** every result carries `error` (a kit code) and `snap_code` (Snapser's `api_error_code`, 0 when absent).
  - Transport codes: `offline`, `no_session`, `timeout`, `network`.
  - Named Snapser codes (`SnapKitErrors`): `undeclared` (also stat 4000 / event 2000), `quest_not_claimable` (15014), `cas_conflict` (5007), `already_exists`, `not_found`, `invalid_property_value`, `anon_login_disabled`.
  - Otherwise `http_<status>`.
  - Client-level codes: `bad_response`, `invalid_argument`, `disabled`, `not_implemented`.

### Declarations

Snapser rejects undeclared stat keys, events, boards and storage keys with a 404. List them under `"declared"` in the config. A kind you leave out isn't checked.

- **Debug builds:** `record_stat`, `increment_stat`, `submit_score`, `cloud_save_*` and `track` on an undeclared name log one warning and return `{ok:false, error:"undeclared"}` (events are dropped). There's no network call, even when offline, so offline tests catch typos.
- **Release builds:** the kit warns once and sends anyway.

Keep the section in step with the snapend: `tools/snapser/check_declarations.sh <game repo>`, or `SnapKitConfig.from_dict(cfg).declaration_problems(manifest)` in a headless test.

## Editor

Project → Tools has two items:
- **Snapser Kit: Show resolved config**
- **Snapser Kit: Test connection** (anonymous login, using its own probe session)

## Tests

```bash
SNAPSER_OFFLINE=1 godot --headless --path . --script res://tests/snapser_kit/run_tests.gd [-- --filter=<substr>]
```

- Tests live in `tests/snapser_kit/` in the godot-addons repo.
- They use `SnapKitMockGateway`, an in-process fake gateway with anonymous login and refresh, 401 simulation and failure injection. They never touch the network.
- **Files go in a sandbox:** every file the kit writes (session, cloud-save state, editor probe) lives under `SnapKitConfig.data_root`, which defaults to `user://`.
  - The test runner, and any `SnapKitMockGateway` you construct, move it to a scratch directory, so tests never touch a player's real files.
  - The runner fails the suite if anything under `user://` changes.
  - A game's own suites can do the same by calling `SnapKitMockGateway.use_scratch_data_root()` before starting the service.
- Live smoke tests and provisioning are covered in `tools/snapser/RUNBOOK.md`.

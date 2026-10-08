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
     "cloud_save": { "blob_key": "save_v1", "sync_prefixes": ["sax_prog_"] },
     "link_providers": ["apple"],
     "quests": false
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
| Status | `is_online()`, `user_id()` |
| Signals | `online_changed`, `session_ready`, `config_updated`, `cloud_save_conflict`, `boot_finished` |
| Stats | `record_stat(key, value)`, `increment_stat(key, delta)` (keys `^[a-z0-9_]+$`) |
| Leaderboards | `submit_score(board, score)`, `top_scores(board, n)`, `scores_around_me(board, n)` (boards map through `config.leaderboards`) |
| Remote config | `remote_config()` (cached), `refresh_remote_config()` |
| Cloud save | `cloud_save_push()`, `cloud_save_pull()`, override `_merge(local, remote)`; set `save_store` (duck-typed `export_prefix` / `import_prefix` / optional `changed` signal) or rely on `/root/SaveService` |
| Analytics | `track(event, props)`: queued and batched; never blocks. The kit sends `session_start`, `session_end` and `online_state` itself. |
| Profile | `display_name()` (never empty), `set_display_name(name)` |
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
- **Errors:** `offline`, `no_session`, `timeout`, `network`, `http_<status>`, plus client-level `bad_response`, `invalid_argument`, `disabled` and `not_implemented`.

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
- Live smoke tests and provisioning are covered in `tools/snapser/RUNBOOK.md`.

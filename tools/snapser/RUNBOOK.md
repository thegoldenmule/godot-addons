# Snapser runbook (snapser_kit games)

Operational steps for a game that uses `addons/snapser_kit`. This repo is
**public**. Never commit snapend IDs, application IDs, gateway URLs, API keys or
`.p8` files here. Those belong in each game's repo.

## Files

| File | Where | What |
|---|---|---|
| `snapend-manifest.template.json` | here | Standard DEVELOPMENT snapend: auth (anonymous **enabled**; apple/google present but `null`), statistics, leaderboards, storage (`save_v1` private JSON blob), profiles (`display_name`), analytics (the six standard events), remote-config (empty `v1`). Placeholders: `__SNAPEND_ID__`, `__SNAPEND_NAME__`. |
| `snapend-manifest.quests.fragment.json` | here | Optional quests service definition + empty settings, for games that use quests. |
| `smoke/run_smoke.sh`, `smoke/smoke.gd` | here | Live smoke test against one game's snapend. |
| `snapser/snapend-manifest.json` | game repo | That game's snapend as code (from the template). |
| `game/snapser_kit.config.json` | game repo | Committed client config: `game_id`, `gateway_url`, boards, cloud-save keys, link providers, optional `"quests": true`. |

## Provision a game's dev snapend

1. Copy the template into the game repo as `snapser/snapend-manifest.json`.
2. Add the game's content:
   - `leaderboards.leaderboards[]`. Example all-time "max" board (shape from a working snapend; adjust `time_unit`/`duration` for daily/weekly):
     ```json
     {"name": "career_wins", "description": "Career wins", "type": "global", "scope": "external",
      "sort": "descending", "behavior": "maximum", "tiers": [], "duration": "1", "time_unit": "days",
      "start_time": "<unix s>"}
     ```
   - `statistics.statistics[]`: declare the game's stat keys (`^[a-z0-9_]+$`) if the snap requires declarations. The smoke test writes `smoke_runs` and `smoke_last_unix`. Declare them too if undeclared keys are rejected.
   - `storage.keys[]`: keep `save_v1` (or match `cloud_save.blob_key`).
   - Quests (optional): splice in the fragment's `service_definition` and `settings`, and set `"quests": true` in the client config.
3. Apply. **Check the D8 guardrail first.** Once a game has shipped an online build, every apply needs approval. An apply **logs out every player**; the kit re-logs-in anonymous players silently (401 → re-login → replay).
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

## Analytics events

Snapser analytics properties are typed `string`, `number` or `timestamp`; there is **no boolean**. Send flags as `0`/`1` (the kit's own `online_state.online` does). Every event a game sends must be declared in `analytics.events[]` with `"type": "user"` (at most 12 properties). The template declares:

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
tools/snapser/smoke/run_smoke.sh path/to/snapser_kit.config.json --board=career_wins --verbose
```

- It uses this repo's kit build, and the gateway **only** from the given config. It refuses if `SNAPSER_GATEWAY_URL` points elsewhere, and refuses non-https or placeholder URLs.
- It keeps one persisted smoke user per game (`user://snapkit_smoke_<game_id>.json` in this project's user dir).
- It checks:
  - anonymous login, refresh, and re-login to the same user
  - remote config
  - stats set/increment
  - leaderboard submit/top/around-me
  - profile name set/fetch
  - storage blob put/get
  - analytics flush
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

# Configuration & secrets

**Status:** current

## Kind
subsystem

## Summary
Build Kit splits its state by **whether it is safe to commit**. Shared settings go to `res://build_kit.config.json` (committed); App Store Connect credentials go to the repo `.env` (gitignored); the `.p8` private key itself never enters the repo at all. Both files live outside `addons/build_kit/`, so a self-update cannot clobber them.

## Purpose
The preset name and the build number are things every collaborator wants — they belong in the repo. The API key's id, issuer and path are the opposite: writing them into a tracked file would relocate a leak rather than prevent one. Keeping the split explicit means adopting a key is a one-gesture action that cannot accidentally commit a secret.

## Design notes
Migration from ≤ 0.1.7: those versions wrote asc_key_id / asc_issuer_id / asc_key_path into build_kit.config.json, which is committed. On load, 0.1.8+ moves any it finds into the .env, drops them from the config and saves — idempotent, and a no-op once clean. They are identifiers, not the private key (the .p8 was always kept outside the repo), so this is hygiene rather than an incident; but a config pushed to a public repo should have the pairing treated as disclosed.

The third piece of project state is the iOS export preset in res://export_presets.cfg, which Build Kit reads (bundle id, Team ID, export_project_only, export_path) and repairs, but never owns. Its signing fields stay empty by design — no secret ever lands in export_presets.cfg.

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `asc_credentials() — config (legacy) → environment → .env` in `addons/build_kit/build_kit_service.gd`
- function `upsert_env_text() / ensure_env_gitignored() — the pure write path` in `addons/build_kit/build_kit_service.gd`
- function `adopt_asc_key() — ingest a dropped .p8` in `addons/build_kit/build_kit_service.gd`
- function `migrate_config_secrets_to_env() — the ≤ 0.1.7 cleanup` in `addons/build_kit/build_kit_service.gd`

## Data model
**`res://build_kit.config.json`** — committed. Holds `ios.preset` (which export preset to build) and `ios.build_number` (auto-incremented after each successful upload, kept an `int` so `CFBundleVersion` reads `"2"`, not `"2.0"`).

**The repo `.env`** — gitignored. Candidates in precedence order are `res://.env` then `res://../.env` (covering the common layout where the Godot project is a subdirectory of the repo); the first that exists is also the one written to. It holds `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH`. Values in the **process environment** take precedence over the file.

**`~/private_keys/AuthKey_<KEYID>.p8`** — outside any repo, `chmod 600`. A dropped or browsed key is copied here; the key id is read out of Apple's own filename, and the stored path is written **home-relative** (`~/…`) so it still resolves on another machine.

Writes go through `upsert_env_text()`, which rewrites an existing key's value in place (keeping any `export ` prefix) and appends the rest — comments, blank lines and unrelated keys survive untouched. It is pure, so the headless verifier exercises it without touching disk. After every write, `ensure_env_gitignored()` checks the `.env` is actually ignored and adds the rule if it is missing — touching only an existing `.gitignore`, or creating one beside a `.git` directory, so it never litters a non-repo.

## Usage
_None._

## Invariants & constraints
- build_kit.config.json is committed and therefore holds no secrets — asserted by the headless verifier.
- Writing a credential always checks the target .env is gitignored, adding the rule when it is missing.
- The .p8 is copied to ~/private_keys/ (chmod 600) and referenced by a home-relative path, so it is portable between machines and un-committable.
- Both state files live outside addons/build_kit/, so a self-update overwriting the addon folder cannot touch them.
- An .env upsert preserves comments, blank lines, unrelated keys and any `export ` prefix, and never duplicates a key.

## Synced commit
1503c29

# ASC credentials live in the repo .env, never in the committed config

**Status:** accepted

## Metadata
- **Number:** ADR-21
- **Date:** 2026-08-28
- **Scope:** build_kit
- **Deciders:** Benjamin Jordan

## Context
Build Kit needs two kinds of project state, and they pull in opposite directions. The preset name and the build number are things **every collaborator wants** — a build number that only exists on one machine produces duplicate `CFBundleVersion`s. The API key's id, issuer and path are the opposite: through 0.1.7 they lived in `build_kit.config.json` alongside the shared settings, which is a **committed** file. The `.p8` itself was always kept outside the repo, so this was never a private-key leak — but committing the identifiers pushes half of a credential into git history, and there was nothing stopping the next field from being worse.

## Decision
State is split by whether it is safe to commit. res://build_kit.config.json holds ios.preset and ios.build_number and is committed. ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH go to the repo .env — res://.env, else res://../.env for the common layout where the Godot project is a subdirectory of the repo. Process-environment values take precedence over the file.

The .p8 is copied to ~/private_keys/ and chmod 600'd — outside any repo, so it cannot be committed — and referenced by a home-relative path so it still resolves on another machine.

Every credential write calls ensure_env_gitignored(), which adds the rule when it is missing: writing a secret into a file git tracks would only relocate the leak. It touches an existing .gitignore, or creates one beside a .git directory, and never litters a non-repo.

Writes go through the pure upsert_env_text(), which rewrites a key's value in place (keeping any `export ` prefix) and appends the rest, leaving comments, blank lines and unrelated keys untouched — the .env belongs to the project, not to this addon.

load_config() migrates the ≤ 0.1.7 fields: any asc_* found in the config is moved into the .env, erased from the config, and the config saved. Idempotent, and a no-op once clean.

## Consequences
Adopting a key is a single drag-and-drop that cannot accidentally commit a secret, and the verifier asserts the default config holds none.

Both files live outside addons/build_kit/, so a self-update overwriting the addon folder cannot clobber project state.

Credentials are per-machine: a new collaborator clones the repo, gets the preset and build number, and adopts their own key. There is no shared-key path, by design.

A config committed by ≤ 0.1.7 is cleaned by the next commit after an upgrade, but the identifiers remain in git history — if that repo was public, the pairing should be treated as disclosed.

## Relations
_None._

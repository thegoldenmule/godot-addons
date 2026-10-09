# asc_helper.py — the App Store Connect probe

**Status:** current

## Kind
component

## Summary
`asc_helper.py` — a small, **stdlib-only** command-line probe of the App Store Connect API, spawned detached as `python3 -B` and answering with exactly **one JSON object on stdout**. It is how Build Kit learns things Godot and `xcodebuild` cannot tell it: which team a key belongs to, whether the app record exists, whether the bundle id is registered, and what state the uploaded builds are in.

## Purpose
The App Store Connect API needs an ES256-signed JWT, which GDScript cannot produce and which normally pulls in Python's `cryptography` package — a dependency no Godot addon should impose. Shelling the signature out to `/usr/bin/openssl` (always present on macOS) and converting its DER output to the raw r‖s form keeps the helper dependency-free: it runs on a stock machine with nothing installed but the Xcode command-line tools.

## Design notes
/v1/apps?filter[bundleId] is neither guaranteed-unique nor guaranteed-exact, and its result order is unspecified: duplicate and since-deleted records for the same bundle id do come back. find_apps() re-filters for an exact match, and the builds command breaks any remaining tie by letting the builds decide — the record holding the most recently uploaded build is the live one, and ghost records carrying no builds lose. Taking data[0] blindly would resolve to a ghost whose empty build list is indistinguishable from 'nothing uploaded yet'.

Uploaded dates are compared as parsed datetimes, not strings — the offsets differ between records.

The helper is spawned with python3 -B so no .pyc / **pycache** is written inside the vendored addon folder (0.1.17).

## Components
_No components._

## Dependencies
_No dependencies._

## Code references
- function `make_token() — ES256 JWT via /usr/bin/openssl` in `addons/build_kit/asc_helper.py`
- function `find_apps() — exact-match app-record resolution` in `addons/build_kit/asc_helper.py`
- function `_spawn_asc() / _parse_helper_json() — the GDScript side of the contract` in `addons/build_kit/build_kit_service.gd`

## Data model
Invocation is `asc_helper.py --key-path <p8> --key-id <K> --issuer-id <I> <command> <arg>`, with four commands:

- **`team-info`** — which team does this key belong to? The API has no whoami, so the team is inferred from its assets: a certificate's subject `OU` (authoritative), falling back to a bundle id's `seedId`. An empty `team_id` means the team simply has no assets yet.
- **`check-app`** — `{found, bundle_registered, apps: [{id, name}]}` for a bundle id.
- **`ensure-bundle-id`** — registers the App ID on the developer portal (the same operation as Identifiers → ＋), so the New App dialog's Bundle ID dropdown has something to pick. Idempotent.
- **`builds`** — the five most recent builds as `{version, state, uploaded}`, plus the resolved `app_id`.

Errors are the same contract inverted: `{"ok": false, "error": "…"}` and a non-zero exit. The GDScript side (`_parse_helper_json`) scans the captured log for the first brace-leading line that parses — so stray output can never break the read.

## Usage
_None._

## Invariants & constraints
- Stdlib-only: no pip dependency, ever. The one external binary is /usr/bin/openssl.
- Exactly one JSON object is printed on stdout, success or failure — the single contract the GDScript side parses.
- The helper only reads, except ensure-bundle-id — an ordinary, reversible developer-portal registration made with the user's own key.
- It never receives or stores a secret of its own: the .p8 path, key id and issuer id are passed in as arguments by the service.

## Synced commit
1503c29

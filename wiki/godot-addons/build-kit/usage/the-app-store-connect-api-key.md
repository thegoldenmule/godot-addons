# The App Store Connect API key

**Status:** active

## Body
An App Store Connect API key is optional — Build Kit will use your signed-in Xcode session instead — but it is what makes the tool _proactive_: headless auth, an app-record check before the upload rather than after it, and TestFlight status polling.

## Create it

From the preflight row, press **↗ Create API key**:

1. App Store Connect → Users and Access → **Integrations**.
2. Check the team picker at the top right is the team this project targets.
3. **＋** → any name → role **App Manager** → Generate.
4. **Download** the `.p8`. Apple lets you download it once.

> Role matters. A Developer-role key authenticates fine but **cannot manage signing assets** — cloud signing fails with "Cloud signing permission error", and roles cannot be edited afterwards (you revoke and mint a new key).

## Adopt it

**Drop the downloaded **`.p8`** anywhere on the Build Kit panel** (or press _Browse for .p8…_). Then copy the **Issuer ID** from the top of the API-keys page into the field and press **Save**.

That one gesture:

- reads the key id out of Apple's filename — the download is always `AuthKey_<KEYID>.p8`;
- copies the file to `~/private_keys/` and `chmod 600`s it, outside any repo;
- writes `ASC_KEY_ID` and `ASC_KEY_PATH` (home-relative) to the repo `.env`, and `ASC_ISSUER_ID` when you save the issuer;
- checks that `.env` is gitignored, adding the rule if it is missing.

```sh
# .env — written for you
ASC_KEY_ID=ABC123DEFG
ASC_ISSUER_ID=12345678-abcd-…
ASC_KEY_PATH=~/private_keys/AuthKey_ABC123DEFG.p8
```

`ASC_*` in the process environment also works, and takes precedence over the `.env`.

## What the row tells you

Once all three values are present, the row goes **busy** and validates the key against Apple before trusting it:

- **wrong team** — the key belongs to a different team than your preset targets. Its answers would be truthful _about the wrong team_, so the app-record row is blocked until you replace it. Switch the team picker on the API-keys page, mint a new key, drop it.
- **rejected** — invalid or revoked; mint a new one.
- **team unverified** — the key is valid, but the team owns no certificates or bundle ids yet, so there is nothing to infer the team id from. Harmless; it resolves after your first build.
- **ok** — the app-record probe runs next.

The probes need `python3`, which ships with the Xcode command-line tools (`xcode-select --install`). No pip packages are involved.

## Upgrading from ≤ 0.1.7

Those versions wrote the three `asc_*` fields into `build_kit.config.json`, which is committed. On first load, 0.1.8+ moves them into the `.env` and drops them from the config — your next commit removes them. They are _identifiers_, not the private key (the `.p8` was always kept outside the repo), so this is hygiene rather than an incident; but if that config was pushed to a public repo, treat the pairing as disclosed.

## References
_None._

## Child pages
_None._

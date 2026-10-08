# snapser_kit_apple

Sign in with Apple for [`snapser_kit`](../snapser_kit/README.md) on iOS. It has three parts:

- A small GDExtension (`SnapKitAppleSignIn`, ObjC++ on godot-cpp) around `ASAuthorizationController`.
- An export plugin that wires the extension into iOS builds.
- `SnapKitAppleBridge`, the GDScript identity bridge that `snapser_kit` calls to link an Apple account.

iOS only. On every other platform the bridge returns `{ok:false, error:"unsupported_platform"}` and never loads native code, so you can register it unconditionally.

Requirements: Godot 4.7+, iOS 15.0+ (the Godot 4.7 default), and a physical device. There's no simulator slice (see Limitations). `editor_tool_kit` must be vendored alongside it for self-update.

## Setup

1. **Vendor and enable.** Copy `addons/snapser_kit_apple/` into the game and enable **Snapser Kit Apple** under Project → Project Settings → Plugins. The plugin must be enabled at export time. Without it, iOS builds don't contain the native library and the bridge returns `native_missing`.
2. **Entitlement.** In the iOS export preset, set **Entitlements → Additional** (`entitlements/additional`) to:
   ```xml
   <key>com.apple.developer.applesignin</key><array><string>Default</string></array>
   ```
   If it's missing, the export plugin prints a warning. Without the entitlement, sign-in fails at runtime with `ASAuthorizationError 1000` (`error:"unknown"`).
3. **App ID capability.** In the Apple Developer portal, enable **Sign in with Apple** on the game's App ID *before* the next signed build. Cloud signing only puts the entitlement into the provisioning profile if the capability is on.
4. **Snapser connector.** Configure the Apple connector on the game's snapend: the bundle ID as "Service Id", plus the team ID, key ID and `.p8` key. The key never goes in a repo.
5. **Register the bridge** in the game's `Snapser` autoload (which `extends SnapKitService`):
   ```gdscript
   func _ready() -> void:
       register_identity_provider("apple", SnapKitAppleBridge.new())
       start()
   ```
   Add `"apple"` to `link_providers` in `snapser_kit.config.json`. After that, `Snapser.link_account("apple")` shows the Apple sheet and links the account.

## API

```gdscript
var apple := SnapKitAppleBridge.new()
apple.scopes = PackedStringArray(["email"])      # default; "full_name" also allowed
var r: Dictionary = await apple.get_identity_token()
# success: {ok:true,  token:<authorization code>, error:"", identity_token, user, email}
# failure: {ok:false, token:"", error:<name>[, code, message]}
SnapKitAppleBridge.is_supported()                # iOS with the native library loaded
```

`token` is the Apple **authorization code**, not the identity token. Snapser's Apple connector exchanges the code with Apple itself. The code is single-use and expires after about 5 minutes, so send it straight to `login/apple` and never retry that call. `snapser_kit` does this with `opts.no_retry`. Apple only returns `email` (and the name) on the first authorization for an App ID. Later sign-ins return `""`.

| `error` | Meaning |
|---|---|
| `unsupported_platform` | Not iOS. |
| `native_missing` | iOS, but the native library isn't in the build (the plugin was disabled at export). |
| `busy` | A sign-in is already in progress on this bridge. |
| `start_failed` | The native `sign_in()` call returned an error. |
| `canceled` | The player dismissed the Apple sheet (1001). |
| `unknown` | `ASAuthorizationError 1000`. Almost always a missing entitlement, a missing App ID capability, or no Apple ID signed in on the device. |
| `invalid_response`, `not_handled`, `failed`, `not_interactive` | `ASAuthorizationError` 1002–1005. |
| `unexpected_credential`, `empty_authorization_code` | Apple returned something unusable. |
| `apple_error` | Any other code. See `code` and `message`. |

## How it's wired

```
addons/snapser_kit_apple/
  plugin.cfg, plugin.gd             registers the export plugin
  snapkit_apple_bridge.gd           SnapKitAppleBridge (runtime API)
  snapkit_apple_export_plugin.gd    iOS export wiring
  ios/.gdignore                     hides ios/ from the editor
  ios/snapser_kit_apple.gdextension
  ios/snapser_kit_apple.xcframework release, ios-arm64, static (~0.7 MB)
```

The `.gdextension` only has an iOS library. If the editor could see it, every desktop editor and every Web or desktop build would log `No GDExtension library found for current OS` on startup. So `ios/` carries a `.gdignore`, and the export plugin does for iOS exports what Godot's built-in GDExtension export plugin would do:
- links the `.xcframework` and registers its entry symbol;
- packs the `.gdextension` into the PCK;
- links `AuthenticationServices.framework`.

On iOS, the bridge loads the extension on first use with `GDExtensionManager.load_extension()`.

## Building the native library

The committed `.xcframework` is built from `tools/snapser_kit_apple/` (in this repo, not vendored into games):

```bash
python3 -m venv .venv-scons && .venv-scons/bin/pip install scons
SCONS=.venv-scons/bin/scons tools/snapser_kit_apple/build_ios.sh
```

The script fetches godot-cpp `10.0.0-stable` (pinned by SHA; built with `api_version=4.7`) into a gitignored `.build/`. It compiles a release `ios-arm64` static library for iOS 15.0 and pre-links it with `ld -r` so that only `snapser_kit_apple_init` stays global. That keeps our copy of godot-cpp from colliding with other static GDExtensions. The script then writes `ios/snapser_kit_apple.xcframework`. The output is reproducible byte for byte. Rebuild and commit it whenever `src/` changes, and bump `version` in `plugin.cfg`.

## Verifying an iOS build

After an export, check that the signed app carries the entitlement. Unsigned archives followed by cloud-signed exports can drop it:

```bash
unzip -o Game.ipa -d /tmp/ipa && codesign -d --entitlements - /tmp/ipa/Payload/*.app
# expect: com.apple.developer.applesignin = [Default]
```

## Tests

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
    --script res://tests/snapser_kit_apple/run_tests.gd
```

These cover the non-iOS path, the iOS flow against a fake native object (result mapping, busy handling), the export plugin helpers and the packaging invariants. The real Apple flow needs a device.

## Limitations

- **Device only.** Godot 4.7.1's iOS template ships an x86_64-only simulator slice, and the iOS 26 simulators no longer run x86_64 apps. So this addon has no simulator slice.
- **No credential-state checks or token revocation.** Apple requires in-app account deletion to revoke the Apple token (Guideline 5.1.1(v)). That belongs with account deletion in `snapser_kit`/Snapser, not here.

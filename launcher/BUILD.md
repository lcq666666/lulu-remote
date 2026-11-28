# BUILD.md — how to build LULU Remote v1

## What was verified in this environment (2026-11-26, Linux VM)

- ✅ Repo layout, `git init`, decisions in `../docs/decisions.md`.
- ✅ Pairing protocol grounded in live sources read 2026-11-26:
  `schlarpc/castaway` `docs/gamestream-protocol-notes.md` (§3, Appendix A),
  Sunshine API docs (`POST /api/pin`, `GET /api/pin`), and the
  moonlight-qt CLI source (`pair` / `list` / `stream` / `quit`).
- ✅ Pinned component versions checked on the web 2026-11-26:
  Moonlight Qt v6.2.0 (2026-10-04), Sunshine v2026.914.233613
  (2026-09-14), Tailscale 1.104.7 (2026-11-12, MSI SHA-256 from the
  winget manifest — a secondary source; CI and the installer both
  re-verify it). Tailscale's redistribution position checked the same
  day: open-source client/daemon are BSD-3-Clause, but the official
  Windows GUI client is a separate product, so Tailscale is
  downloaded at install time, never bundled (see `../installer/VERSIONS.md`).
- ❌ **Flutter / Dart are NOT installed here** (`flutter: command not found`).
  `flutter pub get`, `flutter analyze`, `flutter test`,
  `flutter build windows` and `flutter build apk` have **not** been run.
  Nothing in this scaffold is compile-verified yet.
- ❌ **No Inno Setup, no Windows runner here either.** The `.iss`
  files and `.github/workflows/build.yml` have **not** been compiled
  or run. The first CI run is their real test.

## Who needs what: use vs. build

This is the fix for the "too many separate downloads" complaint
(2026-11-26, see `../docs/decisions.md`):

| Who | Needs |
|---|---|
| **User** (uses LULU) | Packages from GitHub Releases: `LULU-Remote-Setup-*.exe` (control PC), `LULU-Host-Setup-*.exe` (each remote PC), `LULU-Remote-*.apk` and `LULU-Pairing-Worker-*.apk` (phone). **No** Flutter, Visual Studio, Android SDK, or Inno Setup. |
| **CI** (builds LULU) | Flutter 3.22+, Inno Setup 6.x, JDK 17 — all installed by `.github/workflows/build.yml` on the runners. |
| **Developer** (changes LULU code locally) | Same as CI, plus a Windows PC for `flutter build windows` and an Android SDK for `flutter build apk`. Local builds are for development only — release installers always come from CI. |

## Release build (GitHub Actions — the only release build)

`.github/workflows/build.yml`, on push to `main` and on `v*` tags:

1. `flutter test` → `flutter analyze` (Linux job, fast fail).
2. Windows job: `flutter build windows --release` and stage the pairing worker →
   `installer\scripts\fetch-components.ps1` (downloads Moonlight +
   Sunshine, writes `installer/vendor/MANIFEST.md`, fetches both
   LICENSE files, verifies the Tailscale MSI hash and deletes it) →
   `iscc` compiles both `.iss` files → installers uploaded as artifacts.
3. Android job builds the launcher and companion APK with matching signing identities. It uses `flutter build apk --release` when the keystore
   secrets exist (`ANDROID_KEYSTORE_BASE64` etc.), otherwise
   `flutter build apk --debug` and the file name says so.
4. On `v*` tags only: the two installers and both APKs are attached to a
   GitHub Release automatically.

## What you need (build machine — local dev only)

### Windows exe

- Windows 10/11 64-bit, Visual Studio 2022 with the
  **Desktop development with C++** workload (required by Flutter Windows).
- Flutter SDK 3.22+ (stable channel), Git.
- For a local dev run only, stock engines installed separately:
  - Moonlight Qt — https://github.com/moonlight-stream/moonlight-qt
  - Tailscale Windows client (first) or ZeroTier (fallback).
  The release installers bundle/download these instead — see
  `../installer/` and the "Release build" section above. The
  first-run wizard in the app (`lib/services/component_installer.dart`)
  re-runs the bundled installers when a component is missing.
- Sunshine is installed on the **remote** PCs, not on the launcher PC,
  except when the launcher PC is itself a host.

### Android APK

- Same Flutter SDK, plus Android Studio / Android SDK, Android NDK,
  and a JDK 17.
- Stock Moonlight Android — Google Play (`com.limelight`) or
  https://github.com/moonlight-stream/moonlight-android — installed on
  the phone. LULU launches it; it does not embed it.
- A debug keystore is generated automatically for debug builds. A release
  APK needs your own signing key (`key.properties`, never committed).

## Build commands

```powershell
# 0. First time on a machine with Flutter (regenerates the platform
#    runners if the minimal windows/ and android/ stubs ever drift):
cd launcher
flutter create --platforms=windows,android --org com.lulu.remote .
#    If flutter create overwrites lib/main.dart, restore it from git
#    (git checkout -- lib) before continuing.

# 1. Dependencies
flutter pub get

# 2. Static checks — fix everything this reports before building.
flutter analyze
flutter test

# 3. Windows
flutter build windows --release
..\installer\scripts\build-pairing-worker.ps1
#    Output: build\windows\x64\runner\Release\lulu_remote.exe and lulu_pairing_worker.exe
#    Ship it with the whole Release\ folder (flutter_windows.dll, data\).

# 4. Android (debug APK, for the first phone test)
flutter build apk --debug
#    Output: build\app\outputs\flutter-apk\app-debug.apk

# 5. Android (release APK, after you have a signing key)
flutter build apk --release
```

Both Android APKs are needed for in-app pairing. In CI the companion is built in
`../pairing_worker/android_app/` after copying the generated Gradle wrapper
from `android/`. Build both on the same machine for matching debug signatures.

## First-run checklist on the build machine

1. `flutter doctor` — all checkmarks for Windows + Android before building.
2. Run `flutter test` — the pairing tests use Sunshine's own golden
   vectors (`salt ff5dc6eda99339a8a0793e216c4257c4`, `pin 5338`,
   from `Sunshine/tests/unit/test_http_pairing.cpp`, via the castaway
   notes). If those fail, **do not** try pairing against a real host —
   the crypto is wrong.
3. Install Moonlight Qt, then in LULU open **Setup checklist** and confirm
   it finds `moonlight-qt.exe`. If it does not, add its install folder
   to PATH or edit the search paths in
   `lib/services/moonlight_launcher.dart`.
4. Pair against a real Sunshine host on the LAN first (not over a relayed
   Tailscale path — pairing over a relayed path frequently times out).
   In-app pairing: open the unpaired device, tap **开始配对**, read the
   4-digit PIN shown in LULU, and let LULU submit it to Sunshine
   (`POST https://<host>:47990/api/pin`, admin credentials entered once).
   The pairing request is held open by Sunshine until the PIN is
   submitted, so do not kill the app while it says “等待提交 PIN”.

## What is NOT verified (prototype-verification list)

Do not present any of these as working until the named test passes:

1. **Pairing handshake end-to-end.** The 4-phase `/pair` flow in
   `../pairing_worker/` follows the castaway notes byte-for-byte on paper
   (AES key `SHA-256(salt || PIN)[..16]`, AES-128-ECB no padding,
   cert-signature = raw 256-byte X.509 `signatureValue`, phase 5
   `pairchallenge` over mutual TLS), but it has never run against a real
   Sunshine binary. First test: LAN, one host, `flutter test` golden
   vectors first, then a real pair, then `moonlight-qt list <host>`.
2. **Dart X.509 generation / parsing.** `../pairing_worker/lib/src/client_identity.dart`
   builds the RSA-2048 self-signed cert (`CN=NVIDIA GameStream Client`)
   with hand-written DER via pointycastle ASN.1, and extracts the cert
   signature + RSA public key with a hand-written DER walker. This is
   the #1 compile/behaviour risk. If `flutter analyze` or the tests
   fight it, the fallback is the `basic_utils` package
   (`X509Utils.generateSelfSignedCertificate`) — swap only that file,
   keep the rest of the pairing module unchanged.
3. **`moonlight-qt pair` headless behaviour.** LULU does **not** call
   `moonlight-qt pair` — the official CLI has no reliable headless PIN
   path (`--headless` exists only in some forks). LULU pairs itself and
   only calls `moonlight-qt stream` / `quit` / `list`. If a future
   Moonlight release adds a headless pair mode, re-evaluate; do not
   assume the CLI pair path works.
4. **Android stream handoff.** Moonlight Android v12.2 declares `Game` as
   internal. It uses its own client identity, and its `ServerCert` extra pins
   the host certificate. The launcher opens Moonlight for the initial pairing
   and copies the saved host address. Once paired in Moonlight, the public
   `ShortcutTrampoline` accepts `UUID`, `AppName`, and optionally a string
   `AppId`. The unified acceptance guide covers both entry points and checks
   the resulting picture and input on a phone.
5. **Sunshine `/api/pin` response shape.** `GET /api/pin` is used to
   find the pending `pairing_id`; the code handles a JSON array, a
   JSON object, and an empty response (POST without `pairing_id`).
   The exact shape on the Sunshine version you run may differ — check
   the response in the pairing log on the first real pair.
6. **Tailscale / ZeroTier detection.** `MeshStatusService` checks
   reachability of `https://<mesh-ip>:47990/serverinfo`, not the VPN
   daemon state. A host can be “online” on the mesh and still refuse
   pairing (Sunshine not running, firewall). The setup checklist is
   the place that catches that, not the status dot.
7. **Inno Setup scripts (`.iss`).** Never compiled — no Inno Setup on
   this Linux VM. First CI run is the test. Most likely failure:
   the `/VERYSILENT` switches assume the Moonlight / Sunshine vendor
   installers are Inno Setup based; if `iscc` fails or a vendor
   installer pops a window, check the vendor installers' real silent
   switches first.
8. **CI workflow (`.github/workflows/build.yml`).** Never run. Also
   untested: the `choco install innosetup` step, the APK release-vs-
   debug branch (depends on keystore secrets being set or not), and
   the tag-release upload step.
9. **Component fetch script.** `fetch-components.ps1` picks the
   Sunshine Windows installer by asset-name pattern
   (`*Windows*Installer*.exe`) through the GitHub releases API and
   was never run against the live API. If it cannot find the asset,
   read the error (it lists the real asset names) and fix the pattern.
   The Moonlight asset name (`MoonlightSetup-6.2.0.exe`) and the
   Tailscale MSI SHA-256 come from secondary sources (release listings
   / winget manifest); both are re-verified by hash at build/install
   time and fail loudly on mismatch.
10. **First-run one-click install in the app.** `ComponentInstaller`
    (re-running the bundled installers, UAC elevation via PowerShell)
    and the Play Store jumps on Android were never run — no Flutter,
    no Windows, no phone here. On Android, the honest limit is stated
    in the code and the UI: no silent install of another app is
    possible, one tap to the system install prompt is the maximum.

## Release checklist (before any distribution)

- Pin exact Sunshine / Moonlight versions + SHA-256 in
  `../installer/VERSIONS.md` (single source of truth) and
  `../release/THIRD-PARTY.md`; the build-time `vendor/MANIFEST.md`
  carries the hashes actually downloaded. Ship their LICENSE texts
  (CI fetches them into the installers' `licenses\` folders).
- `../pairing_worker/` ships under GPL-3.0 (see its README). The rest of the
  launcher is MIT. Do not merge the two licences into one file.
- Windows exe is unsigned in v1 — SmartScreen will warn. A code-signing
  certificate is the only fix; do not work around it with an installer
  that suppresses the warning.
- Never commit `*.pem`, `*.key`, `key.properties`, or a real
  `keystore.jks` (see `.gitignore`).

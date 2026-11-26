# BUILD.md — how to build LULU Remote v1

## What was verified in this environment (2026-11-26, Linux VM)

- ✅ Repo layout, `git init`, decisions in `../docs/decisions.md`.
- ✅ Pairing protocol grounded in live sources read 2026-11-26:
  `schlarpc/castaway` `docs/gamestream-protocol-notes.md` (§3, Appendix A),
  Sunshine API docs (`POST /api/pin`, `GET /api/pin`), and the
  moonlight-qt CLI source (`pair` / `list` / `stream` / `quit`).
- ❌ **Flutter / Dart are NOT installed here** (`flutter: command not found`).
  `flutter pub get`, `flutter analyze`, `flutter test`,
  `flutter build windows` and `flutter build apk` have **not** been run.
  Nothing in this scaffold is compile-verified yet.

## What you need (build machine)

### Windows exe

- Windows 10/11 64-bit, Visual Studio 2022 with the
  **Desktop development with C++** workload (required by Flutter Windows).
- Flutter SDK 3.22+ (stable channel), Git.
- Stock engines, installed separately (not bundled):
  - Moonlight Qt — https://github.com/moonlight-stream/moonlight-qt
  - Tailscale Windows client (first) or ZeroTier (fallback).
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
#    Output: build\windows\x64\runner\Release\lulu_remote.exe
#    Ship it with the whole Release\ folder (flutter_windows.dll, data\).

# 4. Android (debug APK, for the first phone test)
flutter build apk --debug
#    Output: build\app\outputs\flutter-apk\app-debug.apk

# 5. Android (release APK, after you have a signing key)
flutter build apk --release
```

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
   `lib/pairing/` follows the castaway notes byte-for-byte on paper
   (AES key `SHA-256(salt || PIN)[..16]`, AES-128-ECB no padding,
   cert-signature = raw 256-byte X.509 `signatureValue`, phase 5
   `pairchallenge` over mutual TLS), but it has never run against a real
   Sunshine binary. First test: LAN, one host, `flutter test` golden
   vectors first, then a real pair, then `moonlight-qt list <host>`.
2. **Dart X.509 generation / parsing.** `lib/pairing/client_identity.dart`
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
4. **Android Game Intent with LULU's own cert.** `MainActivity.kt`
   implements two paths:
   - (a) `ShortcutTrampoline` (UUID + AppId) — works only with
     **Moonlight's own** pairing, so it is the fallback for devices
     paired the old way. It cannot use LULU's cert.
   - (b) Direct `Game` Intent with LULU's cert (`Host`, `Port`,
     `HttpsPort`, `AppName`, `AppId`, `UUID`, `PcName`, `HDR`,
     `ServerCert` DER bytes) — **unverified prototype**. The extra keys
     come from the research report / DeepWiki on moonlight-vplus, not
     from a run against Moonlight Android v12.2. Test on a real phone
     with Moonlight Android installed: if the Game activity finishes
     immediately, the AppId is wrong (read it from `/applist` after
     pairing) or the cert is rejected — then the fallback is forking
     Moonlight Android (whole fork GPL-3.0), which is out of v1 scope.
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

## Release checklist (before any distribution)

- Pin exact Sunshine / Moonlight versions + SHA-256 in
  `../release/THIRD-PARTY.md` and ship their LICENSE texts.
- `lib/pairing/` ships under GPL-3.0 (see its README). The rest of the
  launcher is MIT. Do not merge the two licences into one file.
- Windows exe is unsigned in v1 — SmartScreen will warn. A code-signing
  certificate is the only fix; do not work around it with an installer
  that suppresses the warning.
- Never commit `*.pem`, `*.key`, `key.properties`, or a real
  `keystore.jks` (see `.gitignore`).

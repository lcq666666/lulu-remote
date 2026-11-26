# LULU Remote — Flutter launcher v1 (scaffold)

One Dart codebase, two targets: Windows exe and Android APK.

The launcher is a **thin shell**. It stores devices, shows online status,
runs the in-app GameStream pairing flow, and launches the stock engines.
It does **not** implement video capture/encode/decode, NAT traversal, or
encryption itself — those belong to Sunshine, Moonlight and Tailscale.

## Confirmed decisions (2026-11-26)

- Engine: Moonlight (Sunshine host on each remote Windows PC).
- Networking: Tailscale first, ZeroTier fallback. The mesh address is stored
  per device; the mesh layer is pluggable, never hard-coded to `100.x`.
- Repo: private for now.
- UI: dark green/teal, simple device list, 2 hosts, quality presets.

## Layout

```
lib/
  main.dart            entry point
  app.dart             MaterialApp + dark green/teal theme
  models/              Device, QualityPreset (MIT, launcher code)
  services/            device store, secure store, Moonlight launcher,
                       mesh status, host-setup checklist (MIT)
  pairing/             GameStream 4-phase /pair handshake (GPL-3.0,
                       separate module — see lib/pairing/README.md)
  screens/             home, pairing, add-device, setup checklist
  widgets/             device card, PIN display
android/               MainActivity (MethodChannel for Moonlight Intents)
windows/               minimal runner note — see BUILD.md
test/                   pairing crypto unit tests (golden vectors)
```

## What this scaffold is — and is not

- It is a complete, hand-written project skeleton: `pubspec.yaml`, all Dart
  sources, Android manifest + MainActivity, and build docs.
- It was written on a Linux VM **without Flutter or Dart installed**, so
  `flutter pub get`, `flutter analyze`, `flutter build windows` and
  `flutter build apk` have **not** been run here. See BUILD.md for the exact
  commands and for what is verified vs. not verified.
- No Sunshine / Moonlight binaries are bundled. The launcher detects the
  stock installs and shows a setup checklist when one is missing.

## Licence split

- `lib/` except `lib/pairing/`: MIT (launcher UI + store + launch code).
- `lib/pairing/`: GPL-3.0. It re-implements the GameStream pairing
  handshake from moonlight-common-c / moonlight-chrome logic (see its
  README). Keep it in its own directory; do not link GPL code into the
  launcher beyond this module, and do not copy LL-Remote code — LL-Remote
  has no LICENSE file and is `private: true`, so it is reference only.

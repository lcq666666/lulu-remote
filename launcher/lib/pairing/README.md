# lib/pairing/ — GameStream pairing module (GPL-3.0)

This directory is **legally separate** from the rest of the launcher.

- Licence: **GNU GPL-3.0**. The rest of `lib/` is MIT. Do not move files
  between the two without a licence review, and do not copy code from
  LL-Remote here (or anywhere) — LL-Remote has no LICENSE file and its
  `package.json` is `"private": true`, so it is reference only.
- What it does: the GameStream 4-phase `/pair` handshake against Sunshine,
  so LULU can show the 4-digit PIN **inside LULU** and submit it to
  Sunshine itself, instead of asking the user to open Moonlight's GUI.
- Sources (read, not copied — the implementation below is original Dart,
  written against these specifications):
  - `schlarpc/castaway` `docs/gamestream-protocol-notes.md` §3 + Appendix A
    (derived from moonlight-common-c `e41355e`, Sunshine `965c91a`,
    moonlight-qt) — https://github.com/schlarpc/castaway/blob/HEAD/docs/gamestream-protocol-notes.md
  - moonlight-common-c / moonlight-chrome pairing logic
    (`nvpairingmanager.cpp`, `identitymanager.cpp`) via the castaway notes.
  - Sunshine API docs — `POST /api/pin`
    https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2api.html
  - Sunshine `src/nvhttp.cpp` / `src/crypto.cpp` (server side, via DeepWiki
    summaries and the castaway notes).

## Protocol summary (gen 7+, the Sunshine path)

All five calls are `GET /pair?uniqueid=<id>&uuid=<32hex>&devicename=LULU
&updateState=1&phrase=...` on plaintext HTTP, port 47989 (base port).
`uniqueid` is lowercase hex of a random u64, sent on every call; `uuid`
is 32 hex chars. Sunshine keys the in-flight session on `uniqueid`.

Key derivation: `aesKey = SHA-256(salt || PIN-as-ASCII)[..16]`,
AES-128-ECB, no padding. PIN is ASCII digits — leading zeros matter.

1. `phrase=getservercert` — send `salt` (16 random bytes, lowercase hex)
   and `clientcert` (hex of the client PEM text, lowercase). Sunshine
   **parks this response until a PIN is submitted** (via `/api/pin`),
   so phase 1 must have **no timeout**. Response: `<plaincert>` =
   uppercase hex of the server PEM text.
2. `clientchallenge` — send `ECB(randomChallenge[16])` (32 hex chars).
   Response: `ECB(SHA-256(ourChallenge || serverCertSig || serverSecret)
   || serverChallenge)` — 48 bytes, 96 hex chars.
3. `serverchallengeresp` — send
   `ECB(SHA-256(serverChallenge || clientCertSig || clientSecret))`.
   Response: `pairingsecret` = `serverSecret[16] || RSA-sign(serverSecret)`
   (272 bytes). Client checks here, in order: the RSA signature over the
   server secret (MITM check, against the phase-1 server cert), then the
   PIN hash (wrong PIN if it mismatches).
4. `clientpairingsecret` — send
   `clientSecret[16] || RSA-sign(clientSecret)` (272 bytes). Success is
   `<paired>1</paired>` — note phase 4 returns HTTP 200 with
   `<paired>0</paired>` on refusal, so the status code alone lies.
5. `phrase=pairchallenge` — over **mutual TLS** (port from
   `/serverinfo`'s `HttpsPort`, 47984 by default), first request with the
   new client cert against the pinned server cert. If this fails for any
   reason, the pairing must be discarded.

"Certificate signature" = the raw 256-byte X.509 `signatureValue`
BIT STRING contents (the last element of the DER), not a digest of the
certificate. Getting this wrong completes every phase and fails only
at the end.

## Flow in LULU (why the order matters)

Phase 1 is started **first**, in the background, because Sunshine holds
it open until the PIN arrives. Only then does LULU submit the PIN via
`POST https://<host>:47990/api/pin` (Basic auth, Sunshine admin
credentials entered once, stored only in the OS secure store). Submitting
the PIN before starting phase 1 finds no pending session — `pin()` acts
on the first session in Sunshine's map, not on a lookup by uniqueid.

## What is NOT verified

- This module has never run against a real Sunshine binary. Run
  `flutter test` first (golden vectors from Sunshine's own
  `tests/unit/test_http_pairing.cpp`: salt
  `ff5dc6eda99339a8a0793e216c4257c4`, pin `5338`), then pair on a LAN.
- The hand-written DER builder/parser in `client_identity.dart` /
  `gamestream_crypto.dart` is the #1 risk. Fallback: swap only
  `client_identity.dart` for the `basic_utils` package
  (`X509Utils.generateSelfSignedCertificate`).
- The Android Game Intent with LULU's own cert is a separate,
  unverified prototype (see `MainActivity.kt` and `BUILD.md`).

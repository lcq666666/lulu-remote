// SPDX-License-Identifier: GPL-3.0-only
// LULU Remote — in-app GameStream pairing.
// Protocol: pairing_worker/README.md (castaway gamestream-protocol-notes.md
// §3 / Appendix A; moonlight-common-c e41355e; Sunshine 965c91a).
// This file orchestrates the handshake; the crypto lives in
// gamestream_crypto.dart and the identity in client_identity.dart.
//
// CRITICAL ORDER (read the README before changing it):
//   1. GET /serverinfo (plaintext) — appversion + HttpsPort + host UUID.
//   2. Start phase 1 (/pair?phrase=getservercert) in the background.
//      Sunshine PARKS this response until a PIN is submitted — no timeout.
//   3. Submit the PIN via POST /api/pin (Sunshine admin credentials).
//   4. Phase 1 returns plaincert; run phases 2–4; then phase 5
//      (pairchallenge) over mutual TLS. If phase 5 fails, discard the
//      pairing — the cert may not have entered the host's trust set yet.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data'; // Uint8List — was missing; flutter analyze reported it undefined 10 times

import 'package:xml/xml.dart';

import 'device.dart';
import 'pairing_memory.dart';
import 'client_identity.dart';
import 'gamestream_crypto.dart';
import 'pairing_errors.dart';
import 'sunshine_pin_api.dart';

enum PairingPhase {
  checkingClient,
  checkingNetwork,
  checkingHost,
  checkingAccount,
  starting,
  waitingForPin,
  submittingPin,
  challenging,
  verifying,
  confirmingTls,
  saving,
  done,
}

class PairingProgress {
  const PairingProgress(this.phase, this.message, {this.pin, this.requestName});
  final PairingPhase phase;
  final String message;
  final String? pin;
  final String? requestName;
}

class PairingResult {
  const PairingResult({
    required this.device,
    required this.serverCertDer,
  });
  final Device device;
  final Uint8List serverCertDer;
}

class PairingService {
  PairingService({
    required PairingMemory secureStore,
    SunshinePinApi? pinApi,
  })  : _secureStore = secureStore,
        _pinApi = pinApi ?? SunshinePinApi();

  final PairingMemory _secureStore;
  final SunshinePinApi _pinApi;

  /// Pair [device] and return the updated device + pinned server cert.
  ///
  /// The 4-digit PIN is generated here, handed to the UI via [onProgress]
  /// (so LULU displays it), and submitted to Sunshine by this service —
  /// the user never opens Moonlight. [adminUser]/[adminPassword] are the
  /// Sunshine web UI credentials used for this attempt.
  Future<PairingResult> pair({
    required Device device,
    required String adminUser,
    required String adminPassword,
    void Function(PairingProgress progress)? onProgress,
  }) async {
    void emit(PairingPhase phase, String message,
            {String? pin, String? requestName}) =>
        onProgress?.call(PairingProgress(phase, message,
            pin: pin, requestName: requestName));

    final plainClient = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      // Check the host and account before creating a pending pairing request.
      emit(PairingPhase.checkingHost, '正在确认对方的 Sunshine 服务是否正常。');
      final serverInfo = await _getXml(
        plainClient,
        Uri.parse('${device.nvhttpBase}/serverinfo?uniqueid=lulu-probe'),
        timeout: const Duration(seconds: 5),
      );
      if (_xmlText(serverInfo, 'HttpsPort') == null &&
          _xmlText(serverInfo, 'appversion') == null) {
        throw const PairingTransport(
            '这个地址未返回 Sunshine 的设备信息。请核对对方电脑的地址和远程连接端口。');
      }
      final httpsPort = int.tryParse(_xmlText(serverInfo, 'HttpsPort') ?? '') ??
          (device.sunshinePort - 5);
      final hostUuid =
          _xmlText(serverInfo, 'uuid') ?? _xmlText(serverInfo, 'uniqueid');

      emit(PairingPhase.checkingAccount, '正在验证对方电脑的管理账号和访问权限。');
      await _pinApi.verifyAccount(
        device: device,
        adminUser: adminUser,
        adminPassword: adminPassword,
      );

      emit(PairingPhase.starting, '正在准备本机的配对身份。');
      final identity = await ClientIdentity.loadOrGenerate(_secureStore);
      final uuid = hexEncode(randomBytes(16));
      final requestName = '${Platform.localHostname} · LULU-$uuid';
      final pin = Random.secure().nextInt(10000).toString().padLeft(4, '0');
      final salt = randomBytes(16);
      final aesKey = deriveAesKey(salt, pin);

      // --- Step 1: start phase 1 in the background (NO timeout) ---
      final clientCertHex = hexEncode(ascii.encode(identity.certPem));
      final phase1 = _pairGet(
        plainClient,
        device: device,
        uniqueId: identity.uniqueId,
        uuid: uuid,
        requestName: requestName,
        query: {
          'phrase': 'getservercert',
          'salt': hexEncode(salt),
          'clientcert': clientCertHex,
        },
        timeout: null, // Sunshine parks this until the PIN arrives.
      );
      emit(PairingPhase.waitingForPin, '正在等待对方确认。',
          pin: pin, requestName: requestName);

      // --- Step 2: submit the PIN to Sunshine's web API ---
      // Phase 1 can reject the request before the host exposes a PIN entry.
      Object? requestError;
      StackTrace? requestStack;
      void rememberFailure(Object error, StackTrace stack) {
        requestError = error;
        requestStack = stack;
      }

      unawaited(phase1.then<void>((document) {
        try {
          _requirePaired(document, phase: 1);
        } on PairingException catch (error, stack) {
          rememberFailure(error, stack);
        }
      }, onError: rememberFailure));
      var awaitingPin = true;
      final pinSubmission = _pinApi
          .submitPin(
        device: device,
        pin: pin,
        adminUser: adminUser,
        adminPassword: adminPassword,
        requestName: requestName,
        checkPendingRequest: () {
          final error = requestError;
          if (error != null) Error.throwWithStackTrace(error, requestStack!);
        },
        onRequestFound: () => emit(
            PairingPhase.submittingPin, '对方已登记请求，正在自动提交四位配对码。',
            pin: pin, requestName: requestName),
      )
          .onError<HttpException>((error, stack) async {
        if (requestError != null) Error.throwWithStackTrace(error, stack);
        final pending =
            await _pinApi.listPairings(device, adminUser, adminPassword);
        if (!pending.any((request) => request.name == requestName)) {
          Error.throwWithStackTrace(error, stack);
        }
        if (!awaitingPin) return;
        emit(PairingPhase.waitingForPin, '自动确认未完成，可以在对方电脑上输入 PIN。',
            pin: pin, requestName: requestName);
      });

      // The host can wait for phase 4 before responding to the PIN POST.
      final phase1Doc = await Future.any([
        phase1,
        pinSubmission.then((_) => phase1),
      ]).timeout(const Duration(seconds: 90),
          onTimeout: () => throw const PairingTransport('等待对方确认超时，请重新发起配对。'));
      awaitingPin = false;
      _requirePaired(phase1Doc, phase: 1);
      final plainCertHex = _xmlText(phase1Doc, 'plaincert');
      if (plainCertHex == null || plainCertHex.isEmpty) {
        throw const PairingAlreadyInProgress();
      }
      final serverCertPem = ascii.decode(hexDecode(plainCertHex));
      final serverCertDer = pemToDer(serverCertPem);
      final serverCertSig = extractCertSignature(serverCertDer);
      final serverPublicKey = extractRsaPublicKeyFromCert(serverCertDer);

      // --- Phase 2: clientchallenge ---
      emit(PairingPhase.challenging, '双方正在交换配对验证信息。');
      final randomChallenge = randomBytes(16);
      final challengeCipher = aesEcb(aesKey, randomChallenge, encrypt: true);
      final phase2Doc = await _pairGet(
        plainClient,
        device: device,
        uniqueId: identity.uniqueId,
        uuid: uuid,
        query: {'clientchallenge': hexEncode(challengeCipher)},
      );
      _requirePaired(phase2Doc, phase: 2);
      final challengeResponseHex = _xmlText(phase2Doc, 'challengeresponse');
      if (challengeResponseHex == null) {
        throw const PairingTransport('第 2 步没有返回 challengeresponse。');
      }
      final challengeResponse =
          aesEcb(aesKey, hexDecode(challengeResponseHex), encrypt: false);
      if (challengeResponse.length < 48) {
        throw const PairingTransport('第 2 步返回的数据太短。');
      }
      final serverResponseHash = challengeResponse.sublist(0, 32);
      final serverChallenge = challengeResponse.sublist(32, 48);
      final clientSecret = randomBytes(16);

      // --- Phase 3: serverchallengeresp ---
      final clientCertSig = extractCertSignature(identity.certDer);
      final hashInput = Uint8List.fromList([
        ...serverChallenge,
        ...clientCertSig,
        ...clientSecret,
      ]);
      final serverChallengeResp =
          aesEcb(aesKey, sha256(hashInput), encrypt: true);
      final phase3Doc = await _pairGet(
        plainClient,
        device: device,
        uniqueId: identity.uniqueId,
        uuid: uuid,
        query: {'serverchallengeresp': hexEncode(serverChallengeResp)},
      );
      _requirePaired(phase3Doc, phase: 3);
      final pairingSecretHex = _xmlText(phase3Doc, 'pairingsecret');
      if (pairingSecretHex == null) {
        throw const PairingTransport('第 3 步没有返回 pairingsecret。');
      }
      final pairingSecret = hexDecode(pairingSecretHex);
      if (pairingSecret.length <= 16) {
        throw const PairingTransport('第 3 步返回的 pairingsecret 太短。');
      }
      final serverSecret = pairingSecret.sublist(0, 16);
      final serverSignature = pairingSecret.sublist(16);

      // Trust checks, in order: MITM first, PIN second (see README).
      emit(PairingPhase.verifying, '正在核对对方身份和配对码。');
      if (!rsaVerifySha256(serverPublicKey, serverSecret, serverSignature)) {
        throw const PairingMitm();
      }
      final pinHash = sha256(Uint8List.fromList([
        ...randomChallenge,
        ...serverCertSig,
        ...serverSecret,
      ]));
      if (!_bytesEqual(pinHash, serverResponseHash)) {
        throw const PairingWrongPin();
      }

      // --- Phase 4: clientpairingsecret ---
      final clientPairingSecret = Uint8List.fromList([
        ...clientSecret,
        ...rsaSignSha256(identity.privateKey, clientSecret),
      ]);
      final phase4Doc = await _pairGet(
        plainClient,
        device: device,
        uniqueId: identity.uniqueId,
        uuid: uuid,
        query: {'clientpairingsecret': hexEncode(clientPairingSecret)},
      );
      // Phase 4 reports refusal as HTTP 200 + <paired>0</paired>.
      if (_xmlText(phase4Doc, 'paired') != '1') {
        throw const PairingRefused();
      }

      // --- Phase 5: pairchallenge over mutual TLS ---
      emit(PairingPhase.confirmingTls, '正在确认对方已经授权这台设备。');
      await _pairChallengeTls(
        device: device,
        httpsPort: httpsPort,
        identity: identity,
        uuid: uuid,
        serverCertDer: serverCertDer,
      );

      // Persist the pinned server cert, then resolve the applist.
      emit(PairingPhase.saving, '正在保存配对信息并读取可连接的应用。');
      await _secureStore.writeSunshineUser(device.id, adminUser);
      await _secureStore.writeServerCertHex(
        device.id,
        hexEncode(serverCertDer),
      );
      final appId = await _resolveAppId(
        device: device,
        httpsPort: httpsPort,
        identity: identity,
        serverCertDer: serverCertDer,
      );
      final updated = device.copyWith(
        paired: true,
        appId: appId,
        hostUuid: hostUuid,
      );
      emit(PairingPhase.done, '配对成功，以后点连接就行。');
      return PairingResult(device: updated, serverCertDer: serverCertDer);
    } finally {
      plainClient.close(force: true);
    }
  }

  // --- NVHTTP helpers ---------------------------------------------------

  Future<XmlDocument> _pairGet(
    HttpClient client, {
    required Device device,
    required String uniqueId,
    required String uuid,
    String requestName = 'LULU',
    required Map<String, String> query,
    Duration? timeout = const Duration(seconds: 5),
  }) async {
    final params = <String, String>{
      'uniqueid': uniqueId,
      'uuid': uuid,
      'devicename': requestName,
      'updateState': '1',
      ...query,
    };
    final uri =
        Uri.parse('${device.nvhttpBase}/pair').replace(queryParameters: params);
    return _getXml(client, uri, timeout: timeout);
  }

  Future<XmlDocument> _getXml(
    HttpClient client,
    Uri uri, {
    Duration? timeout,
  }) async {
    Future<XmlDocument> run() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      // Sunshine closes NVHTTP sockets even without a Connection: close header.
      request.persistentConnection = false;
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw PairingTransport(
          '对方返回 HTTP ${response.statusCode}。请核对地址与远程连接端口。',
        );
      }
      try {
        return XmlDocument.parse(text);
      } on XmlParserException {
        throw const PairingTransport('对方返回的设备信息无法识别。请核对地址与远程连接端口。');
      }
    }

    final future = run();
    return timeout == null ? future : future.timeout(timeout);
  }

  static void _requirePaired(XmlDocument doc, {required int phase}) {
    final root = doc.rootElement;
    if (root.getAttribute('status_code') != '200' ||
        _xmlText(doc, 'paired') != '1') {
      throw PairingTransport(
        '第 $phase 步失败：${_xmlText(doc, 'status_message') ?? '未知错误'}',
      );
    }
  }

  static String? _xmlText(XmlDocument doc, String tag) {
    final elements = doc.findAllElements(tag);
    return elements.isEmpty ? null : elements.first.innerText;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Phase 5: the first mutual-TLS request with the new client cert,
  /// against the server cert pinned from phase 1. Any failure here
  /// means the pairing is discarded by the caller (paired stays false).
  Future<void> _pairChallengeTls({
    required Device device,
    required int httpsPort,
    required ClientIdentity identity,
    required String uuid,
    required Uint8List serverCertDer,
  }) async {
    final client = _tlsClient(identity: identity, serverCertDer: serverCertDer);
    try {
      final uri = Uri.parse('${device.tlsBase}/pair').replace(
        queryParameters: {
          'uniqueid': identity.uniqueId,
          'uuid': uuid,
          'devicename': 'LULU',
          'updateState': '1',
          'phrase': 'pairchallenge',
        },
      );
      // tlsBase uses the default port (base-5); rebuild with HttpsPort.
      final fixed = uri.replace(port: httpsPort);
      final doc = await _getXml(
        client,
        fixed,
        timeout: const Duration(seconds: 10),
      );
      _requirePaired(doc, phase: 5);
    } on PairingException {
      rethrow;
    } catch (e) {
      throw PairingTransport('TLS 确认失败（第 5 步）：$e。请重试配对。');
    } finally {
      client.close();
    }
  }

  /// /applist over mutual TLS — resolves the numeric AppId for
  /// device.appName ("Desktop"), needed for the Android Game Intent.
  Future<int?> _resolveAppId({
    required Device device,
    required int httpsPort,
    required ClientIdentity identity,
    required Uint8List serverCertDer,
  }) async {
    final client = _tlsClient(identity: identity, serverCertDer: serverCertDer);
    try {
      final uri = Uri.parse('${device.tlsBase}/applist').replace(
        port: httpsPort,
        queryParameters: {'uniqueid': identity.uniqueId},
      );
      final doc = await _getXml(
        client,
        uri,
        timeout: const Duration(seconds: 10),
      );
      for (final app in doc.findAllElements('App')) {
        final titles = app.findElements('AppTitle');
        final title = titles.isEmpty ? null : titles.first.innerText;
        if (title == device.appName) {
          final ids = app.findElements('ID');
          final id = ids.isEmpty ? null : ids.first.innerText;
          return int.tryParse(id ?? '');
        }
      }
      return null;
    } catch (_) {
      // Applist is a nice-to-have: pairing already succeeded. The UI
      // can retry it later; Android launch needs it, Windows does not
      // (moonlight-qt streams by app name).
      return null;
    } finally {
      client.close();
    }
  }

  /// HttpClient with the LULU client cert (mutual TLS) that trusts
  /// exactly one server certificate — the one pinned in phase 1.
  /// The host cert is self-signed, so normal validation would reject
  /// every host; skipping validation would accept any host. Pinning is
  /// the only check that means anything here.
  HttpClient _tlsClient({
    required ClientIdentity identity,
    required Uint8List serverCertDer,
  }) {
    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(utf8.encode(identity.certPem));
    context.usePrivateKeyBytes(utf8.encode(identity.keyPem));
    final client = HttpClient(context: context)..findProxy = (_) => 'DIRECT';
    final expected = sha256(serverCertDer);
    client.badCertificateCallback =
        (cert, _, __) => _bytesEqual(sha256(cert.der), expected);
    return client;
  }
}

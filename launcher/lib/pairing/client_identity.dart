// SPDX-License-Identifier: GPL-3.0-only
// LULU Remote — client identity (RSA-2048 self-signed certificate).
// The client identity IS the credential: pairing teaches a host to trust
// one specific certificate, and every later HTTPS request authenticates
// by presenting it. Lose the key and you re-pair with every host.
//
// Shape reproduced from Moonlight, not Sunshine's tolerance:
// RSA-2048, self-signed, CN=NVIDIA GameStream Client, SHA-256.
// Sunshine accepts expired client certificates deliberately (matching
// GFE), so validity is not load-bearing — but the certificate bytes are,
// because pairing hashes them.
//
// The DER builder below is hand-written (no ASN.1 library is used) so
// the module depends only on pointycastle. It is the #1 verification
// risk in this module: test it against the golden vectors in test/
// before pairing against a real host. Fallback: swap this file for the
// `basic_utils` package (X509Utils.generateSelfSignedCertificate).

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../services/secure_store.dart';
import 'gamestream_crypto.dart';

class ClientIdentity {
  ClientIdentity({
    required this.privateKey,
    required this.publicKey,
    required this.certPem,
    required this.keyPem,
    required this.uniqueId,
  });

  final RSAPrivateKey privateKey;
  final RSAPublicKey publicKey;

  /// PEM of the self-signed certificate (CN=NVIDIA GameStream Client).
  final String certPem;

  /// PEM of the private key (PKCS#8), for dart:io SecurityContext
  /// (mutual TLS in phase 5). The signing key itself is also stored as
  /// JSON components in secure storage — see [SecureStore].
  final String keyPem;

  /// Lowercase hex of a random u64, generated once and persisted, sent
  /// on every pairing request. Not a secret, not an authenticator.
  final String uniqueId;

  /// DER bytes of the certificate (for the Game Intent ServerCert extra
  /// and for pinning the server cert by fingerprint).
  Uint8List get certDer => pemToDer(certPem);

  /// Load the persisted identity, or generate + persist a new one.
  static Future<ClientIdentity> loadOrGenerate(SecureStore store) async {
    final certPem = await store.readClientCertPem();
    final keyPem = await store.readClientKeyPem();
    final keyJson = await store.readClientKeyJson();
    final uniqueId = await store.readUniqueId();
    if (certPem != null && keyPem != null && keyJson != null) {
      final key = _privateKeyFromJson(keyJson);
      return ClientIdentity(
        privateKey: key,
        publicKey: RSAPublicKey(key.modulus!, BigInt.from(65537)),
        certPem: certPem,
        keyPem: keyPem,
        uniqueId: uniqueId ?? await _newUniqueId(store),
      );
    }
    final identity = generate();
    await store.writeClientCertPem(identity.certPem);
    await store.writeClientKeyPem(identity.keyPem);
    await store.writeClientKeyJson(_privateKeyToJson(identity.privateKey));
    await store.writeUniqueId(identity.uniqueId);
    return identity;
  }

  static Future<String> _newUniqueId(SecureStore store) async {
    final id = hexEncode(randomBytes(8));
    await store.writeUniqueId(id);
    return id;
  }

  /// Generate a fresh RSA-2048 identity + self-signed certificate.
  static ClientIdentity generate() {
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(randomBytes(32)));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
          secureRandom,
        ),
      );
    final pair = generator.generateKeyPair();
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;
    final certDer = _buildSelfSignedCert(privateKey, publicKey);
    final keyPem = derToPem(_buildPkcs8(privateKey), 'PRIVATE KEY');
    return ClientIdentity(
      privateKey: privateKey,
      publicKey: publicKey,
      certPem: derToPem(certDer, 'CERTIFICATE'),
      keyPem: keyPem,
      uniqueId: hexEncode(randomBytes(8)),
    );
  }

  static String _privateKeyToJson(RSAPrivateKey key) => jsonEncode({
        'n': key.modulus!.toRadixString(16),
        'e': BigInt.from(65537).toRadixString(16),
        'd': key.privateExponent!.toRadixString(16),
        'p': key.p!.toRadixString(16),
        'q': key.q!.toRadixString(16),
      });

  static RSAPrivateKey _privateKeyFromJson(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return RSAPrivateKey(
      BigInt.parse(map['n'] as String, radix: 16),
      BigInt.parse(map['d'] as String, radix: 16),
      BigInt.parse(map['p'] as String, radix: 16),
      BigInt.parse(map['q'] as String, radix: 16),
    );
  }

  // --- DER construction -------------------------------------------------

  static Uint8List _buildSelfSignedCert(
    RSAPrivateKey privateKey,
    RSAPublicKey publicKey,
  ) {
    final name = _rdn('NVIDIA GameStream Client');
    final now = DateTime.now().toUtc();
    final tbs = _derSequence([
      _derExplicit0(_derInteger(BigInt.two)), // version v3
      _derInteger(_serial()),
      _derSequence([_derOid([1, 2, 840, 113549, 1, 1, 11]), _derNull()]),
      name, // issuer
      _derSequence([
        _derUtcTime(now),
        _derUtcTime(now.add(const Duration(days: 3650))),
      ]),
      name, // subject
      _derSequence([
        _derSequence([_derOid([1, 2, 840, 113549, 1, 1, 1]), _derNull()]),
        _derBitString(_derSequence([
          _derInteger(publicKey.modulus!),
          _derInteger(publicKey.exponent!),
        ])),
      ]),
    ]);
    final signature = rsaSignSha256(privateKey, tbs);
    return _derSequence([
      tbs,
      _derSequence([_derOid([1, 2, 840, 113549, 1, 1, 11]), _derNull()]),
      _derBitString(signature),
    ]);
  }

  static Uint8List _buildPkcs8(RSAPrivateKey key) {
    final p = key.p!;
    final q = key.q!;
    final d = key.privateExponent!;
    final dp = d % (p - BigInt.one);
    final dq = d % (q - BigInt.one);
    final qinv = q.modInverse(p);
    final rsaPrivate = _derSequence([
      _derInteger(BigInt.zero),
      _derInteger(key.modulus!),
      _derInteger(BigInt.from(65537)),
      _derInteger(d),
      _derInteger(p),
      _derInteger(q),
      _derInteger(dp),
      _derInteger(dq),
      _derInteger(qinv),
    ]);
    return _derSequence([
      _derInteger(BigInt.zero),
      _derSequence([_derOid([1, 2, 840, 113549, 1, 1, 1]), _derNull()]),
      _derOctetString(rsaPrivate),
    ]);
  }

  static BigInt _serial() {
    final bytes = randomBytes(8);
    bytes[0] &= 0x7F; // keep positive
    return BigInt.parse(hexEncode(bytes), radix: 16);
  }

  static Uint8List _rdn(String commonName) => _derSequence([
        _derSet([
          _derSequence([
            _derOid([2, 5, 4, 3]), // CN
            _derUtf8(commonName),
          ]),
        ]),
      ]);

  // --- tiny DER writer (tag + length + contents) ------------------------

  static Uint8List _tlv(int tag, Uint8List content) {
    final length = _derLength(content.length);
    return Uint8List.fromList([tag, ...length, ...content]);
  }

  static Uint8List _derLength(int length) {
    if (length < 0x80) return Uint8List.fromList([length]);
    final bytes = <int>[];
    var value = length;
    while (value > 0) {
      bytes.insert(0, value & 0xFF);
      value >>= 8;
    }
    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }

  static Uint8List _derSequence(List<Uint8List> children) =>
      _tlv(0x30, _concat(children));

  static Uint8List _derSet(List<Uint8List> children) =>
      _tlv(0x31, _concat(children));

  static Uint8List _derExplicit0(Uint8List content) => _tlv(0xA0, content);

  static Uint8List _derInteger(BigInt value) {
    var bytes = <int>[];
    var v = value;
    if (v == BigInt.zero) return _tlv(0x02, Uint8List.fromList([0]));
    while (v > BigInt.zero) {
      bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
      v >>= 8;
    }
    if (bytes[0] & 0x80 != 0) bytes.insert(0, 0);
    return _tlv(0x02, Uint8List.fromList(bytes));
  }

  static Uint8List _derOid(List<int> arcs) {
    final bytes = <int>[40 * arcs[0] + arcs[1]];
    for (final arc in arcs.skip(2)) {
      var value = arc;
      final stack = <int>[value & 0x7F];
      value >>= 7;
      while (value > 0) {
        stack.insert(0, (value & 0x7F) | 0x80);
        value >>= 7;
      }
      bytes.addAll(stack);
    }
    return _tlv(0x06, Uint8List.fromList(bytes));
  }

  static Uint8List _derNull() => _tlv(0x05, Uint8List(0));

  static Uint8List _derBitString(Uint8List content) =>
      _tlv(0x03, Uint8List.fromList([0, ...content]));

  static Uint8List _derOctetString(Uint8List content) =>
      _tlv(0x04, content);

  static Uint8List _derUtf8(String value) =>
      _tlv(0x0C, Uint8List.fromList(utf8.encode(value)));

  static Uint8List _derUtcTime(DateTime time) {
    final y = (time.year % 100).toString().padLeft(2, '0');
    final text =
        '$y${_two(time.month)}${_two(time.day)}${_two(time.hour)}${_two(time.minute)}${_two(time.second)}Z';
    return _tlv(0x17, Uint8List.fromList(ascii.encode(text)));
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static Uint8List _concat(List<Uint8List> parts) {
    final out = <int>[];
    for (final part in parts) {
      out.addAll(part);
    }
    return Uint8List.fromList(out);
  }
}

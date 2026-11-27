// SPDX-License-Identifier: GPL-3.0-only
// LULU Remote — GameStream pairing crypto.
// Written from the specification in pairing_worker/README.md
// (castaway gamestream-protocol-notes.md §3 / Appendix A, derived from
// moonlight-common-c e41355e and Sunshine 965c91a). Original Dart code;
// no code copied from LL-Remote or from moonlight-common-c.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';

/// Hex helpers. LULU emits lowercase, natural byte order; Sunshine emits
/// uppercase. Decoding is strict — non-hex input is an error, not a guess.
String hexEncode(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexDecode(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(clean)) {
    throw const FormatException('invalid hex string');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List sha256(Uint8List data) =>
    Uint8List.fromList(crypto.sha256.convert(data).bytes);

Uint8List randomBytes(int length) {
  final rnd = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rnd.nextInt(256)),
  );
}

/// Gen-7 AES key: SHA-256(salt || PIN-as-ASCII), first 16 bytes.
/// The PIN is ASCII digits — leading zeros matter.
Uint8List deriveAesKey(Uint8List salt, String pin) {
  final input = Uint8List.fromList([...salt, ...ascii.encode(pin)]);
  return sha256(input).sublist(0, 16);
}

/// AES-128-ECB, no padding. [data] must be a multiple of 16 bytes —
/// every pairing field is (16 / 32 / 48 bytes).
Uint8List aesEcb(Uint8List key, Uint8List data, {required bool encrypt}) {
  if (data.length % 16 != 0) {
    throw ArgumentError('AES-ECB input must be a multiple of 16 bytes');
  }
  final cipher = ECBBlockCipher(AESEngine())
    ..init(encrypt, KeyParameter(key));
  final out = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += 16) {
    cipher.processBlock(data, offset, out, offset);
  }
  return out;
}

// DER encoding of the SHA-256 object identifier (2.16.840.1.101.3.4.2.1).
const _sha256DigestIdentifier = '0609608648016503040201';

/// RSA PKCS#1 v1.5, SHA-256 — the signature over a 16-byte secret.
Uint8List rsaSignSha256(RSAPrivateKey key, Uint8List data) {
  final signer = RSASigner(SHA256Digest(), _sha256DigestIdentifier)
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  return signer.generateSignature(data).bytes;
}

/// RSA PKCS#1 v1.5, SHA-256 verification against a public key parsed
/// from a certificate (see [extractRsaPublicKeyFromCert]).
bool rsaVerifySha256(RSAPublicKey key, Uint8List data, Uint8List signature) {
  final verifier = RSASigner(SHA256Digest(), _sha256DigestIdentifier)
    ..init(false, PublicKeyParameter<RSAPublicKey>(key));
  return verifier.verifySignature(data, RSASignature(signature));
}

// ---------------------------------------------------------------------------
// Minimal DER reader/writer. Used only for X.509 certificates: extracting
// the signatureValue and the RSA public key, and building the self-signed
// client certificate (see client_identity.dart). No general ASN.1 support
// is claimed.
// ---------------------------------------------------------------------------

class _Tlv {
  _Tlv(this.tag, this.headerLength, this.value, this.totalLength);
  final int tag;
  final int headerLength;
  final Uint8List value; // contents only (no tag/length)
  final int totalLength; // tag + length + contents
}

_Tlv _readTlv(Uint8List der, int offset) {
  final tag = der[offset];
  var pos = offset + 1;
  var length = der[pos++];
  if (length & 0x80 != 0) {
    final count = length & 0x7F;
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[pos++];
    }
  }
  final value = der.sublist(pos, pos + length);
  return _Tlv(tag, pos - offset, value, (pos - offset) + length);
}

/// Children of a SEQUENCE / SET / explicitly-tagged value.
List<Uint8List> derChildren(Uint8List der, {int offset = 0}) {
  final outer = _readTlv(der, offset);
  final out = <Uint8List>[];
  var pos = 0;
  final bytes = outer.value;
  while (pos < bytes.length) {
    final child = _readTlv(bytes, pos);
    out.add(bytes.sublist(pos, pos + child.totalLength));
    pos += child.totalLength;
  }
  return out;
}

/// The raw TLV bytes of the first child (used to get the exact
/// TBSCertificate bytes that were signed).
Uint8List derFirstChildRaw(Uint8List der) {
  final outer = _readTlv(der, 0);
  final child = _readTlv(outer.value, 0);
  return outer.value.sublist(0, child.totalLength);
}

/// X.509 certificate signatureValue: the raw signature bytes (for
/// RSA-2048, 256 bytes) — the BIT STRING contents of the third element
/// of the certificate SEQUENCE, minus its leading unused-bits byte.
///
/// This is the value both sides hash in the pairing handshake. It is
/// NOT a digest of the certificate and NOT the TBS bytes.
Uint8List extractCertSignature(Uint8List certDer) {
  final children = derChildren(certDer);
  if (children.length < 3) {
    throw const FormatException('certificate has fewer than 3 elements');
  }
  final bitString = _readTlv(children[2], 0);
  if (bitString.tag != 0x03 || bitString.value.isEmpty) {
    throw const FormatException('third certificate element is not a BIT STRING');
  }
  // First content byte is the unused-bits count (0 for a signature).
  return bitString.value.sublist(1);
}

/// RSA public key from a certificate's subjectPublicKeyInfo:
/// SPKI = SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { SEQUENCE {
/// modulus INTEGER, exponent INTEGER } }.
RSAPublicKey extractRsaPublicKeyFromCert(Uint8List certDer) {
  final tbsChildren = derChildren(derFirstChildRaw(certDer));
  // TBSCertificate: version, serial, sigAlg, issuer, validity, subject,
  // subjectPublicKeyInfo is the 7th element (index 6).
  if (tbsChildren.length < 7) {
    throw const FormatException('TBSCertificate has fewer than 7 elements');
  }
  final spkiChildren = derChildren(tbsChildren[6]);
  if (spkiChildren.length < 2) {
    throw const FormatException('subjectPublicKeyInfo is malformed');
  }
  final bitString = _readTlv(spkiChildren[1], 0);
  final rsaSeq = derChildren(bitString.value.sublist(1));
  if (rsaSeq.length < 2) {
    throw const FormatException('RSA public key is malformed');
  }
  return RSAPublicKey(
    _derInteger(rsaSeq[0]),
    _derInteger(rsaSeq[1]),
  );
}

BigInt _derInteger(Uint8List tlvBytes) {
  final tlv = _readTlv(tlvBytes, 0);
  if (tlv.tag != 0x02) throw const FormatException('expected INTEGER');
  var bytes = tlv.value;
  // Strip a leading zero byte added to keep the integer positive.
  if (bytes.isNotEmpty && bytes[0] == 0) bytes = bytes.sublist(1);
  return BigInt.parse(hexEncode(bytes), radix: 16);
}

/// PEM text -> DER bytes (strips the header/footer and whitespace).
Uint8List pemToDer(String pem) {
  final body = pem
      .replaceAll(RegExp(r'-----BEGIN [A-Z ]+-----'), '')
      .replaceAll(RegExp(r'-----END [A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  return base64Decode(body);
}

/// DER bytes -> PEM text with 64-character lines.
String derToPem(Uint8List der, String label) {
  final b64 = base64Encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

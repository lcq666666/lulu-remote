// Golden-vector tests for the pairing crypto.
//
// Vectors come from Sunshine's own unit test
// (tests/unit/test_http_pairing.cpp), quoted in schlarpc/castaway
// docs/gamestream-protocol-notes.md §3.8:
//   salt = "ff5dc6eda99339a8a0793e216c4257c4", pin = "5338"
//   clientchallenge ciphertext = 741CD3D6890C16DA39D53BCA0893AAF0
//     (plaintext: the ASCII text "CLIENT CHALLENGE")
//   serverchallengeresp ciphertext =
//     920BABAE9F7599AA1CA8EC87FB3454C91872A7D8D5127DDC176C2FDAE635CF7A
//     (plaintext: SHA-256 6493DAE49C913E1AEAF37C1072F71D664B72B2C4DA1FFB4720BECE0D929E008A)
//
// Run BEFORE pairing against a real host. If these fail, the crypto is
// wrong and a real pair will fail at the end with no useful error — do
// not debug it against a live Sunshine first.
//
// NOTE: these tests have never been run — Flutter/Dart are not installed
// in the environment where this scaffold was written. See BUILD.md.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lulu_remote/pairing/client_identity.dart';
import 'package:lulu_remote/pairing/gamestream_crypto.dart';
import 'package:pointycastle/export.dart';

void main() {
  test('SHA-256 known vector', () {
    expect(
      hexEncode(sha256(Uint8List.fromList(ascii.encode('abc')))),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('hex round-trip is strict', () {
    expect(hexEncode(hexDecode('ff5dc6eda99339a8')), 'ff5dc6eda99339a8');
    expect(() => hexDecode('zz'), throwsFormatException);
    expect(() => hexDecode('abc'), throwsFormatException); // odd length
  });

  test('AES key derivation is PIN-sensitive (leading zeros matter)', () {
    final salt = hexDecode('ff5dc6eda99339a8a0793e216c4257c4');
    final keyA = deriveAesKey(salt, '5338');
    final keyB = deriveAesKey(salt, '0538');
    expect(keyA.length, 16);
    expect(keyA, isNot(keyB));
    expect(deriveAesKey(salt, '5338'), keyA); // deterministic
  });

  test('golden vector: clientchallenge decrypts to "CLIENT CHALLENGE"', () {
    final salt = hexDecode('ff5dc6eda99339a8a0793e216c4257c4');
    final aesKey = deriveAesKey(salt, '5338');
    final plain = aesEcb(
      aesKey,
      hexDecode('741CD3D6890C16DA39D53BCA0893AAF0'),
      encrypt: false,
    );
    expect(ascii.decode(plain), 'CLIENT CHALLENGE');
  });

  test('golden vector: serverchallengeresp decrypts to the known SHA-256', () {
    final salt = hexDecode('ff5dc6eda99339a8a0793e216c4257c4');
    final aesKey = deriveAesKey(salt, '5338');
    final plain = aesEcb(
      aesKey,
      hexDecode(
        '920BABAE9F7599AA1CA8EC87FB3454C91872A7D8D5127DDC176C2FDAE635CF7A',
      ),
      encrypt: false,
    );
    expect(
      hexEncode(plain),
      '6493dae49c913e1aeaf37c1072f71d664b72b2c4da1ffb4720bece0d929e008a',
    );
  });

  test('AES-ECB round-trip (16/32/48 bytes)', () {
    final key = randomBytes(16);
    for (final length in [16, 32, 48]) {
      final data = randomBytes(length);
      final encrypted = aesEcb(key, data, encrypt: true);
      expect(aesEcb(key, encrypted, encrypt: false), data);
    }
  });

  test('verifies an OpenSSL RSA-SHA256 pairing signature', () {
    // Generated with OpenSSL-backed PKCS#1 v1.5 signing. Only the public
    // modulus and signature are retained, so this does not test a round-trip.
    final modulus = base64Decode(
      '2CiROG9URLAzgd5aUlPcpCCeyMmJnkIoeNphMcC81d6bL6cFca9DSyzoxySWie4B'
      'kQgl4PBVr9jjVH4W/t9B65AeF6fgo97PmZkyygYGS2VLMJ0vmMQGRonNsuG30m2s'
      'u9NEBeU5YtljiXMgMD20sIte5sop2AaJ6gkxioScowGzduFo5DkMeuekM8BjH0UC'
      'qSMkms1crnC1BsMZ+enJj3WwUl+uJpbMQT+9vHz6Li39XNgmiLtj+1glLJ9h6Mi2'
      'oSu7XF7wnT4TIDxt/GDTYG/Mz9Ht8ulXtIT6FV6fpFPmvhqjQH9BeuXYPBWNK81t'
      'YEjxq+ZI2nR2+m2UcYqKew==',
    );
    final publicKey = RSAPublicKey(
      BigInt.parse(hexEncode(modulus), radix: 16),
      BigInt.from(65537),
    );
    final signature = base64Decode(
      'x2SN3+OcNHWaOq+e16/KxJCSaf8ga+cObODbSf3t8diYuUi40XcqjyhUMmslS8TF'
      'DE6Eh9PgNHkBRY+Fzx3GZ19X7perMXklWBzDJbR4MPcOLxRzx63+jn9WGf6Dt71Q'
      'Y3Gb6tw9mU27b8GnkeTiDeb0/6v3+htr9VQLu17NFmRTvrsr7mfmgkDyn+N2rUys'
      'N+Ma/YB5G3j6XpTDgmQjGXdNoFiOtT0d+mh0jrUsxy+sGPL0UBzph6SKB/4dQtEE'
      '8vhI8CGjDkF7V7PpAkCUXyFK90hBnkEoj6cWs9REd+5Mtm8pWdACC1m4+r2EZtU8'
      'FfjZIVTnSagwzAKTry1vjg==',
    );
    final secret = Uint8List.fromList(ascii.encode('LULU pairingtest'));
    expect(rsaVerifySha256(publicKey, secret, signature), isTrue);
    secret[0] ^= 1;
    expect(rsaVerifySha256(publicKey, secret, signature), isFalse);
  });

  test(
    'generated identity: RSA sign/verify round-trip, cert signature is 256 bytes',
    () {
      final identity = ClientIdentity.generate();
      expect(identity.uniqueId.length, 16);
      expect(identity.certPem, contains('BEGIN CERTIFICATE'));
      expect(identity.keyPem, contains('BEGIN PRIVATE KEY'));

      final data = randomBytes(16);
      final signature = rsaSignSha256(identity.privateKey, data);
      expect(signature.length, 256);
      expect(rsaVerifySha256(identity.publicKey, data, signature), isTrue);
      expect(
        rsaVerifySha256(identity.publicKey, randomBytes(16), signature),
        isFalse,
      );

      final certDer = identity.certDer;
      expect(extractCertSignature(certDer).length, 256);
      final parsedKey = extractRsaPublicKeyFromCert(certDer);
      expect(parsedKey.modulus, identity.publicKey.modulus);
      expect(parsedKey.exponent, identity.publicKey.exponent);
    },
    timeout: const Timeout(Duration(minutes: 2)), // RSA-2048 keygen is slow
  );
}

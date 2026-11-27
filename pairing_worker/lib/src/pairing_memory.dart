// SPDX-License-Identifier: GPL-3.0-only

/// Request-scoped memory for identity material. The calling launcher commits
/// updates to its system secure store when the worker sends them over IPC.
class PairingMemory {
  PairingMemory({
    this.certPem,
    this.keyPem,
    this.keyJson,
    this.uniqueId,
    this.onWrite,
  });

  String? certPem;
  String? keyPem;
  String? keyJson;
  String? uniqueId;
  final void Function(String field, String value)? onWrite;
  final serverCerts = <String, String>{};

  Future<String?> readClientCertPem() async => certPem;
  Future<String?> readClientKeyPem() async => keyPem;
  Future<String?> readClientKeyJson() async => keyJson;
  Future<String?> readUniqueId() async => uniqueId;
  Future<String?> readServerCertHex(String deviceId) async =>
      serverCerts[deviceId];

  Future<void> writeClientCertPem(String value) async {
    certPem = value;
    onWrite?.call('clientCertPem', value);
  }

  Future<void> writeClientKeyPem(String value) async {
    keyPem = value;
    onWrite?.call('clientKeyPem', value);
  }

  Future<void> writeClientKeyJson(String value) async {
    keyJson = value;
    onWrite?.call('clientKeyJson', value);
  }

  Future<void> writeUniqueId(String value) async {
    uniqueId = value;
    onWrite?.call('uniqueId', value);
  }

  Future<void> writeSunshineUser(String deviceId, String value) async {
    onWrite?.call('sunshineUser', value);
  }

  Future<void> writeServerCertHex(String deviceId, String value) async {
    serverCerts[deviceId] = value;
    onWrite?.call('serverCertHex', value);
  }
}

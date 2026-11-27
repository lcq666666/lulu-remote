// SPDX-License-Identifier: GPL-3.0-only

/// The remote host fields used by the pairing worker.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.meshAddress,
    this.sunshinePort = 47989,
    this.webPort = 47990,
    this.appName = 'Desktop',
    this.appId,
    this.hostUuid,
    this.paired = false,
  });

  final String id;
  final String name;
  final String meshAddress;
  final int sunshinePort;
  final int webPort;
  final String appName;
  final int? appId;
  final String? hostUuid;
  final bool paired;

  String get nvhttpBase => 'http://$meshAddress:$sunshinePort';
  String get webBase => 'https://$meshAddress:$webPort';
  String get tlsBase => 'https://$meshAddress:${sunshinePort - 5}';

  Device copyWith({bool? paired, int? appId, String? hostUuid}) => Device(
        id: id,
        name: name,
        meshAddress: meshAddress,
        sunshinePort: sunshinePort,
        webPort: webPort,
        appName: appName,
        paired: paired ?? this.paired,
        appId: appId ?? this.appId,
        hostUuid: hostUuid ?? this.hostUuid,
      );
}

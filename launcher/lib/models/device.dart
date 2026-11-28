import 'dart:io';

/// A remote Windows PC (a Sunshine host).
///
/// Only non-secret fields are stored here. The Sunshine admin password,
/// the LULU client certificate/key and the pinned server certificate live
/// in [SecureStore] (flutter_secure_storage), never in this object and
/// never in SharedPreferences.
class Device {
  Device({
    required this.id,
    required this.name,
    required this.meshAddress,
    this.network = NetworkKind.tailscale,
    this.sunshinePort = 47989,
    this.webPort = 47990,
    this.appName = 'Desktop',
    this.appId,
    this.hostUuid,
    this.paired = false,
    this.lastSeen,
    this.wakeMac,
    this.wakeRelayAddress,
    this.group = '',
    this.nickname = '',
  });

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: json['id'] as String,
        name: json['name'] as String,
        meshAddress: json['meshAddress'] as String,
        network: NetworkKind.values.firstWhere(
          (e) => e.name == (json['network'] as String? ?? 'tailscale'),
          orElse: () => NetworkKind.tailscale,
        ),
        sunshinePort: json['sunshinePort'] as int? ?? 47989,
        webPort: json['webPort'] as int? ?? 47990,
        appName: json['appName'] as String? ?? 'Desktop',
        appId: json['appId'] as int?,
        hostUuid: json['hostUuid'] as String?,
        paired: json['paired'] as bool? ?? false,
        wakeMac: json['wakeMac'] as String?,
        wakeRelayAddress: json['wakeRelayAddress'] as String?,
        group: (json['group'] as String? ?? '').trim(),
        nickname: (json['nickname'] as String? ?? '').trim(),
        lastSeen: json['lastSeen'] == null
            ? null
            : DateTime.tryParse(json['lastSeen'] as String),
      );

  final String id;
  String name;
  String meshAddress;
  NetworkKind network;

  /// NVHTTP plaintext port. Sunshine derives every port from this base
  /// (default 47989): /serverinfo and /pair live here; TLS is base-5
  /// (47984) and is read from /serverinfo's HttpsPort, never assumed.
  int sunshinePort;

  /// Sunshine web UI / API port (base+1, default 47990).
  int webPort;

  /// App to stream, by name for moonlight-qt (`stream <host> "Desktop"`).
  String appName;

  /// Numeric app id from /applist, when available after in-app pairing.
  int? appId;

  /// Host UUID recorded during in-app pairing, when available.
  String? hostUuid;

  final String? wakeMac;
  final String? wakeRelayAddress;
  final String group;
  final String nickname;

  String get displayName => nickname.isEmpty ? name : nickname;

  bool paired;
  DateTime? lastSeen;

  /// Plaintext NVHTTP base URL, e.g. http://100.64.0.5:47989
  String get nvhttpBase => 'http://$meshAddress:$sunshinePort';

  /// Sunshine web UI base URL, e.g. https://100.64.0.5:47990
  String get webBase => 'https://$meshAddress:$webPort';

  /// TLS NVHTTP base URL. The port is a fallback only; PairingService
  /// replaces it with the HttpsPort read from /serverinfo when known.
  String get tlsBase => 'https://$meshAddress:${sunshinePort - 5}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'meshAddress': meshAddress,
        'network': network.name,
        'sunshinePort': sunshinePort,
        'webPort': webPort,
        'appName': appName,
        'appId': appId,
        'hostUuid': hostUuid,
        'paired': paired,
        if (wakeMac != null) 'wakeMac': wakeMac,
        if (wakeRelayAddress != null) 'wakeRelayAddress': wakeRelayAddress,
        if (group.isNotEmpty) 'group': group,
        if (nickname.isNotEmpty) 'nickname': nickname,
        'lastSeen': lastSeen?.toIso8601String(),
      };

  Device copyWith({bool? paired, int? appId, String? hostUuid}) => Device(
        id: id,
        name: name,
        meshAddress: meshAddress,
        network: network,
        sunshinePort: sunshinePort,
        webPort: webPort,
        appName: appName,
        appId: appId ?? this.appId,
        hostUuid: hostUuid ?? this.hostUuid,
        paired: paired ?? this.paired,
        lastSeen: lastSeen,
        wakeMac: wakeMac,
        wakeRelayAddress: wakeRelayAddress,
        group: group,
        nickname: nickname,
      );
}

enum NetworkKind {
  tailscale,
  zerotier,
  natpierce;

  static NetworkKind? detect(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) return null;
    final bytes = ip.rawAddress;
    if (bytes[0] == 10) return natpierce;
    if (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127) return tailscale;
    return null;
  }
}

extension NetworkKindLabel on NetworkKind {
  String get label => switch (this) {
        NetworkKind.tailscale => 'Tailscale',
        NetworkKind.zerotier => 'ZeroTier',
        NetworkKind.natpierce => '皎月连',
      };
}

// Per-application tunnels: "config1 for app1, config2 for app2".

/// One application pinned to one location.
///
/// Several of these run at once inside a single core rather than as separate
/// tunnels. That is not a shortcut — it is the only way this works: a machine
/// has one routing table and one TUN device, so "two VPN connections at once"
/// is really one core with two outbounds and a rule that says which process
/// gets which. Stopping "one connection" means dropping its rule, and the
/// other apps never notice.
class AppBinding {
  const AppBinding({
    required this.id,
    required this.process,
    required this.serverUid,
    this.label = '',
    this.enabled = true,
  });

  /// Stable id so the UI can address a row.
  final String id;

  /// Executable name as the OS reports it — `chrome.exe`, `firefox`. sing-box
  /// matches on exactly this.
  final String process;

  /// [ServerConfig.uid] of the location this app should use.
  final String serverUid;

  /// What to call it in the list; falls back to the process name.
  final String label;

  /// A disabled binding stays in the list but stops routing — this is "stop
  /// this one connection" without forgetting the setup.
  final bool enabled;

  String get displayLabel => label.trim().isEmpty ? process : label.trim();

  AppBinding copyWith({
    String? process,
    String? serverUid,
    String? label,
    bool? enabled,
  }) =>
      AppBinding(
        id: id,
        process: process ?? this.process,
        serverUid: serverUid ?? this.serverUid,
        label: label ?? this.label,
        enabled: enabled ?? this.enabled,
      );

  factory AppBinding.fromJson(Map<String, dynamic> j) => AppBinding(
        id: (j['id'] ?? '') as String,
        process: (j['process'] ?? '') as String,
        serverUid: (j['server_uid'] ?? '') as String,
        label: (j['label'] ?? '') as String,
        enabled: (j['enabled'] ?? true) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'process': process,
        'server_uid': serverUid,
        'label': label,
        'enabled': enabled,
      };
}

String newBindingId() =>
    'bind_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

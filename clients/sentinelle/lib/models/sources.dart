// Where the locations in the picker come from.
//
// The app used to have exactly one: a single panel login. It now merges three
// kinds of source, and everything downstream — the grouped list, the map, the
// refresh loop — works off this one abstraction rather than special-casing
// "the account" against "the rest".

import 'models.dart';

enum SourceKind {
  /// A Bridge panel the user signed into. Has a profile, a quota and a
  /// heartbeat.
  account,

  /// A subscription URL from someone else's panel. Just a list of configs.
  subscription,

  /// Configs the user pasted in themselves.
  manual,
}

extension SourceKindLabel on SourceKind {
  String get label => switch (this) {
        SourceKind.account => 'Account',
        SourceKind.subscription => 'Subscription',
        SourceKind.manual => 'Imported',
      };
}

/// One account, subscription or clipboard import.
///
/// Deliberately a single class with a [kind] rather than a hierarchy: it is
/// persisted as one JSON list, and every screen wants to treat the three the
/// same way right up until it needs the quota.
class LocationSource {
  const LocationSource({
    required this.id,
    required this.kind,
    this.label = '',
    this.baseUrl = '',
    this.token,
    this.username = '',
    this.password = '',
    this.url = '',
    this.enabled = true,
    this.pinned = false,
    this.lastRefresh,
    this.error,
  });

  /// Stable across restarts; forms the prefix of every [ServerConfig.uid] it
  /// produces, so renames and hand-placed locations stay attached.
  final String id;
  final SourceKind kind;

  /// What the user sees as the group heading. Falls back to something sensible
  /// when empty — see [displayLabel].
  final String label;

  // ── Accounts ───────────────────────────────────────────────────────────────
  final String baseUrl;
  final String? token;
  final String username;

  /// Kept so a session that expires can be renewed without asking again. Same
  /// bargain the single-account build already made with "remember me".
  final String password;

  // ── Subscriptions ──────────────────────────────────────────────────────────
  final String url;

  /// A disabled source stays in the list but contributes no locations.
  final bool enabled;

  /// Puts this source's locations at the top of the picker, ahead of every
  /// unpinned one.
  ///
  /// Sources are otherwise listed in the order they were added, which is an
  /// accident of history rather than a statement about which account someone
  /// actually uses. Pinning is per source rather than a full manual ordering
  /// because the question people have is "show me my own account first", not
  /// "let me rank six subscriptions".
  final bool pinned;

  final DateTime? lastRefresh;

  /// Set when the last refresh failed, so the row can explain itself instead
  /// of silently going empty.
  final String? error;

  bool get isAccount => kind == SourceKind.account;

  String get displayLabel {
    if (label.trim().isNotEmpty) return label.trim();
    return switch (kind) {
      SourceKind.account =>
        username.isNotEmpty ? '$username · ${_host(baseUrl)}' : _host(baseUrl),
      SourceKind.subscription => _host(url),
      SourceKind.manual => 'Imported configs',
    };
  }

  static String _host(String raw) {
    final u = Uri.tryParse(raw);
    if (u == null || u.host.isEmpty) return raw;
    return u.host;
  }

  LocationSource copyWith({
    String? label,
    String? baseUrl,
    Object? token = _unset,
    String? username,
    String? password,
    String? url,
    bool? enabled,
    bool? pinned,
    Object? lastRefresh = _unset,
    Object? error = _unset,
  }) =>
      LocationSource(
        id: id,
        kind: kind,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        token: token == _unset ? this.token : token as String?,
        username: username ?? this.username,
        password: password ?? this.password,
        url: url ?? this.url,
        enabled: enabled ?? this.enabled,
        pinned: pinned ?? this.pinned,
        lastRefresh:
            lastRefresh == _unset ? this.lastRefresh : lastRefresh as DateTime?,
        error: error == _unset ? this.error : error as String?,
      );

  static const _unset = Object();

  factory LocationSource.fromJson(Map<String, dynamic> j) => LocationSource(
        id: (j['id'] ?? '') as String,
        kind: SourceKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => SourceKind.subscription,
        ),
        label: (j['label'] ?? '') as String,
        baseUrl: (j['base_url'] ?? '') as String,
        token: j['token'] as String?,
        username: (j['username'] ?? '') as String,
        password: (j['password'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        enabled: (j['enabled'] ?? true) as bool,
        pinned: (j['pinned'] ?? false) as bool,
        lastRefresh: DateTime.tryParse((j['last_refresh'] ?? '') as String),
        error: j['error'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'label': label,
        'base_url': baseUrl,
        'token': token,
        'username': username,
        'password': password,
        'url': url,
        'enabled': enabled,
        'pinned': pinned,
        'last_refresh': lastRefresh?.toIso8601String(),
        'error': error,
      };
}

/// Generates ids that are unique for this installation without pulling in a
/// uuid package for four calls.
String newSourceId(SourceKind kind) =>
    '${kind.name.substring(0, 3)}_'
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

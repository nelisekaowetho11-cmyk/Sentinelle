import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/models.dart';
import '../models/sources.dart';
import 'api.dart';
import 'share_link.dart';
import 'storage.dart';
import 'subscription_service.dart';

/// Owns every place locations come from and presents them as one list.
///
/// The app used to be built around a single panel login. Rather than bolt
/// subscriptions and pasted configs on beside it, everything — including that
/// original account — is now a [LocationSource], and the rest of the app only
/// ever sees the merged result. That is what makes "no account at all, just my
/// own configs" work without a second code path.
class SourceRegistry {
  SourceRegistry({SubscriptionService? subscriptions})
      : _subs = subscriptions ?? SubscriptionService();

  final SubscriptionService _subs;

  final List<LocationSource> _sources = [];
  final Map<String, List<ServerConfig>> _servers = {};
  final Map<String, Profile> _profiles = {};
  final Map<String, ClientOrigin> _origins = {};
  final Map<String, SubscriptionUsage> _usage = {};
  final Map<String, PanelApi> _apis = {};
  final Map<String, String?> _blocked = {};

  /// Every source, pinned ones first.
  ///
  /// One list, one order: the picker's group headings, the map and [servers]
  /// all read this, so a pinned account leads everywhere at once rather than
  /// only in the place the sort was applied.
  List<LocationSource> get sources => List.unmodifiable(_ordered);

  /// Insertion order, which is what is persisted and what the Sources screen
  /// itself shows. Pinning is a view concern, not a re-shuffling of the file.
  List<LocationSource> get sourcesInAddedOrder => List.unmodifiable(_sources);

  List<LocationSource> get _ordered {
    // Stable: only the pinned flag moves anything, so two pinned sources keep
    // the order the user added them in.
    final pinned = <LocationSource>[];
    final rest = <LocationSource>[];
    for (final s in _sources) {
      (s.pinned ? pinned : rest).add(s);
    }
    return [...pinned, ...rest];
  }

  List<LocationSource> get accounts =>
      _ordered.where((s) => s.kind == SourceKind.account).toList();

  Profile? profileOf(String sourceId) => _profiles[sourceId];
  ClientOrigin? originOf(String sourceId) => _origins[sourceId];
  SubscriptionUsage? usageOf(String sourceId) => _usage[sourceId];
  PanelApi? apiOf(String sourceId) => _apis[sourceId];
  String? blockedReasonOf(String sourceId) => _blocked[sourceId];

  LocationSource? sourceById(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Servers for one source, with the user's renames and pins already applied.
  List<ServerConfig> serversOf(String sourceId) =>
      (_servers[sourceId] ?? const []).map(_applyOverrides).toList();

  /// Every enabled source's servers, in source order — pinned sources first.
  ///
  /// Order matters: it is what the grouped picker renders, and a stable order
  /// keeps the list from reshuffling under the user on every refresh.
  List<ServerConfig> get servers => [
        for (final source in _ordered)
          if (source.enabled) ...serversOf(source.id),
      ];

  /// The account whose profile drives the quota display. The first one added
  /// wins; with no accounts at all there is simply no quota to show.
  LocationSource? get primaryAccount =>
      accounts.isEmpty ? null : accounts.first;

  bool get hasAccount => accounts.isNotEmpty;
  bool get isEmpty => servers.isEmpty;

  // ── Overrides ──────────────────────────────────────────────────────────────

  Map<String, String> _aliases = const {};
  Map<String, GeoOverride> _geo = const {};

  ServerConfig _applyOverrides(ServerConfig s) {
    final alias = _aliases[s.uid];
    final geo = _geo[s.uid];
    if (alias == null && geo == null) return s;
    return s.copyWith(
      alias: alias ?? s.alias,
      country: geo?.country ?? s.country,
      lat: geo?.lat ?? s.lat,
      lon: geo?.lon ?? s.lon,
      geoIsManual: geo != null,
    );
  }

  Future<void> setAlias(String uid, String? name) async {
    await Storage.I.setAlias(uid, name);
    _aliases = Storage.I.aliases;
  }

  Future<void> setGeo(String uid, GeoOverride? geo) async {
    await Storage.I.setGeoOverride(uid, geo);
    _geo = Storage.I.geoOverrides;
  }

  // ── Load ───────────────────────────────────────────────────────────────────

  /// Reads everything back from disk, migrating a pre-multi-account install on
  /// the way.
  Future<void> load() async {
    _aliases = Storage.I.aliases;
    _geo = Storage.I.geoOverrides;

    _sources
      ..clear()
      ..addAll(Storage.I.sources);

    if (_sources.isEmpty) await _migrateLegacyAccount();

    _servers
      ..clear()
      ..addAll(Storage.I.cachedSourceServers);
    _profiles
      ..clear()
      ..addAll(Storage.I.cachedSourceProfiles);

    for (final s in _sources) {
      if (s.kind == SourceKind.account) _buildApi(s);
    }
  }

  /// The single-account build stored its panel in loose keys. Fold that into a
  /// source so an existing user keeps their account — and their servers —
  /// across the upgrade instead of being logged out.
  Future<void> _migrateLegacyAccount() async {
    final url = Storage.I.baseUrl;
    final token = Storage.I.token;
    if (url.isEmpty || token == null || token.isEmpty) return;

    final source = LocationSource(
      id: newSourceId(SourceKind.account),
      kind: SourceKind.account,
      baseUrl: url,
      token: token,
      username: Storage.I.savedUsername,
      password: Storage.I.savedPassword,
    );
    _sources.add(source);
    await Storage.I.setSources(_sources);

    // The cached servers carry the old panel ids; re-tagging them under the
    // new source keeps the picker populated until the first refresh lands.
    final legacy = Storage.I.cachedServers;
    if (legacy.isNotEmpty) {
      _servers[source.id] = [
        for (final s in legacy)
          ServerConfig.fromJson(s.toJson()..remove('uid'),
              sourceId: source.id),
      ];
      await Storage.I.setCachedSourceServers(_servers);
    }
    final profile = Storage.I.cachedProfile;
    if (profile != null) {
      _profiles[source.id] = profile;
      await Storage.I.setCachedSourceProfiles(_profiles);
    }
  }

  void _buildApi(LocationSource s) {
    _apis[s.id]?.close();
    _apis[s.id] = PanelApi(
      baseUrl: s.baseUrl,
      token: s.token,
      sourceId: s.id,
    );
  }

  // ── Adding ─────────────────────────────────────────────────────────────────

  /// Why the last [addAccount] failed, when the panel said more than a
  /// sentence's worth. The device-limit refusal carries the devices holding the
  /// slots, which is what lets the sign-in screen offer to free one.
  ApiException? lastAuthFailure;

  /// The address [addAccount] settled on after probing schemes and following
  /// redirects. Kept so a follow-up call — releasing a device slot, say — talks
  /// to the same origin instead of probing again.
  String lastResolvedUrl = '';

  /// Signs into a panel and adds it. Returns null on success, an error message
  /// otherwise.
  Future<String?> addAccount(
    String baseUrl,
    String username,
    String password,
  ) async {
    // Checked before the round-trip: a build that forbids cleartext should say
    // so immediately rather than spend a timeout failing to reach a scheme it
    // was never going to use.
    final refusal = PanelApi.plaintextRefusal(baseUrl);
    if (refusal != null) return refusal;

    final url = await PanelApi.resolveBaseUrl(baseUrl);
    lastResolvedUrl = url;
    lastAuthFailure = null;
    final id = newSourceId(SourceKind.account);
    final api = PanelApi(baseUrl: url, sourceId: id);

    try {
      final res = await api.login(username.trim(), password);
      if (_sources.any((s) =>
          s.kind == SourceKind.account &&
          s.baseUrl == api.baseUrl &&
          s.username == username.trim())) {
        api.close();
        return 'That account is already signed in.';
      }

      final source = LocationSource(
        id: id,
        kind: SourceKind.account,
        baseUrl: api.baseUrl,
        token: res.token,
        username: username.trim(),
        password: password,
        lastRefresh: DateTime.now(),
      );
      _sources.add(source);
      _apis[id] = api;
      _absorbSession(id, res.session);
      await _persist();
      lastResolvedUrl = api.baseUrl;
      return null;
    } on ApiException catch (e) {
      lastResolvedUrl = api.baseUrl;
      lastAuthFailure = e;
      api.close();
      return e.message;
    }
  }

  /// Adds a subscription from another panel. Works with or without an account.
  Future<String?> addSubscription(String url, {String label = ''}) async {
    // A subscription link carries a token that is as good as a password, so it
    // is held to the same standard as the sign-in.
    final refusal = PanelApi.plaintextRefusal(url);
    if (refusal != null) return refusal;

    final id = newSourceId(SourceKind.subscription);
    final res = await _subs.fetch(url, sourceId: id);
    if (!res.ok) return res.error;

    _sources.add(LocationSource(
      id: id,
      kind: SourceKind.subscription,
      label: label.trim().isNotEmpty ? label.trim() : (res.title ?? ''),
      url: url.trim(),
      lastRefresh: DateTime.now(),
    ));
    _servers[id] = res.servers;
    if (res.usage != null) _usage[id] = res.usage!;
    await _persist();
    return null;
  }

  /// Imports one or more configs from pasted text.
  ///
  /// Repeated imports collect into a single "Imported configs" source rather
  /// than littering the list with a group per paste.
  Future<ImportOutcome> addManual(String text, {String? label}) async {
    var source = _sources.where((s) => s.kind == SourceKind.manual).firstOrNull;
    final id = source?.id ?? newSourceId(SourceKind.manual);

    final parsed = ShareLink.parseMany(text, sourceId: id);
    if (parsed.isEmpty) {
      return ImportOutcome(
        added: 0,
        failures: parsed.failures,
        error: parsed.failures.isEmpty
            ? 'No configs found in that text.'
            : 'Nothing could be imported.',
      );
    }

    if (source == null) {
      source = LocationSource(
        id: id,
        kind: SourceKind.manual,
        label: label ?? '',
        lastRefresh: DateTime.now(),
      );
      _sources.add(source);
    }

    // Re-pasting a config the user already has updates it in place; a
    // duplicate row for the same endpoint helps nobody.
    final existing = [...(_servers[id] ?? const <ServerConfig>[])];
    var added = 0;
    for (final s in parsed.servers) {
      final at = existing.indexWhere((e) => e.uid == s.uid);
      if (at >= 0) {
        existing[at] = s;
      } else {
        existing.add(s);
        added++;
      }
    }
    _servers[id] = existing;
    _touch(id);
    await _persist();

    return ImportOutcome(
      added: added,
      updated: parsed.count - added,
      failures: parsed.failures,
    );
  }

  // ── Removing ───────────────────────────────────────────────────────────────

  Future<void> remove(String sourceId) => removeMany([sourceId]);

  Future<void> removeMany(Iterable<String> ids) async {
    for (final id in ids) {
      final source = sourceById(id);
      if (source == null) continue;
      // Best effort: a panel that cannot be reached should not stop the user
      // getting the account out of their app.
      final api = _apis.remove(id);
      // Tell the panel first, or this device keeps holding a slot against the
      // account's limit until it ages out — a signed-out laptop locking a phone
      // out for ten minutes was exactly that.
      if (api != null && source.kind == SourceKind.account) {
        await api.logout();
      }
      api?.close();
      _sources.removeWhere((s) => s.id == id);
      _servers.remove(id);
      _profiles.remove(id);
      _origins.remove(id);
      _usage.remove(id);
      _blocked.remove(id);
      await Storage.I.forgetSource(id);
    }
    _aliases = Storage.I.aliases;
    _geo = Storage.I.geoOverrides;
    await _persist();
  }

  Future<void> removeAll() => removeMany(_sources.map((s) => s.id).toList());

  Future<void> setEnabled(String sourceId, bool enabled) async {
    _replace(sourceId, (s) => s.copyWith(enabled: enabled));
    await _persist();
  }

  Future<void> rename(String sourceId, String label) async {
    _replace(sourceId, (s) => s.copyWith(label: label));
    await _persist();
  }

  /// Sends this source's locations to the top of the picker, or puts them back
  /// where they were added.
  Future<void> setPinned(String sourceId, bool pinned) async {
    _replace(sourceId, (s) => s.copyWith(pinned: pinned));
    await _persist();
  }

  // ── Refreshing ─────────────────────────────────────────────────────────────

  /// Refreshes every enabled source. Failures are recorded on the source
  /// rather than thrown: one dead subscription must not stop the others.
  Future<void> refreshAll() async {
    await Future.wait([
      for (final s in _sources)
        if (s.enabled) refresh(s.id),
    ]);
  }

  Future<void> refresh(String sourceId) async {
    final source = sourceById(sourceId);
    if (source == null) return;
    switch (source.kind) {
      case SourceKind.account:
        await _refreshAccount(source);
      case SourceKind.subscription:
        await _refreshSubscription(source);
      case SourceKind.manual:
        // Nothing to fetch — these live entirely on the device.
        break;
    }
    await _persist();
  }

  Future<void> _refreshAccount(LocationSource source) async {
    var api = _apis[source.id];
    if (api == null) {
      _buildApi(source);
      api = _apis[source.id]!;
    }
    try {
      _absorbSession(source.id, await api.session());
      _replace(source.id,
          (s) => s.copyWith(error: null, lastRefresh: DateTime.now()));
      if (api.baseUrl != source.baseUrl) {
        _replace(source.id, (s) => s.copyWith(baseUrl: api!.baseUrl));
      }
    } on ApiException catch (e) {
      if (e.isAuthError) {
        // Sessions expire. Renew silently with the saved credentials before
        // bothering the user, exactly as the single-account build did.
        if (await _reauthenticate(source)) return;
        _replace(
            source.id, (s) => s.copyWith(token: null, error: 'Signed out'));
      } else {
        _replace(source.id, (s) => s.copyWith(error: e.message));
      }
    }
  }

  Future<bool> _reauthenticate(LocationSource source) async {
    if (source.username.isEmpty || source.password.isEmpty) return false;
    final api = _apis[source.id];
    if (api == null) return false;
    try {
      final res = await api.login(source.username, source.password);
      _replace(
        source.id,
        (s) => s.copyWith(
            token: res.token, error: null, lastRefresh: DateTime.now()),
      );
      _absorbSession(source.id, res.session);
      return true;
    } on ApiException {
      return false;
    }
  }

  Future<void> _refreshSubscription(LocationSource source) async {
    final res = await _subs.fetch(source.url, sourceId: source.id);
    if (!res.ok) {
      _replace(source.id, (s) => s.copyWith(error: res.error));
      return;
    }
    _servers[source.id] = res.servers;
    if (res.usage != null) _usage[source.id] = res.usage!;
    _replace(
      source.id,
      (s) => s.copyWith(
        error: null,
        lastRefresh: DateTime.now(),
        label: s.label.isEmpty ? (res.title ?? '') : s.label,
      ),
    );
  }

  void _absorbSession(String sourceId, ClientSession session) {
    _servers[sourceId] = session.servers;
    _profiles[sourceId] = session.profile;
    _blocked[sourceId] = session.blockedReason;
    if (!session.origin.isEmpty) _origins[sourceId] = session.origin;
  }

  /// Records a heartbeat's fresher profile without a full session fetch.
  void applyHeartbeat(
    String sourceId, {
    required Profile profile,
    String? blockedReason,
  }) {
    _profiles[sourceId] = profile;
    _blocked[sourceId] = blockedReason;
    unawaited(Storage.I.setCachedSourceProfiles(_profiles));
  }

  void _replace(
      String sourceId, LocationSource Function(LocationSource) update) {
    final i = _sources.indexWhere((s) => s.id == sourceId);
    if (i < 0) return;
    _sources[i] = update(_sources[i]);
  }

  void _touch(String sourceId) =>
      _replace(sourceId, (s) => s.copyWith(lastRefresh: DateTime.now()));

  Future<void> _persist() async {
    await Storage.I.setSources(_sources);
    await Storage.I.setCachedSourceServers(_servers);
    await Storage.I.setCachedSourceProfiles(_profiles);
  }

  /// Installs a source and its data directly, with no network and no disk.
  ///
  /// Tests used to assign `state.servers` and `state.profile`; those are
  /// derived from the registry now, so this is the seam that replaces them.
  @visibleForTesting
  void seed({
    required String id,
    SourceKind kind = SourceKind.account,
    String label = '',
    List<ServerConfig> servers = const [],
    Profile? profile,
    ClientOrigin? origin,
    String? blockedReason,
  }) {
    if (!_sources.any((s) => s.id == id)) {
      _sources.add(LocationSource(id: id, kind: kind, label: label));
    }
    _servers[id] = servers;
    if (profile != null) _profiles[id] = profile;
    if (origin != null) _origins[id] = origin;
    _blocked[id] = blockedReason;
  }

  void dispose() {
    for (final api in _apis.values) {
      api.close();
    }
    _apis.clear();
    _subs.close();
  }
}

/// What came of pasting a blob of configs.
class ImportOutcome {
  const ImportOutcome({
    required this.added,
    this.updated = 0,
    this.failures = const [],
    this.error,
  });

  final int added;
  final int updated;
  final List<String> failures;
  final String? error;

  bool get ok => error == null;

  String get summary {
    if (error != null) return error!;
    final parts = <String>[
      if (added > 0) '$added added',
      if (updated > 0) '$updated updated',
      if (failures.isNotEmpty) '${failures.length} skipped',
    ];
    return parts.isEmpty ? 'Nothing changed' : parts.join(' · ');
  }
}

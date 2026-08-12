import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../branding.dart';
import '../models/app_binding.dart';
import '../models/models.dart';
import '../models/sources.dart';
import '../theme.dart' show AppThemeMode;
import 'routing.dart';

/// Persisted app state: credentials, last session snapshot and user settings.
class Storage {
  Storage._(this._p);
  final SharedPreferences _p;

  static Storage? _instance;
  static Storage get I => _instance!;

  /// Null until [init] has run. Lets code that merely *prefers* persistence
  /// — the device identity, for one — work before or without it, instead of
  /// exploding on a null assertion.
  static Storage? get maybeI => _instance;

  static Future<Storage> init() async {
    _instance ??= Storage._(await SharedPreferences.getInstance());
    return _instance!;
  }

  /// Drops the cached singleton so the next [init] picks up fresh preferences.
  ///
  /// Without this a test's writes survive into the next test: `init` only
  /// builds the instance once, so re-mocking SharedPreferences alone changes
  /// nothing.
  @visibleForTesting
  static void resetForTests() => _instance = null;

  // ── Account ────────────────────────────────────────────────────────────────
  static const _kBaseUrl = 'panel_base_url';
  static const _kToken = 'auth_token';
  static const _kUsername = 'saved_username';
  static const _kPassword = 'saved_password';
  static const _kRemember = 'remember_me';
  static const _kProfile = 'cached_profile';
  static const _kServers = 'cached_servers';
  static const _kBrand = 'brand';

  String get baseUrl => _p.getString(_kBaseUrl) ?? '';
  Future<void> setBaseUrl(String v) => _p.setString(_kBaseUrl, v);

  String? get token => _p.getString(_kToken);
  Future<void> setToken(String? v) =>
      v == null ? _p.remove(_kToken) : _p.setString(_kToken, v);

  String get savedUsername => _p.getString(_kUsername) ?? '';
  Future<void> setSavedUsername(String v) => _p.setString(_kUsername, v);

  String get savedPassword => _p.getString(_kPassword) ?? '';
  Future<void> setSavedPassword(String v) => _p.setString(_kPassword, v);

  bool get rememberMe => _p.getBool(_kRemember) ?? true;
  Future<void> setRememberMe(bool v) => _p.setBool(_kRemember, v);

  String get brand => _p.getString(_kBrand) ?? kAppName;
  Future<void> setBrand(String v) => _p.setString(_kBrand, v);

  Profile? get cachedProfile {
    final s = _p.getString(_kProfile);
    if (s == null) return null;
    try {
      return Profile.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> setCachedProfile(Profile? p) => p == null
      ? _p.remove(_kProfile)
      : _p.setString(_kProfile, jsonEncode(p.toJson()));

  List<ServerConfig> get cachedServers {
    final s = _p.getString(_kServers);
    if (s == null) return const [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => ServerConfig.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setCachedServers(List<ServerConfig> v) =>
      _p.setString(_kServers, jsonEncode(v.map((e) => e.toJson()).toList()));

  Future<void> clearAccount() async {
    await _p.remove(_kToken);
    await _p.remove(_kProfile);
    await _p.remove(_kServers);
    if (!rememberMe) {
      await _p.remove(_kUsername);
      await _p.remove(_kPassword);
    }
  }

  // ── Preferences ────────────────────────────────────────────────────────────
  static const _kLastServer = 'last_server_id';
  static const _kAutoConnect = 'auto_connect';
  static const _kBypassLan = 'bypass_lan';
  static const _kBlockAds = 'block_ads';
  static const _kDns = 'dns_servers';
  static const _kSocksPort = 'socks_port';
  static const _kHttpPort = 'http_port';
  static const _kSystemProxy = 'system_proxy';
  static const _kSplitApps = 'split_apps';
  static const _kSplitMode = 'split_mode';
  static const _kTunnelRules = 'tunnel_rules';
  static const _kBypassRules = 'bypass_rules';
  static const _kCorePath = 'xray_core_path';
  static const _kStartMin = 'start_minimised';
  static const _kVpnMode = 'tunnel_mode_vpn';
  static const _kCloseToTray = 'close_to_tray';
  static const _kKillSwitch = 'kill_switch';
  static const _kFavourites = 'favourite_servers';
  static const _kDetailedHome = 'home_detailed';
  static const _kSidebarCollapsed = 'sidebar_collapsed';
  static const _kDnsGuard = 'guard_dns';
  static const _kIpv6Guard = 'guard_ipv6';
  static const _kWebRtcGuard = 'guard_webrtc';
  static const _kTimezoneGuard = 'guard_timezone';
  static const _kLanGuard = 'guard_lan';
  static const _kQuicGuard = 'guard_quic';
  static const _kBindings = 'app_bindings';
  static const _kDeviceId = 'device_id';
  static const _kDeviceName = 'device_name';
  static const _kThemeMode = 'theme_mode';
  static const _kLaunchAtLogin = 'launch_at_login';

  int? get lastServerId => _p.getInt(_kLastServer);
  Future<void> setLastServerId(int? v) =>
      v == null ? _p.remove(_kLastServer) : _p.setInt(_kLastServer, v);

  bool get autoConnect => _p.getBool(_kAutoConnect) ?? false;
  Future<void> setAutoConnect(bool v) => _p.setBool(_kAutoConnect, v);

  bool get bypassLan => _p.getBool(_kBypassLan) ?? true;
  Future<void> setBypassLan(bool v) => _p.setBool(_kBypassLan, v);

  bool get blockAds => _p.getBool(_kBlockAds) ?? false;
  Future<void> setBlockAds(bool v) => _p.setBool(_kBlockAds, v);

  String get dnsServers => _p.getString(_kDns) ?? '1.1.1.1, 8.8.8.8';
  Future<void> setDnsServers(String v) => _p.setString(_kDns, v);

  int get socksPort => _p.getInt(_kSocksPort) ?? 10808;
  Future<void> setSocksPort(int v) => _p.setInt(_kSocksPort, v);

  int get httpPort => _p.getInt(_kHttpPort) ?? 10809;
  Future<void> setHttpPort(int v) => _p.setInt(_kHttpPort, v);

  bool get systemProxy => _p.getBool(_kSystemProxy) ?? true;
  Future<void> setSystemProxy(bool v) => _p.setBool(_kSystemProxy, v);

  /// Apps named in the split list: Android package names, desktop executable
  /// names (`chrome.exe`).
  List<String> get splitApps =>
      (_p.getStringList(_kSplitApps) ?? const <String>[]);
  Future<void> setSplitApps(List<String> v) => _p.setStringList(_kSplitApps, v);

  /// How [splitApps] is interpreted.
  SplitMode get splitMode =>
      SplitMode.values.byName(_p.getString(_kSplitMode) ?? SplitMode.all.name);
  Future<void> setSplitMode(SplitMode v) => _p.setString(_kSplitMode, v.name);

  /// Domains/IPs forced through the tunnel even when the default is direct.
  List<String> get tunnelRules =>
      (_p.getStringList(_kTunnelRules) ?? const <String>[]);
  Future<void> setTunnelRules(List<String> v) =>
      _p.setStringList(_kTunnelRules, v);

  /// Domains/IPs that always bypass the tunnel.
  List<String> get bypassRules =>
      (_p.getStringList(_kBypassRules) ?? const <String>[]);
  Future<void> setBypassRules(List<String> v) =>
      _p.setStringList(_kBypassRules, v);

  String get corePath => _p.getString(_kCorePath) ?? '';
  Future<void> setCorePath(String v) => _p.setString(_kCorePath, v);

  bool get startMinimised => _p.getBool(_kStartMin) ?? false;
  Future<void> setStartMinimised(bool v) => _p.setBool(_kStartMin, v);

  /// Full-tunnel mode.
  ///
  /// On desktop this is a TUN device and needs administrator rights, so proxy
  /// mode is the default there. On Android it is the ordinary VpnService
  /// tunnel and needs nothing special, so it is the default instead —
  /// proxy-only is the deliberate choice on that platform.
  bool get vpnMode => _p.getBool(_kVpnMode) ?? Platform.isAndroid;
  Future<void> setVpnMode(bool v) => _p.setBool(_kVpnMode, v);

  /// Desktop only — closing the window hides to the tray instead of quitting.
  bool get closeToTray => _p.getBool(_kCloseToTray) ?? false;
  Future<void> setCloseToTray(bool v) => _p.setBool(_kCloseToTray, v);

  /// Hold traffic closed when the tunnel drops on its own, instead of letting
  /// it fall back to the open connection. On by default: an unnoticed leak is
  /// worse than an obvious outage, which is the whole point of the feature.
  bool get killSwitch => _p.getBool(_kKillSwitch) ?? true;
  Future<void> setKillSwitch(bool v) => _p.setBool(_kKillSwitch, v);

  /// Server ids the user starred, as strings because SharedPreferences has no
  /// int-list type.
  List<int> get favourites => (_p.getStringList(_kFavourites) ?? const [])
      .map(int.tryParse)
      .whereType<int>()
      .toList();

  Future<void> setFavourites(List<int> v) =>
      _p.setStringList(_kFavourites, v.map((e) => '$e').toList());

  bool isFavourite(int id) => favourites.contains(id);

  Future<void> toggleFavourite(int id) async {
    final list = favourites;
    list.contains(id) ? list.remove(id) : list.add(id);
    await setFavourites(list);
  }

  /// Connect page layout. The detailed view — live map, security panel, live
  /// speeds — is the default; the simple view is the single-orb page.
  bool get detailedHome => _p.getBool(_kDetailedHome) ?? true;
  Future<void> setDetailedHome(bool v) => _p.setBool(_kDetailedHome, v);

  /// Desktop only — the left menu shrinks to icons so it stops taking a fifth
  /// of the window.
  bool get sidebarCollapsed => _p.getBool(_kSidebarCollapsed) ?? false;
  Future<void> setSidebarCollapsed(bool v) =>
      _p.setBool(_kSidebarCollapsed, v);

  /// Light, dark, or whatever the operating system is set to.
  ///
  /// Defaults to following the system: the app is dark by design, but a machine
  /// deliberately set to light mode is the user telling us something.
  AppThemeMode get themeMode => AppThemeMode.parse(_p.getString(_kThemeMode));
  Future<void> setThemeMode(AppThemeMode v) => _p.setString(_kThemeMode, v.name);

  /// Desktop only — launch when the user signs in.
  bool get launchAtLogin => _p.getBool(_kLaunchAtLogin) ?? false;
  Future<void> setLaunchAtLogin(bool v) => _p.setBool(_kLaunchAtLogin, v);

  // ── Leak guards ────────────────────────────────────────────────────────────

  /// Force every DNS query through the tunnel and refuse plaintext lookups
  /// that try to go around it.
  bool get dnsGuard => _p.getBool(_kDnsGuard) ?? true;
  Future<void> setDnsGuard(bool v) => _p.setBool(_kDnsGuard, v);

  /// Drop IPv6 rather than let it escape a v4-only tunnel.
  bool get ipv6Guard => _p.getBool(_kIpv6Guard) ?? true;
  Future<void> setIpv6Guard(bool v) => _p.setBool(_kIpv6Guard, v);

  /// Block the STUN/TURN discovery WebRTC uses to learn the real address.
  bool get webRtcGuard => _p.getBool(_kWebRtcGuard) ?? true;
  Future<void> setWebRtcGuard(bool v) => _p.setBool(_kWebRtcGuard, v);

  /// Warn when the device clock does not match the exit country. Reporting
  /// only — nothing in a VPN can change the system timezone — so it defaults
  /// on: an unnoticed mismatch is exactly the kind of leak this catches.
  bool get timezoneGuard => _p.getBool(_kTimezoneGuard) ?? true;
  Future<void> setTimezoneGuard(bool v) => _p.setBool(_kTimezoneGuard, v);

  /// Drop mDNS / LLMNR / SSDP / NetBIOS, which broadcast the device's real
  /// hostname and addresses to whatever network it is sitting on.
  bool get lanGuard => _p.getBool(_kLanGuard) ?? true;
  Future<void> setLanGuard(bool v) => _p.setBool(_kLanGuard, v);

  /// Refuse QUIC so browsers fall back to TCP.
  ///
  /// Off by default: it costs real speed on a tunnel that carries UDP well,
  /// and it is a mitigation for a specific failure rather than a leak in its
  /// own right.
  bool get quicGuard => _p.getBool(_kQuicGuard) ?? false;
  Future<void> setQuicGuard(bool v) => _p.setBool(_kQuicGuard, v);

  // ── Per-app tunnels ────────────────────────────────────────────────────────

  /// Applications pinned to a location of their own.
  List<AppBinding> get appBindings {
    final s = _p.getString(_kBindings);
    if (s == null) return const [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => AppBinding.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setAppBindings(List<AppBinding> v) =>
      _p.setString(_kBindings, jsonEncode(v.map((e) => e.toJson()).toList()));

  // ── Location sources ───────────────────────────────────────────────────────
  static const _kSources = 'location_sources';
  static const _kSourceServers = 'source_servers';
  static const _kSourceProfiles = 'source_profiles';
  static const _kAliases = 'server_aliases';
  static const _kGeo = 'server_geo';

  /// Every account, subscription and manual import, in display order.
  List<LocationSource> get sources {
    final s = _p.getString(_kSources);
    if (s == null) return const [];
    try {
      return (jsonDecode(s) as List)
          .map((e) =>
              LocationSource.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setSources(List<LocationSource> v) =>
      _p.setString(_kSources, jsonEncode(v.map((e) => e.toJson()).toList()));

  /// Last known servers per source, so the picker is populated on the frame
  /// after launch instead of after the network answers.
  Map<String, List<ServerConfig>> get cachedSourceServers {
    final s = _p.getString(_kSourceServers);
    if (s == null) return {};
    try {
      final raw = jsonDecode(s) as Map<String, dynamic>;
      return raw.map((sourceId, list) => MapEntry(
            sourceId,
            (list as List)
                .map((e) => ServerConfig.fromJson(
                      Map<String, dynamic>.from(e as Map),
                      sourceId: sourceId,
                    ))
                .toList(),
          ));
    } catch (_) {
      return {};
    }
  }

  Future<void> setCachedSourceServers(Map<String, List<ServerConfig>> v) =>
      _p.setString(
        _kSourceServers,
        jsonEncode(v.map((k, list) =>
            MapEntry(k, list.map((e) => e.toJson()).toList()))),
      );

  /// Cached profile per account source.
  Map<String, Profile> get cachedSourceProfiles {
    final s = _p.getString(_kSourceProfiles);
    if (s == null) return {};
    try {
      final raw = jsonDecode(s) as Map<String, dynamic>;
      return raw.map((k, v) =>
          MapEntry(k, Profile.fromJson(Map<String, dynamic>.from(v as Map))));
    } catch (_) {
      return {};
    }
  }

  Future<void> setCachedSourceProfiles(Map<String, Profile> v) => _p.setString(
        _kSourceProfiles,
        jsonEncode(v.map((k, p) => MapEntry(k, p.toJson()))),
      );

  // ── Per-server overrides ───────────────────────────────────────────────────
  //
  // Kept outside the server lists themselves and keyed by uid: the lists are
  // replaced wholesale on every refresh, and a rename must not be one panel
  // poll away from disappearing.

  Map<String, String> get aliases => _stringMap(_kAliases);

  Future<void> setAlias(String uid, String? name) async {
    final map = aliases;
    if (name == null || name.trim().isEmpty) {
      map.remove(uid);
    } else {
      map[uid] = name.trim();
    }
    await _p.setString(_kAliases, jsonEncode(map));
  }

  /// Locations the user placed by hand, for configs whose source does not know
  /// where they are.
  Map<String, GeoOverride> get geoOverrides {
    final s = _p.getString(_kGeo);
    if (s == null) return {};
    try {
      final raw = jsonDecode(s) as Map<String, dynamic>;
      return raw.map((k, v) => MapEntry(
          k, GeoOverride.fromJson(Map<String, dynamic>.from(v as Map))));
    } catch (_) {
      return {};
    }
  }

  Future<void> setGeoOverride(String uid, GeoOverride? geo) async {
    final map = geoOverrides;
    if (geo == null) {
      map.remove(uid);
    } else {
      map[uid] = geo;
    }
    await _p.setString(
        _kGeo, jsonEncode(map.map((k, v) => MapEntry(k, v.toJson()))));
  }

  Map<String, String> _stringMap(String key) {
    final s = _p.getString(key);
    if (s == null) return {};
    try {
      return (jsonDecode(s) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  /// Drops everything belonging to [sourceId] — used when a source is removed
  /// so its renames and pins do not linger as orphans.
  Future<void> forgetSource(String sourceId) async {
    final servers = cachedSourceServers..remove(sourceId);
    await setCachedSourceServers(servers);
    final profiles = cachedSourceProfiles..remove(sourceId);
    await setCachedSourceProfiles(profiles);

    final prefix = '$sourceId#';
    final alias = aliases..removeWhere((uid, _) => uid.startsWith(prefix));
    await _p.setString(_kAliases, jsonEncode(alias));
    final geo = geoOverrides..removeWhere((uid, _) => uid.startsWith(prefix));
    await _p.setString(
        _kGeo, jsonEncode(geo.map((k, v) => MapEntry(k, v.toJson()))));
  }

  // ── Device identity ────────────────────────────────────────────────────────

  /// Stable per-installation id, so the panel can count devices against the
  /// account's limit without pinning anyone to an IP address.
  String get deviceId => _p.getString(_kDeviceId) ?? '';
  Future<void> setDeviceId(String v) => _p.setString(_kDeviceId, v);

  String get deviceName => _p.getString(_kDeviceName) ?? '';
  Future<void> setDeviceName(String v) => _p.setString(_kDeviceName, v);
}

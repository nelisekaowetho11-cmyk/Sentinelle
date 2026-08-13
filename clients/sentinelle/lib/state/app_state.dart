import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../branding.dart';
import '../theme.dart' show AppThemeMode;
import '../models/app_binding.dart';
import '../models/models.dart';
import '../models/sources.dart';
import '../services/api.dart';
import '../services/autostart.dart';
import '../services/desktop_notifier.dart';
import '../services/source_registry.dart';
import '../services/storage.dart';
import '../services/update_service.dart';
import '../services/vpn/android_engine.dart';
import '../services/vpn/android_shortcuts.dart';
import '../services/vpn/android_engine.dart' show AndroidVpnEngine;
import '../services/vpn/desktop_engine.dart';
import '../services/vpn/elevation.dart';
import '../services/vpn/leak_guard.dart';
import '../services/vpn/local_proxy.dart';
import '../services/vpn/reachability.dart';
import '../services/vpn/vpn_engine.dart';

enum AuthStage { checking, loggedOut, loggedIn }

/// Single source of truth for the whole client app.
class AppState extends ChangeNotifier {
  /// [engine] is injectable so tests can drive the state/stats streams
  /// directly instead of starting a real core.
  AppState({VpnEngine? engine, this.adoptedTunnel = false}) {
    _engine = engine ??
        (Platform.isAndroid ? AndroidVpnEngine() : DesktopVpnEngine());
    _stateSub = _engine.stateStream.listen(_onVpnState);
    _statsSub = _engine.statsStream.listen(_onVpnStats);
  }

  /// The app opened into a tunnel that was already running — see
  /// [AndroidVpnEngine.sweepOrphans].
  final bool adoptedTunnel;

  late final VpnEngine _engine;
  VpnEngine get engine => _engine;
  StreamSubscription<VpnState>? _stateSub;
  StreamSubscription<VpnStats>? _statsSub;

  /// Every account, subscription and pasted config the app knows about.
  final SourceRegistry sources = SourceRegistry();

  /// The primary account's API, kept for the calls that are still
  /// account-shaped: update checks and the device registry.
  PanelApi? get api {
    final primary = sources.primaryAccount;
    return primary == null ? null : sources.apiOf(primary.id);
  }

  // ── Auth ───────────────────────────────────────────────────────────────────
  AuthStage authStage = AuthStage.checking;
  String? authError;
  bool busy = false;

  /// The panel's own account of the last failed sign-in, when it said more than
  /// a sentence. Only the device-limit refusal does today, and it carries the
  /// devices holding the slots — which is what lets the sign-in screen offer to
  /// sign one of them out instead of leaving the user stuck.
  ApiException? authFailure;

  /// Signs one of the account's other devices out so this one can take its
  /// slot. Returns null on success, or why it could not be done.
  ///
  /// Two ways in, because this is needed on both sides of the sign-in: an app
  /// that is already signed in authenticates with its token, and one that was
  /// just refused a token for being over the limit sends the credentials from
  /// the form instead.
  Future<String?> releaseDevice(
    String deviceId, {
    String username = '',
    String password = '',
  }) async {
    final signedIn = api;
    final api2 = signedIn ??
        PanelApi(
          baseUrl: sources.lastResolvedUrl.isEmpty
              ? Storage.I.baseUrl
              : sources.lastResolvedUrl,
        );
    try {
      await api2.releaseDevice(deviceId,
          username: username.trim(), password: password);
      authFailure = null;
      authError = null;
      notifyListeners();
      // The slot is free now, so the profile the app is showing — "devices 1 of
      // 1" — is already out of date.
      unawaited(refresh(silent: true));
      return null;
    } on ApiException catch (e) {
      return e.message;
    } finally {
      // Only the throwaway one: closing the registry's client would break every
      // later call it makes.
      if (signedIn == null) api2.close();
    }
  }

  /// The primary account's profile, or null when the user is running on
  /// subscriptions and pasted configs alone — which is now a supported way to
  /// use the app, not a broken state.
  Profile? get profile {
    final primary = sources.primaryAccount;
    return primary == null ? null : sources.profileOf(primary.id);
  }

  /// Every location, from every enabled source, in source order.
  List<ServerConfig> get servers => sources.servers;

  String brand = kAppName;

  String? get blockedReason {
    final primary = sources.primaryAccount;
    return primary == null ? null : sources.blockedReasonOf(primary.id);
  }

  /// Where the panel sees us connecting from — the origin of the map's arc and
  /// the "you" marker. Empty until the first session call lands, and always
  /// empty when there is no account to ask.
  ClientOrigin get origin {
    for (final account in sources.accounts) {
      final o = sources.originOf(account.id);
      if (o != null && !o.isEmpty) return o;
    }
    return const ClientOrigin();
  }

  /// True when the user has any way to connect at all.
  bool get hasLocations => sources.servers.isNotEmpty;

  /// Test seam: installs a source's worth of data without touching the network
  /// or SharedPreferences.
  @visibleForTesting
  void seedSource({
    String id = 'test',
    SourceKind kind = SourceKind.account,
    String label = '',
    List<ServerConfig> servers = const [],
    Profile? profile,
    ClientOrigin? origin,
    String? blockedReason,
  }) {
    // ignore: invalid_use_of_visible_for_testing_member
    sources.seed(
      id: id,
      kind: kind,
      label: label,
      servers: servers,
      profile: profile,
      origin: origin,
      blockedReason: blockedReason,
    );
    notifyListeners();
  }

  // ── Connection ─────────────────────────────────────────────────────────────
  VpnState vpnState = VpnState.disconnected;
  VpnStats vpnStats = VpnStats.zero;
  ServerConfig? activeServer;
  String? connectionError;

  /// Rolling speed history for the sparklines (bytes/s, newest last).
  ///
  /// `growable: true` matters: a fixed-length list throws on `removeAt`, and
  /// that threw inside the stats handler *before* notifyListeners(), so the
  /// timer and speeds only appeared to update when something else rebuilt the
  /// page (like switching tabs).
  static const historyLength = 40;
  final List<double> downHistory =
      List<double>.filled(historyLength, 0, growable: true);
  final List<double> upHistory =
      List<double>.filled(historyLength, 0, growable: true);

  /// Latency per server id, in ms. -1 = unreachable, null = not measured.
  final Map<int, int?> pings = {};

  Timer? _heartbeat;

  /// Result of the last update check, shown on the Settings screen and as a
  /// prompt once per launch.
  UpdateInfo update = UpdateInfo.none;
  bool updatePromptShown = false;

  /// True once the user has waved the connect-page update notice away. Reset on
  /// every launch on purpose — the check runs at startup, so a build they chose
  /// to skip is offered again next time rather than never.
  bool updateNoticeDismissed = false;

  /// Download progress, 0…1, while [installUpdate] is running. Null when it is
  /// not, which is what the UI branches on.
  double? updateProgress;
  String? updateError;

  void dismissUpdateNotice() {
    updateNoticeDismissed = true;
    notifyListeners();
  }

  /// Fetches the published build and hands it to the platform installer.
  ///
  /// Returns true when the app must quit for the install to proceed — a Windows
  /// installer cannot overwrite files this process still has open.
  Future<bool> installUpdate() async {
    if (!update.installable || updateProgress != null) return false;
    updateProgress = 0;
    updateError = null;
    notifyListeners();
    try {
      final file = await UpdateService.download(
        update,
        onProgress: (p, received, total) {
          updateProgress = p;
          notifyListeners();
        },
      );
      final quit = await UpdateService.install(file);
      updateProgress = null;
      notifyListeners();
      return quit;
    } catch (e) {
      updateProgress = null;
      updateError = '$e'.replaceFirst('Exception: ', '');
      notifyListeners();
      return false;
    }
  }

  /// Set when the chosen server answered slowly, so the UI can suggest a
  /// closer one without blocking the connection.
  String? slowServerWarning;

  /// Above this, a server is worth warning about.
  static const slowPingMs = 400;

  // ── Kill switch ────────────────────────────────────────────────────────────

  /// True between a user asking for a tunnel and a user asking to stop it.
  ///
  /// This is what separates "the tunnel died" from "the user pressed
  /// disconnect": the kill switch only ever engages on the first.
  bool _wantConnection = false;

  /// True once a tunnel has actually come up during this attempt.
  ///
  /// The kill switch exists to stop traffic escaping when a *working* tunnel
  /// dies. Without this it also fired when a connection simply failed to
  /// establish, which held the system proxy pointing at a dead port and left
  /// the machine with no internet at all — the "kill switch on and it will not
  /// connect" bug. A connection that never came up has nothing to protect.
  bool _tunnelEstablished = false;

  /// True while traffic is being held closed after an unexpected drop.
  bool killSwitchEngaged = false;

  /// Set while the recovery loop is waiting for the network to come back, so
  /// the UI can say "waiting for internet" rather than looking stuck.
  bool waitingForNetwork = false;

  Timer? _recovery;
  bool _recovering = false;
  int _recoveryAttempts = 0;

  /// Ticks of the 5-second recovery timer, and the tick the next reconnect is
  /// allowed on. Counting ticks rather than sleeping keeps the loop responsive
  /// to [retryNow] and to the user disconnecting.
  int _ticks = 0;
  int _nextAttemptTick = 0;

  /// Give up retrying after this many tries — roughly ten minutes with the
  /// backoff below — and leave traffic closed until the user decides.
  static const _maxRecoveryAttempts = 24;

  bool get killSwitchEnabled => Storage.I.killSwitch;

  /// Connect page layout. Detailed is the default.
  bool get detailedHome => Storage.I.detailedHome;

  Future<void> setDetailedHome(bool v) async {
    await Storage.I.setDetailedHome(v);
    notifyListeners();
  }

  // ── Appearance ─────────────────────────────────────────────────────────────

  AppThemeMode get themeMode => Storage.I.themeMode;

  Future<void> setThemeMode(AppThemeMode v) async {
    await Storage.I.setThemeMode(v);
    notifyListeners();
  }

  /// Whether the app starts when the user signs in. Desktop only.
  ///
  /// Read from the machine rather than from our own preference, so an entry
  /// added by the installer — or removed by hand — is reflected honestly
  /// instead of the switch claiming otherwise.
  bool launchAtLogin = false;

  Future<void> refreshLaunchAtLogin() async {
    if (!AutoStart.supported) return;
    final now = await AutoStart.isEnabled();
    if (now == launchAtLogin) return;
    launchAtLogin = now;
    notifyListeners();
  }

  /// Returns null on success, or why it could not be changed.
  Future<String?> setLaunchAtLogin(bool v) async {
    final ok = await AutoStart.setEnabled(v);
    await Storage.I.setLaunchAtLogin(v);
    launchAtLogin = await AutoStart.isEnabled();
    notifyListeners();
    return ok
        ? null
        : 'The startup entry could not be changed. A security policy or '
            'another program may be managing it.';
  }

  // ── Leak guards ────────────────────────────────────────────────────────────

  /// Live state of the DNS / IPv6 / WebRTC guards, shown on the connect page.
  LeakReport leaks = LeakReport.idle;
  Timer? _leakTimer;
  bool _leakChecking = false;

  /// Re-probes the guards. Cheap enough to run on connect and every couple of
  /// minutes after — each probe is a short connect attempt that is *expected*
  /// to fail.
  Future<void> checkLeaks() async {
    if (_leakChecking) return;
    if (!isConnected) {
      if (leaks != LeakReport.idle) {
        leaks = LeakReport.idle;
        notifyListeners();
      }
      return;
    }
    _leakChecking = true;
    try {
      final exit = activeServer;
      final report = await LeakGuard.check(
        dnsEnabled: Storage.I.dnsGuard,
        ipv6Enabled: Storage.I.ipv6Guard,
        webrtcEnabled: Storage.I.webRtcGuard,
        timezoneEnabled: Storage.I.timezoneGuard,
        lanEnabled: Storage.I.lanGuard,
        quicEnabled: Storage.I.quicGuard,
        exitCountry: exit?.country,
        // Where the panel says the request arrived from. Through a working
        // tunnel that is the exit, not the user — which is exactly what the
        // exit-IP guard is checking.
        seenCountry: origin.country,
        seenIp: origin.ip,
      );
      // The tunnel may have gone down while we were probing.
      if (isConnected) {
        leaks = report;
        notifyListeners();
      }
    } finally {
      _leakChecking = false;
    }
  }

  void _startLeakWatch() {
    _leakTimer?.cancel();
    leaks = const LeakReport();
    notifyListeners();
    unawaited(checkLeaks());
    _leakTimer =
        Timer.periodic(const Duration(minutes: 2), (_) => checkLeaks());
  }

  void _stopLeakWatch() {
    _leakTimer?.cancel();
    _leakTimer = null;
    leaks = LeakReport.idle;
  }

  Future<void> setGuard({
    bool? dns,
    bool? ipv6,
    bool? webRtc,
    bool? timezone,
    bool? lan,
    bool? quic,
  }) async {
    if (dns != null) await Storage.I.setDnsGuard(dns);
    if (ipv6 != null) await Storage.I.setIpv6Guard(ipv6);
    if (webRtc != null) await Storage.I.setWebRtcGuard(webRtc);
    if (timezone != null) await Storage.I.setTimezoneGuard(timezone);
    if (lan != null) await Storage.I.setLanGuard(lan);
    if (quic != null) await Storage.I.setQuicGuard(quic);
    notifyListeners();
    // The guards live in the core's routing table, so they only change on a
    // reconnect. Re-probe so the panel stops claiming a stale result.
    if (isConnected) unawaited(checkLeaks());
  }

  Future<void> setKillSwitch(bool v) async {
    await Storage.I.setKillSwitch(v);
    _applyKillSwitchToEngine();
    if (!v && killSwitchEngaged) {
      await releaseKillSwitch();
    } else {
      notifyListeners();
    }
  }

  void _applyKillSwitchToEngine() {
    final e = _engine;
    if (e is DesktopVpnEngine) e.killSwitch = Storage.I.killSwitch;
  }

  /// The tunnel went down on its own. Hold traffic closed and start trying to
  /// get it back.
  void _engageKillSwitch() {
    if (killSwitchEngaged) return;
    killSwitchEngaged = true;
    _recoveryAttempts = 0;
    _startRecovery();
    notifyListeners();
  }

  /// Android only: engage unless the stop came from the notification, the tile
  /// or the widget, in which case treat it exactly like the user pressing
  /// Disconnect inside the app.
  Future<void> _engageKillSwitchUnlessUserStopped() async {
    final asked = await AndroidShortcuts.consumeUserStop();
    // The user may have reconnected while we were asking.
    if (isConnected || isBusyConnecting) return;
    if (asked) {
      _wantConnection = false;
      _tunnelEstablished = false;
      notifyListeners();
      return;
    }
    if (_wantConnection && killSwitchEnabled) _engageKillSwitch();
  }

  void _startRecovery() {
    _recovery?.cancel();
    _recovery = Timer.periodic(const Duration(seconds: 5), (_) => _tryRecover());
  }

  Future<void> _tryRecover() async {
    if (_recovering) return;
    if (!_wantConnection || !killSwitchEngaged) {
      _recovery?.cancel();
      _recovery = null;
      return;
    }
    if (isConnected || isBusyConnecting) return;

    _ticks++;
    if (_ticks < _nextAttemptTick) return;

    _recovering = true;
    try {
      // Probing direct on purpose: in proxy mode the system proxy still points
      // at a dead port, which is the block working as intended.
      final online = await Reachability.online(
        timeout: const Duration(seconds: 4),
      );
      if (waitingForNetwork != !online) {
        waitingForNetwork = !online;
        notifyListeners();
      }
      // No internet yet: keep waiting without burning a reconnect attempt.
      if (!online) return;

      _recoveryAttempts++;
      if (_recoveryAttempts > _maxRecoveryAttempts) {
        _recovery?.cancel();
        _recovery = null;
        connectionError =
            'Could not get the tunnel back. Traffic is still blocked — '
            'reconnect, or turn the kill switch off to go without protection.';
        notifyListeners();
        return;
      }
      _nextAttemptTick = _ticks + _backoffTicks(_recoveryAttempts);
      await connect(fromRecovery: true);
    } finally {
      _recovering = false;
    }
  }

  /// 5s for the first few tries, then 15s, then 30s. A server that is down
  /// stays down, and hammering it helps nobody.
  static int _backoffTicks(int attempt) =>
      attempt < 3 ? 1 : (attempt < 9 ? 3 : 6);

  /// User chose to stop holding traffic closed. Opens the machine back up.
  Future<void> releaseKillSwitch() async {
    _recovery?.cancel();
    _recovery = null;
    killSwitchEngaged = false;
    waitingForNetwork = false;
    _wantConnection = false;
    _tunnelEstablished = false;
    _dialling = false;
    _recoveryAttempts = 0;
    // Puts the system proxy back the way we found it.
    await _engine.disconnect();
    notifyListeners();
  }

  /// User asked to retry now rather than wait for the next backoff tick.
  Future<void> retryNow() async {
    _recoveryAttempts = 0;
    _nextAttemptTick = 0;
    await connect();
  }

  /// True once a "connected" toast has gone out and no "disconnected" one has
  /// followed it.
  ///
  /// The obvious test — did we come *from* [VpnState.connected] — is wrong:
  /// a deliberate stop goes connected → disconnecting → disconnected, so by the
  /// time `disconnected` arrives the previous state is `disconnecting` and the
  /// notification was never sent. That is the whole of "the desktop app does
  /// not tell me when it disconnects".
  bool _announcedConnected = false;

  /// Toasts the two transitions worth interrupting someone about.
  ///
  /// Driven off the *change* rather than the state, so a repeated event — the
  /// recovery loop retrying, say — does not produce a stream of notifications.
  void _notifyDesktop(VpnState from, VpnState to) {
    if (from == to) return;
    if (Platform.isAndroid) {
      // The home screen widget cannot see this any other way.
      unawaited(AndroidShortcuts.refreshWidgets());
      return;
    }

    if (to == VpnState.connected) {
      _announcedConnected = true;
      final where = activeServer?.displayName ?? 'the tunnel';
      unawaited(DesktopNotifier.connected(where));
      return;
    }
    // Only a tunnel that was actually up is worth announcing as lost;
    // "disconnected" after a failed attempt is just the failure again.
    if (_announcedConnected &&
        (to == VpnState.disconnected || to == VpnState.error)) {
      _announcedConnected = false;
      unawaited(DesktopNotifier.disconnected(
        where: activeServer?.displayName,
        // A stop the user asked for is not a fault, and attaching the last
        // engine failure to it would report an old error as the reason.
        reason: _wantConnection ? _engine.lastFailure : null,
      ));
      return;
    }
    if (to == VpnState.error && _engine.lastFailure != null) {
      unawaited(DesktopNotifier.failed(_engine.lastFailure!));
    }
  }

  /// Dismisses the error banner without changing the tunnel.
  void clearConnectionError() {
    connectionError = null;
    notifyListeners();
  }

  Future<void> checkForUpdate() async {
    // Update metadata comes from the primary panel; with no account signed in
    // there is nobody to ask, which is fine.
    final a = api;
    if (a == null) return;
    final result = await UpdateService.check(a);
    // The window may have closed while the panel was answering, and
    // notifyListeners() on a disposed ChangeNotifier throws.
    if (_disposed) return;
    // A build the user was already notified about should not re-open the notice
    // they closed; a genuinely newer one should.
    if (result.latest != update.latest) updateNoticeDismissed = false;
    update = result;
    notifyListeners();
  }

  /// True when VPN (TUN) mode is selected on desktop but the process is not
  /// elevated, so the tunnel physically cannot come up.
  bool get needsElevation =>
      !Platform.isAndroid &&
      Storage.I.vpnMode &&
      !Elevation.isElevated;

  /// Set the instant the user asks for a tunnel, before the engine has had a
  /// chance to report anything.
  ///
  /// Starting a core takes a moment — on desktop it has to stop the previous
  /// one and wait for a listener, on Android the plugin has to hand a config
  /// across the platform channel. Without this the button stayed in its idle
  /// state for that whole time and read as "nothing happened".
  bool _dialling = false;

  bool get isConnected => vpnState == VpnState.connected;
  bool get isBusyConnecting =>
      _dialling ||
      vpnState == VpnState.connecting ||
      vpnState == VpnState.disconnecting;

  ServerConfig? get selectedServer {
    if (servers.isEmpty) return null;
    final id = Storage.I.lastServerId;
    return servers.firstWhere((s) => s.id == id, orElse: () => servers.first);
  }

  // ── Boot ───────────────────────────────────────────────────────────────────
  Future<void> bootstrap() async {
    brand = Storage.I.brand;
    unawaited(refreshLaunchAtLogin());

    // A tunnel that was already up when the app opened is ours to show, not to
    // tear down. Claimed before anything else so the connect page never paints
    // "disconnected" over a working VPN.
    final engine = _engine;
    if (adoptedTunnel && engine is AndroidVpnEngine) {
      engine.adoptRunningTunnel();
      _wantConnection = true;
      _tunnelEstablished = true;
    }
    await sources.load();

    // Cached locations are on screen before any network call: a subscription
    // that is slow to answer should not make the app look empty.
    if (sources.sources.isEmpty) {
      authStage = AuthStage.loggedOut;
      notifyListeners();
      return;
    }

    authStage = AuthStage.loggedIn;
    notifyListeners();

    // Every launch, and before the (slower) source refresh: the panel knows the
    // answer without us being signed in, and the notice on the connect page is
    // the whole point of asking.
    unawaited(checkForUpdate());

    await sources.refreshAll();
    _lastRefresh = DateTime.now();
    _afterSourcesChanged();
    _startHeartbeat();
    _startAutoRefresh();

    final target = selectedServer;
    if (Storage.I.autoConnect && target != null && canConnectTo(target)) {
      unawaited(connect());
    }
    notifyListeners();
  }

  /// Re-derives everything that hangs off the merged location list.
  void _afterSourcesChanged() {
    final all = servers;
    if (all.isNotEmpty && !all.any((x) => x.id == Storage.I.lastServerId)) {
      Storage.I.setLastServerId(all.first.id);
    }
    // Drop latency readings for locations that no longer exist, or the map
    // keeps colouring pins that went away.
    final live = all.map((s) => s.id).toSet();
    pings.removeWhere((id, _) => !live.contains(id));
    unawaited(checkForUpdate());
  }

  /// True when [server]'s own account says it may be used. Subscriptions and
  /// pasted configs have no quota to check, so they are always allowed.
  bool canConnectTo(ServerConfig server) {
    final source = sources.sourceById(server.sourceId);
    if (source == null || source.kind != SourceKind.account) return true;
    final p = sources.profileOf(source.id);
    return p == null || p.canConnect;
  }

  String? blockedReasonFor(ServerConfig server) {
    final source = sources.sourceById(server.sourceId);
    if (source == null || source.kind != SourceKind.account) return null;
    return sources.blockedReasonOf(source.id);
  }

  // ── Sources ────────────────────────────────────────────────────────────────

  /// Adds a panel account. Several can be signed in at once; the first one
  /// becomes the primary and supplies the quota display.
  Future<bool> login(String baseUrl, String username, String password,
      {required bool remember}) async {
    busy = true;
    authError = null;
    authFailure = null;
    notifyListeners();

    final error = await sources.addAccount(baseUrl, username, password);
    busy = false;

    if (error != null) {
      authError = error;
      authFailure = sources.lastAuthFailure;
      notifyListeners();
      return false;
    }

    // Kept for the migration path and for pre-filling the sign-in form.
    await Storage.I.setRememberMe(remember);
    await Storage.I.setSavedUsername(remember ? username.trim() : '');
    await Storage.I.setSavedPassword(remember ? password : '');

    authStage = AuthStage.loggedIn;
    _afterSourcesChanged();
    _startHeartbeat();
    _startAutoRefresh();
    notifyListeners();

    final target = selectedServer;
    if (Storage.I.autoConnect && target != null && canConnectTo(target)) {
      unawaited(connect());
    }
    return true;
  }

  /// Adds a subscription from any panel, with or without an account signed in.
  Future<String?> addSubscription(String url, {String label = ''}) async {
    busy = true;
    notifyListeners();
    final error = await sources.addSubscription(url, label: label);
    busy = false;
    if (error == null) {
      authStage = AuthStage.loggedIn;
      _afterSourcesChanged();
      _startAutoRefresh();
    }
    notifyListeners();
    return error;
  }

  /// Imports configs the user pasted in.
  Future<ImportOutcome> importConfigs(String text) async {
    busy = true;
    notifyListeners();
    final outcome = await sources.addManual(text);
    busy = false;
    if (outcome.ok) {
      authStage = AuthStage.loggedIn;
      _afterSourcesChanged();
    }
    notifyListeners();
    return outcome;
  }

  /// Refreshes one source on demand — the per-row "refresh now" action.
  Future<void> refreshSource(String sourceId) async {
    await sources.refresh(sourceId);
    _afterSourcesChanged();
    notifyListeners();
  }

  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    await sources.setEnabled(sourceId, enabled);
    await _dropActiveIfGone();
    _afterSourcesChanged();
    notifyListeners();
  }

  Future<void> renameSource(String sourceId, String label) async {
    await sources.rename(sourceId, label);
    notifyListeners();
  }

  /// Puts a source's locations at the top of the picker, or back in the order
  /// it was added.
  ///
  /// The selected server is re-anchored afterwards for the same reason
  /// [_afterSourcesChanged] does it: "first in the list" is the fallback when
  /// nothing is selected, and pinning changes which one that is.
  Future<void> setSourcePinned(String sourceId, bool pinned) async {
    await sources.setPinned(sourceId, pinned);
    _afterSourcesChanged();
    notifyListeners();
  }

  Future<void> setServerAlias(ServerConfig server, String? alias) async {
    await sources.setAlias(server.uid, alias);
    notifyListeners();
  }

  Future<void> setServerLocation(ServerConfig server, GeoOverride? geo) async {
    await sources.setGeo(server.uid, geo);
    notifyListeners();
  }

  /// Signs out of / removes the given sources. This is the "log out of one,
  /// some, or all" path — the UI passes whichever set the user ticked.
  Future<void> removeSources(Iterable<String> sourceIds) async {
    await sources.removeMany(sourceIds);
    await _dropActiveIfGone();
    if (sources.sources.isEmpty) {
      _heartbeat?.cancel();
      _heartbeat = null;
      _autoRefresh?.cancel();
      _autoRefresh = null;
      authStage = AuthStage.loggedOut;
    }
    _afterSourcesChanged();
    notifyListeners();
  }

  /// Removes everything and returns to the sign-in screen.
  Future<void> logout() => removeSources(sources.sources.map((s) => s.id));

  /// Tears the tunnel down if the location carrying it has just been removed
  /// or disabled — otherwise the app keeps a connection the user can no longer
  /// see or manage.
  Future<void> _dropActiveIfGone() async {
    final active = activeServer;
    if (active == null) return;
    if (servers.any((s) => s.uid == active.uid)) return;
    if (isConnected || isBusyConnecting) await disconnect();
    activeServer = null;
  }

  /// When the last full refresh landed, so [refreshOnOpen] can tell a real
  /// return from a momentary flick away.
  DateTime? _lastRefresh;

  /// How stale the data has to be before reopening the app is worth a fetch.
  ///
  /// Well under the [refreshInterval] tick, because the point is the *other*
  /// case: a phone that was asleep for a day has a suspended timer, so without
  /// this the first thing the user sees on opening the app is yesterday's
  /// quota and yesterday's server list.
  static const openRefreshAfter = Duration(seconds: 30);

  /// The app came back to the foreground — on Android from the task switcher,
  /// on desktop from the tray.
  ///
  /// Deliberately silent: this fires on every resume, and flipping the whole
  /// screen into a loading state because someone glanced at a notification
  /// would be worse than the staleness it fixes.
  Future<void> refreshOnOpen() async {
    if (sources.sources.isEmpty) return;
    final last = _lastRefresh;
    if (last != null && DateTime.now().difference(last) < openRefreshAfter) {
      return;
    }
    await refresh(silent: true);
    // A device that has been away long enough for the list to change has
    // almost certainly lost its heartbeat slot too.
    _startHeartbeat();
    _startAutoRefresh();
  }

  Future<void> refresh({bool silent = false}) async {
    if (sources.sources.isEmpty) return;
    if (!silent) {
      busy = true;
      notifyListeners();
    }
    await sources.refreshAll();
    _lastRefresh = DateTime.now();
    _afterSourcesChanged();
    if (!silent) connectionError = null;
    busy = false;
    notifyListeners();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) async {
      for (final account in sources.accounts) {
        final api = sources.apiOf(account.id);
        if (api == null || account.token == null) continue;
        try {
          final h = await api.heartbeat();
          sources.applyHeartbeat(
            account.id,
            profile: h.profile,
            blockedReason: h.blockedReason,
          );
          // Quota ran out or the operator paused the account: stop a tunnel
          // that is running on *that* account, and leave the others alone.
          final active = activeServer;
          if (!h.canConnect &&
              active != null &&
              active.sourceId == account.id &&
              (isConnected || isBusyConnecting)) {
            await disconnect();
            connectionError = h.blockedReason;
          }
        } on ApiException {
          // Refresh deals with expiry properly; a missed heartbeat is not
          // worth signing anyone out over.
        }
      }
      notifyListeners();
    });
  }

  /// Everything the app shows — accounts, their locations, and every
  /// subscription — is brought up to date on a five-minute cadence.
  ///
  /// Deliberately one timer for all of it rather than one per source: the
  /// registry already refreshes them in parallel and records failures per
  /// source, and a single clock keeps the network quiet between ticks.
  static const refreshInterval = Duration(minutes: 5);
  Timer? _autoRefresh;

  void _startAutoRefresh() {
    _autoRefresh?.cancel();
    _autoRefresh = Timer.periodic(refreshInterval, (_) async {
      if (sources.sources.isEmpty) return;
      await sources.refreshAll();
      _lastRefresh = DateTime.now();
      _afterSourcesChanged();
      notifyListeners();
    });
  }

  // ── Connection actions ─────────────────────────────────────────────────────
  VpnEngineOptions get engineOptions => VpnEngineOptions(
        // Android honours this too now: proxy-only runs the core without a
        // VpnService, which is what you want when only one app should be
        // routed, or when the device refuses to grant the VPN permission.
        mode: Storage.I.vpnMode ? TunnelMode.vpn : TunnelMode.proxy,
        socksPort: Storage.I.socksPort,
        httpPort: Storage.I.httpPort,
        dnsServers: Storage.I.dnsServers
            .split(RegExp(r'[,\s]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        bypassLan: Storage.I.bypassLan,
        blockAds: Storage.I.blockAds,
        systemProxy: Storage.I.systemProxy,
        splitApps: Storage.I.splitApps,
        splitMode: Storage.I.splitMode,
        forceTunnel: RoutingRules.parse(Storage.I.tunnelRules),
        forceDirect: RoutingRules.parse(Storage.I.bypassRules),
        corePath: Storage.I.corePath,
        dnsGuard: Storage.I.dnsGuard,
        ipv6Guard: Storage.I.ipv6Guard,
        webRtcGuard: Storage.I.webRtcGuard,
        lanGuard: Storage.I.lanGuard,
        quicGuard: Storage.I.quicGuard,
        appRoutes: _activeAppRoutes,
      );

  // ── Per-app tunnels ────────────────────────────────────────────────────────

  /// Applications pinned to a location of their own, running alongside the
  /// main tunnel.
  ///
  /// One core carries all of them. A machine has one routing table and one TUN
  /// device, so genuinely separate tunnels would fight each other; sing-box
  /// instead resolves the owning process of every connection and sends it to
  /// that app's outbound. "Stop one" therefore means "drop its rule", which is
  /// what [setBindingEnabled] does.
  List<AppBinding> get appBindings => Storage.I.appBindings;

  /// True when per-app tunnels can actually work here.
  ///
  /// Android is excluded on purpose rather than silently doing nothing:
  /// VpnService hands the core raw packets with no app identity attached, and
  /// Xray cannot route on process. The only per-app control Android offers is
  /// including or excluding whole apps from the single tunnel, which is what
  /// the split-tunnel list already does.
  bool get supportsAppTunnels => !Platform.isAndroid;

  /// The routes handed to the core: enabled bindings whose location still
  /// exists.
  List<AppRoute> get _activeAppRoutes {
    if (!supportsAppTunnels) return const [];
    final byUid = {for (final s in servers) s.uid: s};
    final grouped = <String, List<String>>{};
    for (final b in appBindings) {
      if (!b.enabled || b.process.trim().isEmpty) continue;
      if (!byUid.containsKey(b.serverUid)) continue;
      grouped.putIfAbsent(b.serverUid, () => []).add(b.process.trim());
    }
    return [
      for (final entry in grouped.entries)
        AppRoute(processes: entry.value, server: byUid[entry.key]!),
    ];
  }

  /// How many per-app tunnels are live right now.
  int get activeAppTunnels =>
      isConnected ? _activeAppRoutes.fold(0, (n, r) => n + r.processes.length) : 0;

  Future<void> addBinding(String process, ServerConfig server,
      {String label = ''}) async {
    final list = [...appBindings];
    // One app, one exit: re-binding an app it already knows about replaces the
    // old rule rather than producing two that contradict each other.
    list.removeWhere(
        (b) => b.process.toLowerCase() == process.trim().toLowerCase());
    list.add(AppBinding(
      id: newBindingId(),
      process: process.trim(),
      serverUid: server.uid,
      label: label,
    ));
    await Storage.I.setAppBindings(list);
    await _reapplyAppRoutes();
  }

  Future<void> removeBindings(Iterable<String> ids) async {
    final gone = ids.toSet();
    await Storage.I
        .setAppBindings(appBindings.where((b) => !gone.contains(b.id)).toList());
    await _reapplyAppRoutes();
  }

  /// Sends an app that is already bound out through a different location.
  ///
  /// Editing in place rather than remove-and-re-add keeps the binding's id, and
  /// with it whether the user had stopped it — re-adding would silently start a
  /// tunnel they had deliberately paused.
  Future<void> setBindingServer(String id, ServerConfig server) async {
    await Storage.I.setAppBindings([
      for (final b in appBindings)
        b.id == id ? b.copyWith(serverUid: server.uid) : b,
    ]);
    await _reapplyAppRoutes();
  }

  /// Renames one binding. The process it matches on is unchanged.
  Future<void> setBindingLabel(String id, String label) async {
    await Storage.I.setAppBindings([
      for (final b in appBindings)
        b.id == id ? b.copyWith(label: label.trim()) : b,
    ]);
    notifyListeners();
  }

  /// Starts or stops one app's tunnel, leaving every other app alone.
  Future<void> setBindingEnabled(String id, bool enabled) async {
    await Storage.I.setAppBindings([
      for (final b in appBindings) b.id == id ? b.copyWith(enabled: enabled) : b,
    ]);
    await _reapplyAppRoutes();
  }

  /// Stops the given per-app tunnels without touching the main one.
  Future<void> stopBindings(Iterable<String> ids) async {
    final target = ids.toSet();
    await Storage.I.setAppBindings([
      for (final b in appBindings)
        target.contains(b.id) ? b.copyWith(enabled: false) : b,
    ]);
    await _reapplyAppRoutes();
  }

  /// Stops every per-app tunnel. The main tunnel keeps running — "stop all of
  /// them" means the per-app ones, not the connection the user is browsing on.
  Future<void> stopAllBindings() =>
      stopBindings(appBindings.map((b) => b.id).toList());

  /// Routes live in the core's config, so a change only takes effect on a
  /// restart. Done here rather than left to the user: a binding that silently
  /// does nothing until the next reconnect is worse than a two-second blip.
  Future<void> _reapplyAppRoutes() async {
    notifyListeners();
    if (isConnected) await connect(server: activeServer);
  }

  Future<void> selectServer(ServerConfig s) async {
    await Storage.I.setLastServerId(s.id);
    notifyListeners();
    if (pings[s.id] == null) unawaited(refreshSelectedPing());
    if (isConnected) {
      await connect(server: s);
    }
  }

  /// [fromRecovery] marks the kill switch's own retry, which must not tear
  /// down the loop it is running inside.
  Future<void> connect({ServerConfig? server, bool fromRecovery = false}) async {
    final target = server ?? selectedServer;
    if (target == null) {
      // A blocked account is handed no servers at all, so "no servers yet" was
      // what someone over their device limit was told — true, and no help at
      // all in working out why.
      connectionError =
          blockedReason ?? 'No servers are available on your account yet.';
      notifyListeners();
      return;
    }
    if (profile != null && !profile!.canConnect) {
      connectionError = blockedReason ?? 'Your account is not active.';
      notifyListeners();
      return;
    }

    // Catch this before starting a core that is only going to fail: VPN mode
    // needs elevation, and a fresh launch never went through the Settings
    // toggle that used to be the only place this was checked.
    if (needsElevation) {
      connectionError = 'VPN mode needs administrator rights.';
      notifyListeners();
      return;
    }

    // Say "connecting" on this frame. Everything below can take seconds —
    // measuring latency alone used to block for a socket timeout — and until
    // the engine emits its own state the button would otherwise look dead.
    _dialling = true;
    connectionError = null;
    slowServerWarning = null;
    activeServer = target;
    // From here on a drop we did not ask for is the kill switch's business.
    _wantConnection = true;
    _tunnelEstablished = false;
    _applyKillSwitchToEngine();
    notifyListeners();

    // A deliberate connect takes the recovery loop's place rather than racing
    // it: two connects at once just make the core flap.
    if (!fromRecovery) {
      _recovery?.cancel();
      _recovery = null;
      _recoveryAttempts = 0;
    }

    unawaited(Storage.I.setLastServerId(target.id));

    try {
      // The engine serialises this internally and stops any running core
      // first — disconnecting here too would just make the UI flap.
      await _engine.connect(target, engineOptions);
    } catch (e) {
      _dialling = false;
      connectionError = '$e'.replaceFirst('Exception: ', '');
      notifyListeners();
      return;
    }

    // Latency is worth knowing but nothing waits on it, so it happens after
    // the tunnel is on its way rather than in front of it.
    unawaited(_warnIfSlow(target));
  }

  /// Measures [target] in the background and points out a slow server without
  /// getting in the way of the connection.
  Future<void> _warnIfSlow(ServerConfig target) async {
    if (pings[target.id] == null) {
      pings[target.id] = await _engine.measureDelay(target, engineOptions);
    }
    final ping = pings[target.id];
    if (activeServer?.id != target.id) return;
    // The user cancelled while this was measuring. Telling them the server
    // they just walked away from is a bit slow helps nobody.
    if (!_wantConnection) return;
    slowServerWarning = (ping != null && ping > slowPingMs)
        ? 'This server is responding slowly ($ping ms). '
            'A closer location may work better.'
        : null;
    notifyListeners();
  }

  /// Called when the app is quitting: make sure no core outlives the window.
  Future<void> shutdown() async {
    _recovery?.cancel();
    _recovery = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    final e = _engine;
    if (e is DesktopVpnEngine) {
      await e.shutdown();
    } else {
      try {
        await e.disconnect();
      } catch (_) {}
    }
  }

  Future<void> disconnect() async {
    // A deliberate stop. Stand the kill switch down before tearing the tunnel
    // down, or it would treat our own disconnect as a drop and re-engage.
    _wantConnection = false;
    _tunnelEstablished = false;
    _dialling = false;
    killSwitchEngaged = false;
    waitingForNetwork = false;
    _recovery?.cancel();
    _recovery = null;
    _recoveryAttempts = 0;
    _ticks = 0;
    _nextAttemptTick = 0;
    try {
      await _engine.disconnect();
    } catch (e) {
      connectionError = '$e';
    }
    notifyListeners();
    // Our requests are off the tunnel again, so the exit address on screen is
    // now the tunnel's rather than ours. Correct it instead of leaving the old
    // one up until the five-minute refresh.
    unawaited(refresh(silent: true));
  }

  Future<void> toggleConnection() =>
      isConnected || isBusyConnecting ? disconnect() : connect();

  /// Measures every location.
  ///
  /// In batches rather than one at a time: each probe waits out its own
  /// timeout, so a serial pass over twenty locations with three dead ones in it
  /// took the better part of a minute. Batched rather than all at once because
  /// a phone opening every socket in the list at the same moment is how you get
  /// them all timing out together.
  static const _pingBatch = 6;

  Future<void> pingAll() async {
    final all = servers;
    for (var i = 0; i < all.length; i += _pingBatch) {
      final batch = all.skip(i).take(_pingBatch).toList();
      await Future.wait([
        for (final s in batch)
          _engine.measureDelay(s, engineOptions).then((ms) => pings[s.id] = ms),
      ]);
      notifyListeners();
    }
  }

  Future<void> pingOne(ServerConfig s) async {
    pings[s.id] = null;
    notifyListeners();
    pings[s.id] = await _engine.measureDelay(s, engineOptions);
    notifyListeners();
  }

  /// Measures the current server in the background so the Connect page shows a
  /// real number instead of a dash. Called after sign-in, after picking a
  /// server, and once a tunnel comes up.
  Future<void> refreshSelectedPing() async {
    final s = activeServer ?? selectedServer;
    if (s == null) return;
    final ms = await _engine.measureDelay(s, engineOptions);
    pings[s.id] = ms;
    notifyListeners();
  }

  /// Points the app's own requests down the tunnel, or takes them off it.
  ///
  /// Only proxy mode needs it. In VPN mode the operating system routes our
  /// sockets like everything else's, and sending them to the local listener on
  /// top of that would just be a loop.
  void _applyLocalProxy() {
    final proxyMode = engineOptions.mode == TunnelMode.proxy;
    if (isConnected && proxyMode) {
      LocalProxy.use('127.0.0.1', Storage.I.httpPort);
    } else {
      LocalProxy.clear();
    }
  }

  // ── Engine events ──────────────────────────────────────────────────────────
  void _onVpnState(VpnState s) {
    final previous = vpnState;
    vpnState = s;
    // Before anything below asks the panel a question: in proxy mode the
    // answer depends on whether we are looking through the tunnel, and "where
    // does the panel see me from" is the one the connect page draws.
    _applyLocalProxy();
    _notifyDesktop(previous, s);
    // The engine is driving the state now, so the optimistic "dialling" flag
    // has done its job.
    if (s != VpnState.connecting) _dialling = false;
    if (s == VpnState.connected) _tunnelEstablished = true;
    if (s == VpnState.error) {
      // Whichever engine is running, it knows why. Desktop failures used to
      // arrive here with nothing attached, which is how a dead core reached
      // the user as the single word "Error".
      connectionError = _engine.lastFailure ?? connectionError;
    }
    if (s == VpnState.connected) {
      // Through the tunnel the number is meaningful; measure it again.
      unawaited(refreshSelectedPing());
      _startLeakWatch();
      // Ask the panel again now that our own requests go through the tunnel.
      // "you" is the exit address the connect page shows and the leak guard
      // compares against, and until this lands it is still whatever we were
      // seen as before connecting — which is the user's real IP.
      unawaited(refresh(silent: true).then((_) {
        if (isConnected) unawaited(checkLeaks());
      }));
    }
    if (s == VpnState.disconnected || s == VpnState.error) {
      _stopLeakWatch();
    }
    if (s == VpnState.disconnected) {
      for (var i = 0; i < downHistory.length; i++) {
        downHistory[i] = 0;
        upHistory[i] = 0;
      }
      vpnStats = VpnStats.zero;
    }
    // A tunnel that came up and then went away while the user still wanted it:
    // either the core died or the network did. Hold traffic closed and start
    // recovering. A connection that never established is just a failed
    // connect — surface the error and leave the machine alone.
    if ((s == VpnState.disconnected || s == VpnState.error) &&
        _wantConnection &&
        _tunnelEstablished &&
        killSwitchEnabled) {
      if (Platform.isAndroid) {
        // …unless somebody outside the app asked for the stop. Only Android
        // has those surfaces (the notification's DISCONNECT button, the tile,
        // the widget) and only the native side knows, so the answer arrives a
        // channel round-trip later. That is well inside the recovery loop's
        // five-second first tick, and holding the kill switch off until we
        // know is what stops a tap on DISCONNECT reconnecting the VPN.
        unawaited(_engageKillSwitchUnlessUserStopped());
      } else {
        _engageKillSwitch();
      }
    }
    if (s == VpnState.connected && killSwitchEngaged) {
      killSwitchEngaged = false;
      waitingForNetwork = false;
      _recovery?.cancel();
      _recovery = null;
      _recoveryAttempts = 0;
    }
    notifyListeners();
  }

  void _onVpnStats(VpnStats s) {
    vpnStats = s;
    _push(downHistory, s.downloadSpeed.toDouble());
    _push(upHistory, s.uploadSpeed.toDouble());
    notifyListeners();
  }

  static void _push(List<double> history, double value) {
    history.add(value);
    while (history.length > historyLength) {
      history.removeAt(0);
    }
  }

  /// Set by [dispose] so the async tails of in-flight work — an update check
  /// that is still waiting on the panel, most often — know not to notify.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _leakTimer?.cancel();
    _recovery?.cancel();
    _heartbeat?.cancel();
    _autoRefresh?.cancel();
    _stateSub?.cancel();
    _statsSub?.cancel();
    _engine.dispose();
    sources.dispose();
    super.dispose();
  }
}

/// bytes/s → "48.2 Mbps"
({String value, String unit}) formatSpeed(int bytesPerSecond) {
  final bits = bytesPerSecond * 8;
  if (bits >= 1000000000) {
    return (value: (bits / 1000000000).toStringAsFixed(2), unit: 'Gbps');
  }
  if (bits >= 1000000) {
    return (value: (bits / 1000000).toStringAsFixed(1), unit: 'Mbps');
  }
  if (bits >= 1000) return (value: (bits / 1000).toStringAsFixed(1), unit: 'Kbps');
  return (value: '$bits', unit: 'bps');
}

String formatBytes(int bytes) {
  if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

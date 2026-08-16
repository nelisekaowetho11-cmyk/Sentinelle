import 'dart:async';

import '../../models/models.dart';
import '../routing.dart';
import '../singbox_config.dart' show AppRoute, TunnelMode;

export '../routing.dart';
export '../singbox_config.dart' show AppRoute, TunnelMode;

enum VpnState { disconnected, connecting, connected, disconnecting, error }

class VpnStats {
  final int uploadSpeed; // bytes/s
  final int downloadSpeed; // bytes/s
  final int uploadTotal; // bytes
  final int downloadTotal; // bytes
  final Duration duration;

  const VpnStats({
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.duration = Duration.zero,
  });

  static const zero = VpnStats();
}

class VpnEngineOptions {
  const VpnEngineOptions({
    required this.mode,
    required this.socksPort,
    required this.httpPort,
    required this.dnsServers,
    required this.bypassLan,
    required this.blockAds,
    required this.systemProxy,
    required this.splitApps,
    required this.splitMode,
    required this.forceTunnel,
    required this.forceDirect,
    required this.corePath,
    this.dnsGuard = true,
    this.ipv6Guard = true,
    this.webRtcGuard = true,
    this.lanGuard = true,
    this.quicGuard = false,
    this.appRoutes = const [],
  });

  /// Desktop only — Android is always a full TUN tunnel.
  final TunnelMode mode;

  final int socksPort;
  final int httpPort;
  final List<String> dnsServers;
  final bool bypassLan;
  final bool blockAds;

  /// Desktop only — route all system traffic through the local HTTP proxy.
  final bool systemProxy;

  /// Android package names / desktop executable names named by [splitMode].
  final List<String> splitApps;

  /// How [splitApps] is applied.
  final SplitMode splitMode;

  /// Domains and IPs forced through the tunnel.
  final RoutingRules forceTunnel;

  /// Domains and IPs that always bypass the tunnel.
  final RoutingRules forceDirect;

  /// Desktop only — explicit path to an `xray` executable ('' = managed copy).
  final String corePath;

  /// Leak guards, applied to whichever core is carrying the traffic.
  final bool dnsGuard;
  final bool ipv6Guard;
  final bool webRtcGuard;

  /// Drop local-network discovery chatter (mDNS, LLMNR, SSDP, NetBIOS).
  final bool lanGuard;

  /// Refuse QUIC so browsers fall back to TCP through the tunnel.
  final bool quicGuard;

  /// Applications routed to an exit of their own, alongside the main tunnel.
  ///
  /// Desktop only: Android's VpnService hands the core raw packets with no way
  /// to tell which app sent them, and Xray cannot route on process identity.
  final List<AppRoute> appRoutes;
}

/// A platform-specific way of actually carrying traffic.
abstract class VpnEngine {
  Stream<VpnState> get stateStream;
  Stream<VpnStats> get statsStream;

  VpnState get state;
  VpnStats get stats;

  /// One-time setup (VPN permission on Android, core presence on desktop).
  Future<void> initialize();

  /// True when the engine has everything it needs to connect.
  Future<bool> isReady();

  /// Ask the OS for whatever permission is required. Returns false if denied.
  Future<bool> requestPermission();

  Future<void> connect(ServerConfig server, VpnEngineOptions options);
  Future<void> disconnect();

  /// True when the last stop the engine reported was asked for by a person
  /// rather than suffered.
  ///
  /// On the interface for the same reason [lastFailure] is: the state layer
  /// used to type-check for the Android engine to find this out, which made it
  /// untestable through a fake and invisible to every other engine. Only
  /// Android has stops that arrive from outside the app — the notification's
  /// DISCONNECT button, the quick settings tile, the home screen widget — so
  /// elsewhere it is simply false.
  bool get lastStopWasUserRequested;

  /// Round-trip latency to a server, in ms. -1 when unreachable.
  Future<int> measureDelay(ServerConfig server, VpnEngineOptions options);

  /// Human-readable core version, or '' if unknown.
  Future<String> coreVersion();

  /// Why the last attempt failed, in words. Null when nothing has gone wrong.
  ///
  /// On the interface rather than the implementations because the state layer
  /// used to type-check for the Android engine and so never showed a reason
  /// for a desktop failure — the UI just said "Error".
  String? get lastFailure;

  void dispose();
}

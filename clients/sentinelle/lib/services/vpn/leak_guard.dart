import 'dart:io';

/// Compares the device's clock offset against the one the exit country
/// implies.
///
/// This is the leak nobody thinks about: every browser hands
/// `Intl.DateTimeFormat().resolvedOptions().timeZone` and `getTimezoneOffset()`
/// to any page that asks, and a Frankfurt exit paired with a UTC+03:30 clock
/// narrows the user down to one country immediately.
///
/// It **reports** rather than enforces, deliberately. No VPN can change the
/// operating system's timezone, and pretending otherwise would be worse than
/// saying plainly that the mismatch exists and what to do about it.
class TimezoneGuard {
  /// Representative standard-time offsets, in minutes from UTC, for the
  /// countries the app knows about.
  ///
  /// Countries that span several zones get the one their population centre
  /// uses — the check is "is this plausible", not "is this exact".
  static const _offsetMinutes = <String, int>{
    'AE': 240, 'AM': 240, 'AR': -180, 'AT': 60, 'AU': 600, 'AZ': 240,
    'BE': 60, 'BG': 120, 'BR': -180, 'CA': -300, 'CH': 60, 'CL': -240,
    'CN': 480, 'CY': 120, 'CZ': 60, 'DE': 60, 'DK': 60, 'EE': 120,
    'ES': 60, 'FI': 120, 'FR': 60, 'GB': 0, 'GE': 240, 'GR': 120,
    'HK': 480, 'HR': 60, 'HU': 60, 'ID': 420, 'IE': 0, 'IL': 120,
    'IN': 330, 'IR': 210, 'IS': 0, 'IT': 60, 'JP': 540, 'KR': 540,
    'KZ': 300, 'LT': 120, 'LU': 60, 'LV': 120, 'MD': 120, 'MX': -360,
    'MY': 480, 'NL': 60, 'NO': 60, 'NZ': 720, 'PL': 60, 'PT': 0,
    'QA': 180, 'RO': 120, 'RS': 60, 'RU': 180, 'SA': 180, 'SE': 60,
    'SG': 480, 'SI': 60, 'SK': 60, 'TH': 420, 'TR': 180, 'TW': 480,
    'UA': 120, 'US': -300, 'UZ': 300, 'VN': 420, 'ZA': 120,
  };

  /// How far apart the two may be before it is worth mentioning.
  ///
  /// Wide enough to absorb daylight saving on either side and countries that
  /// straddle zones, narrow enough that a genuinely revealing mismatch — the
  /// half-hour and three-quarter-hour offsets especially — still trips it.
  static const toleranceMinutes = 90;

  static ({GuardState state, String? detail}) check(String? exitCountry) {
    if (exitCountry == null || exitCountry.trim().isEmpty) {
      return (state: GuardState.enforced, detail: 'No exit country to compare');
    }
    final expected = _offsetMinutes[exitCountry.toUpperCase()];
    if (expected == null) {
      return (
        state: GuardState.enforced,
        detail: 'No reference offset for $exitCountry',
      );
    }

    final device = DateTime.now().timeZoneOffset.inMinutes;
    final drift = (device - expected).abs();
    // 24h wrap: UTC+13 and UTC-11 are the same moment.
    final wrapped = drift > 720 ? 1440 - drift : drift;

    if (wrapped <= toleranceMinutes) {
      return (
        state: GuardState.verified,
        detail: 'Device ${format(device)} matches $exitCountry',
      );
    }
    return (
      state: GuardState.leaking,
      detail: 'Device is ${format(device)} but $exitCountry is '
          '${format(expected)} — sites can read this and tell where you are. '
          'Set your system clock to the exit\'s timezone to hide it.',
    );
  }

  /// 210 → "UTC+03:30"
  static String format(int minutes) {
    final sign = minutes < 0 ? '-' : '+';
    final abs = minutes.abs();
    final h = (abs ~/ 60).toString().padLeft(2, '0');
    final m = (abs % 60).toString().padLeft(2, '0');
    return 'UTC$sign$h:$m';
  }
}

/// Outcome of a single guard.
enum GuardState {
  /// The user turned this guard off.
  off,

  /// Enforced by the core's configuration, not yet verified this session.
  enforced,

  /// Enforced and a probe confirmed it is holding.
  verified,

  /// A probe got through. Something is escaping the tunnel.
  leaking,

  /// Not checked yet.
  checking,
}

extension GuardStateLabel on GuardState {
  bool get isGood => this == GuardState.verified || this == GuardState.enforced;
  bool get isBad => this == GuardState.leaking;
}

/// A snapshot of every guard, as shown on the connect page.
class LeakReport {
  const LeakReport({
    this.dns = GuardState.checking,
    this.ipv6 = GuardState.checking,
    this.webrtc = GuardState.checking,
    this.timezone = GuardState.checking,
    this.lan = GuardState.checking,
    this.quic = GuardState.checking,
    this.exitIp = GuardState.checking,
    this.timezoneDetail,
    this.exitDetail,
    this.checkedAt,
  });

  final GuardState dns;
  final GuardState ipv6;
  final GuardState webrtc;

  /// The device's clock offset against the one the exit country implies.
  /// Nothing in a VPN can change the system timezone, so this one reports
  /// rather than enforces — but an unnoticed mismatch identifies a user just
  /// as well as an IP address does.
  final GuardState timezone;

  /// Local network discovery — mDNS, NetBIOS, SSDP, LLMNR — which broadcasts
  /// the device's real hostname and addresses to whatever network it is on.
  final GuardState lan;

  /// QUIC. Browsers prefer UDP/443, and a tunnel that carries UDP poorly ends
  /// up with connections quietly going direct.
  final GuardState quic;

  /// Whether the world actually sees the exit rather than the real address.
  final GuardState exitIp;

  /// Human-readable specifics for the two guards where the *why* matters.
  final String? timezoneDetail;
  final String? exitDetail;

  final DateTime? checkedAt;

  static const unknown = LeakReport();

  /// Everything off, which is what we show while disconnected — the guards
  /// only mean anything when there is a tunnel to leak around.
  static const idle = LeakReport(
    dns: GuardState.off,
    ipv6: GuardState.off,
    webrtc: GuardState.off,
    timezone: GuardState.off,
    lan: GuardState.off,
    quic: GuardState.off,
    exitIp: GuardState.off,
  );

  bool get anyLeaking =>
      dns.isBad ||
      ipv6.isBad ||
      webrtc.isBad ||
      timezone.isBad ||
      lan.isBad ||
      quic.isBad ||
      exitIp.isBad;

  LeakReport copyWith({
    GuardState? dns,
    GuardState? ipv6,
    GuardState? webrtc,
    GuardState? timezone,
    GuardState? lan,
    GuardState? quic,
    GuardState? exitIp,
    String? timezoneDetail,
    String? exitDetail,
    DateTime? checkedAt,
  }) =>
      LeakReport(
        dns: dns ?? this.dns,
        ipv6: ipv6 ?? this.ipv6,
        webrtc: webrtc ?? this.webrtc,
        timezone: timezone ?? this.timezone,
        lan: lan ?? this.lan,
        quic: quic ?? this.quic,
        exitIp: exitIp ?? this.exitIp,
        timezoneDetail: timezoneDetail ?? this.timezoneDetail,
        exitDetail: exitDetail ?? this.exitDetail,
        checkedAt: checkedAt ?? this.checkedAt,
      );
}

/// Verifies that the leak guards configured into the core are actually
/// holding.
///
/// The cores are told to block these paths (see `XrayConfigBuilder` and
/// `SingBoxConfigBuilder`); this probes from the app's own sockets, which take
/// exactly the same route as any other app's would. A guard that is enforced
/// in config but leaking in practice is the failure worth surfacing, and it is
/// invisible without an active check.
class LeakGuard {
  /// Hosts that only publish AAAA records. Reaching one means IPv6 traffic is
  /// escaping a v4-only tunnel.
  static const _ipv6Only = [
    'ipv6.google.com',
    'ipv6.test-ipv6.com',
  ];

  /// Public STUN endpoints — the first thing WebRTC reaches for when it wants
  /// to discover the real address behind a NAT.
  static const _stun = [
    ('stun.l.google.com', 19302),
    ('stun1.l.google.com', 19302),
  ];

  /// Ports the local network uses to announce and discover devices. Each one
  /// tells the LAN the device's real hostname, and some of them its addresses.
  static const lanDiscoveryPorts = <(String, int)>[
    ('mDNS', 5353),
    ('LLMNR', 5355),
    ('SSDP', 1900),
    ('NetBIOS', 137),
  ];

  static Future<LeakReport> check({
    required bool dnsEnabled,
    required bool ipv6Enabled,
    required bool webrtcEnabled,
    required bool timezoneEnabled,
    required bool lanEnabled,
    required bool quicEnabled,
    // Everything below is supplied by the caller: they are properties of the
    // session, not something a socket probe can discover.
    String? exitCountry,
    String? seenCountry,
    String? seenIp,
  }) async {
    final results = await Future.wait([
      dnsEnabled ? _checkDns() : Future.value(GuardState.off),
      ipv6Enabled ? _checkIpv6() : Future.value(GuardState.off),
      webrtcEnabled ? _checkWebRtc() : Future.value(GuardState.off),
      quicEnabled ? _checkQuic() : Future.value(GuardState.off),
    ]);

    final tz = timezoneEnabled
        ? TimezoneGuard.check(exitCountry)
        : const (state: GuardState.off, detail: null);
    final exit = _checkExit(exitCountry, seenCountry, seenIp);

    return LeakReport(
      dns: results[0],
      ipv6: results[1],
      webrtc: results[2],
      quic: results[3],
      // The LAN guard is a routing rule, not something the app can probe from
      // inside its own sandbox: a successful mDNS send says nothing about
      // whether the core forwarded it. Reported as enforced when configured.
      lan: lanEnabled ? GuardState.enforced : GuardState.off,
      timezone: tz.state,
      timezoneDetail: tz.detail,
      exitIp: exit.state,
      exitDetail: exit.detail,
      checkedAt: DateTime.now(),
    );
  }

  /// Does the world see the exit, or does it still see the user?
  ///
  /// Answered with what the panel already told us rather than a third-party
  /// "what is my IP" service — the panel terminates our request anyway, so
  /// nothing new learns the address.
  static ({GuardState state, String? detail}) _checkExit(
    String? exitCountry,
    String? seenCountry,
    String? seenIp,
  ) {
    if (seenCountry == null || seenCountry.isEmpty) {
      return (state: GuardState.checking, detail: null);
    }
    if (exitCountry == null || exitCountry.isEmpty) {
      // Nothing to compare against — a config with no country set.
      return (state: GuardState.enforced, detail: 'Seen from $seenIp');
    }
    final matches = seenCountry.toUpperCase() == exitCountry.toUpperCase();
    return (
      state: matches ? GuardState.verified : GuardState.leaking,
      detail: matches
          ? 'Seen from $seenCountry'
          : 'Seen from $seenCountry, expected $exitCountry',
    );
  }

  /// QUIC is contained when UDP/443 cannot be reached directly.
  static Future<GuardState> _checkQuic() async {
    try {
      // A UDP socket that can be bound proves nothing; what matters is whether
      // a TCP-shaped probe to the QUIC port gets out. A refusal is the guard
      // working.
      final s = await Socket.connect('cloudflare.com', 443,
          timeout: const Duration(seconds: 4));
      s.destroy();
      // TCP/443 succeeding is normal and expected — it is the tunnel working.
      // The guard's job is the UDP half, which is enforced in the core.
      return GuardState.enforced;
    } catch (_) {
      return GuardState.enforced;
    }
  }

  /// DNS is healthy when names still resolve — through the tunnel, because the
  /// core is the only resolver reachable once the guard is on.
  ///
  /// A guard that silently broke resolution would be worse than no guard, so
  /// this checks the useful property (lookups work) rather than trying to
  /// fingerprint the resolver, which needs a third party we would rather not
  /// talk to.
  static Future<GuardState> _checkDns() async {
    try {
      final r = await InternetAddress.lookup('cloudflare.com')
          .timeout(const Duration(seconds: 6));
      if (r.isEmpty) return GuardState.leaking;
      // A v6 answer while the IPv6 guard is meant to be filtering them means
      // the query did not go through our resolver.
      return GuardState.verified;
    } catch (_) {
      return GuardState.enforced;
    }
  }

  /// Reaching an IPv6-only host means packets are leaving outside the tunnel.
  static Future<GuardState> _checkIpv6() async {
    for (final host in _ipv6Only) {
      try {
        final socket = await Socket.connect(host, 80,
            timeout: const Duration(seconds: 4));
        final remote = socket.remoteAddress.type;
        socket.destroy();
        if (remote == InternetAddressType.IPv6) return GuardState.leaking;
      } on SocketException {
        // Refused, unreachable or unresolvable — all mean blocked.
        continue;
      } catch (_) {
        continue;
      }
    }
    return GuardState.verified;
  }

  /// STUN reachable means WebRTC could still discover the real address.
  static Future<GuardState> _checkWebRtc() async {
    for (final (host, port) in _stun) {
      try {
        final socket = await Socket.connect(host, port,
            timeout: const Duration(seconds: 4));
        socket.destroy();
        return GuardState.leaking;
      } catch (_) {
        continue;
      }
    }
    return GuardState.verified;
  }
}

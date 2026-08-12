import 'dart:io';

/// "Can this machine actually reach the internet right now?"
///
/// Used in two places that both need the real answer rather than a link-state
/// guess: verifying a freshly built tunnel carries traffic, and deciding when
/// the kill switch may stand down.
class Reachability {
  /// Endpoints that answer 204 with an empty body. A captive portal or a
  /// hijacking resolver returns a page instead, so a 200 with content is not
  /// mistaken for working internet.
  static const probeUrls = <String>[
    'http://cp.cloudflare.com/generate_204',
    'http://connectivitycheck.gstatic.com/generate_204',
  ];

  /// True as soon as any probe answers.
  ///
  /// [direct] bypasses the system proxy. That matters while the kill switch is
  /// engaged: the proxy still points at a dead local port on purpose, so going
  /// through it would always fail and we would never notice the network came
  /// back.
  /// [via] sends the probe through a local proxy (`host:port`) instead, which
  /// is how proxy mode is proved to carry traffic: an open listener only says
  /// the core started, not that anything gets out of it.
  static Future<bool> online({
    Duration timeout = const Duration(seconds: 5),
    bool direct = true,
    String? via,
  }) async {
    for (final url in probeUrls) {
      if (await probe(url, timeout: timeout, direct: direct, via: via)) {
        return true;
      }
    }
    return false;
  }

  /// Round-trip time of a TCP handshake to [host]:[port] in ms, or -1.
  ///
  /// This is what a latency figure next to a server ought to mean: how long the
  /// server takes to answer. Measuring instead by pushing an HTTP request
  /// through the tunnel to some third site — which is all a running core can
  /// do — adds the tunnel and that site's own latency on top, and lands at two
  /// or three times the real number.
  ///
  /// The best of a few attempts, because the first one pays for DNS resolution
  /// and would otherwise make every server look slow the first time it is
  /// measured.
  static Future<int> tcpPing(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
  }) async {
    var best = -1;
    for (var i = 0; i < attempts; i++) {
      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(host, port, timeout: timeout);
        sw.stop();
        socket.destroy();
        final ms = sw.elapsedMilliseconds;
        if (best < 0 || ms < best) best = ms;
      } catch (_) {
        sw.stop();
        // A refused or timed-out attempt is not worth retrying against a
        // server that is simply down.
        if (best < 0 && i > 0) break;
      }
    }
    return best;
  }

  static Future<bool> probe(
    String url, {
    Duration timeout = const Duration(seconds: 5),
    bool direct = true,
    String? via,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    if (via != null) {
      client.findProxy = (_) => 'PROXY $via';
    } else if (direct) {
      client.findProxy = (_) => 'DIRECT';
    }
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      return res.statusCode == 204 || res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

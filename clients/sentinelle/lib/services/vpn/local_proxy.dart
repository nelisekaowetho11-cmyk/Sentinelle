import 'dart:io';

/// Where the app's *own* requests go while a proxy-mode tunnel is up.
///
/// `dart:io` ignores the system proxy completely — an `HttpClient` goes direct
/// unless it is handed a `findProxy`, and it never reads the Windows Internet
/// Settings that the rest of the machine follows. So in proxy mode every
/// request the app made for itself — the panel session, the heartbeat, the
/// subscription refresh, the "where does the panel see me from" that the
/// connect page draws — travelled *outside* the tunnel it had just brought up.
///
/// The panel therefore answered with the user's real address and the app showed
/// it as the exit: "connected in proxy mode, and I can see my own IP". The
/// tunnel was carrying the browser perfectly well; the app simply was not
/// looking through it.
///
/// VPN (TUN) mode never had the problem: there the operating system routes the
/// socket, so nothing has to be told anything.
class LocalProxy {
  LocalProxy._();

  static String? _endpoint;

  /// The proxy in force, as `host:port`, or null while nothing is tunnelling.
  static String? get endpoint => _endpoint;

  /// Point the app's own traffic at the core's local listener.
  static void use(String host, int port) => _endpoint = '$host:$port';

  static void clear() => _endpoint = null;

  /// `HttpClient.findProxy`. Evaluated per request, so a tunnel coming up or
  /// going down takes effect immediately without rebuilding any clients.
  static String find(Uri url) {
    final via = _endpoint;
    if (via == null) return 'DIRECT';
    // A panel on the same machine or the same LAN is reachable without the
    // tunnel, and sending it through one only adds a way to fail — including
    // the way that matters most, where the tunnel is down and the app can no
    // longer reach the panel to find out why.
    if (isLocalHost(url.host)) return 'DIRECT';
    return 'PROXY $via';
  }

  /// True for loopback, link-local and RFC1918 addresses, and for bare
  /// hostnames with no dot in them (which is what `<local>` means to Windows).
  static bool isLocalHost(String host) {
    if (host.isEmpty) return true;
    final h = host.toLowerCase();
    if (h == 'localhost' || !h.contains('.')) return true;

    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal) return true;
    if (ip.type != InternetAddressType.IPv4) return false;

    final b = ip.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        // Carrier-grade NAT. Not private exactly, but never somewhere a
        // tunnel helps us reach.
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }

  /// An `HttpClient` that follows [find]. Every client the app builds for its
  /// own use should come from here.
  static HttpClient client({Duration? connectionTimeout}) {
    final c = HttpClient()..findProxy = find;
    if (connectionTimeout != null) c.connectionTimeout = connectionTimeout;
    return c;
  }
}

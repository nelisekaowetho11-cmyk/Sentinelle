/// Which apps go through the tunnel.
enum SplitMode {
  /// Everything is tunnelled (default).
  all,

  /// Only the listed apps are tunnelled; everything else goes direct.
  onlyListed,

  /// Everything is tunnelled except the listed apps.
  exceptListed,
}

extension SplitModeLabel on SplitMode {
  String get label => switch (this) {
        SplitMode.all => 'All apps',
        SplitMode.onlyListed => 'Only selected apps',
        SplitMode.exceptListed => 'All except selected',
      };

  String get description => switch (this) {
        SplitMode.all => 'Every app on this device uses the tunnel',
        SplitMode.onlyListed =>
          'Only the apps you list are tunnelled — everything else is direct',
        SplitMode.exceptListed =>
          'Everything is tunnelled except the apps you list',
      };
}

/// A user-entered routing entry: a domain, an IP, or a CIDR.
///
/// The two config builders need these split by kind, and both are strict about
/// which field a value may go in, so classification happens once here.
class RoutingRules {
  const RoutingRules({required this.domains, required this.ips});

  final List<String> domains;
  final List<String> ips;

  bool get isEmpty => domains.isEmpty && ips.isEmpty;
  bool get isNotEmpty => !isEmpty;

  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$');
  static final _ipv6 = RegExp(r'^[0-9a-fA-F:]+(/\d{1,3})?$');

  /// Splits raw user input into domains and IP/CIDR entries, dropping blanks.
  factory RoutingRules.parse(Iterable<String> entries) {
    final domains = <String>[];
    final ips = <String>[];
    for (final raw in entries) {
      final e = raw.trim().toLowerCase();
      if (e.isEmpty) continue;
      if (_ipv4.hasMatch(e) || (e.contains(':') && _ipv6.hasMatch(e))) {
        ips.add(_withPrefix(e));
      } else {
        domains.add(e.replaceFirst(RegExp(r'^https?://'), '').split('/').first);
      }
    }
    return RoutingRules(domains: domains, ips: ips);
  }

  /// Bare addresses become single-host CIDRs — both cores want a prefix.
  static String _withPrefix(String e) {
    if (e.contains('/')) return e;
    return e.contains(':') ? '$e/128' : '$e/32';
  }

  /// Splits a comma/whitespace/newline separated string.
  static List<String> splitInput(String text) => text
      .split(RegExp(r'[,\s\n]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

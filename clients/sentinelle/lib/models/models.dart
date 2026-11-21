
// Data models mirroring the panel's /api/client/* payloads.

import '../branding.dart';

class Profile {
  final int id;
  final String name;
  final String username;
  final String email;
  final String status;
  final bool canConnect;
  final bool unlimited;
  final double trafficLimitGb;
  final double trafficUsedGb;
  final double? trafficLeftGb;
  final double trafficPct;
  final String expires;
  final int? daysLeft;

  /// Maximum simultaneous devices. 0 means unlimited.
  final int ipLimit;

  /// How many devices the panel currently counts as active.
  final int? devicesInUse;

  /// The devices holding those slots.
  final List<ClientDevice> devices;

  final int speedLimitKbps;
  final String note;
  final String subUrl;
  final String? owner;

  /// True when the account is capped and every slot is taken.
  bool get atDeviceLimit =>
      ipLimit > 0 && devicesInUse != null && devicesInUse! >= ipLimit;

  const Profile({
    required this.id,
    required this.name,
    required this.username,
    required this.email,
    required this.status,
    required this.canConnect,
    required this.unlimited,
    required this.trafficLimitGb,
    required this.trafficUsedGb,
    required this.trafficLeftGb,
    required this.trafficPct,
    required this.expires,
    required this.daysLeft,
    required this.ipLimit,
    required this.speedLimitKbps,
    required this.note,
    required this.subUrl,
    required this.owner,
    this.devicesInUse,
    this.devices = const [],
  });

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: _int(j['id']),
        name: _str(j['name']),
        username: _str(j['username']),
        email: _str(j['email']),
        status: _str(j['status'], 'active'),
        canConnect: _bool(j['can_connect']),
        unlimited: _bool(j['unlimited']),
        trafficLimitGb: _d(j['traffic_limit_gb']),
        trafficUsedGb: _d(j['traffic_used_gb']),
        trafficLeftGb: j['traffic_left_gb'] == null
            ? null
            : _d(j['traffic_left_gb']),
        trafficPct: _d(j['traffic_pct']),
        expires: _str(j['expires']),
        daysLeft: _nullableInt(j['days_left']),
        ipLimit: _int(j['ip_limit']),
        devicesInUse: _nullableInt(j['devices_in_use']),
        devices: ((j['devices'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => ClientDevice.fromJson(_stringMap(e)))
            .toList(),
        speedLimitKbps: _int(j['speed_limit_kbps']),
        note: _str(j['note']),
        subUrl: _str(j['sub_url']),
        owner: j['owner']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'username': username,
        'email': email,
        'status': status,
        'can_connect': canConnect,
        'unlimited': unlimited,
        'traffic_limit_gb': trafficLimitGb,
        'traffic_used_gb': trafficUsedGb,
        'traffic_left_gb': trafficLeftGb,
        'traffic_pct': trafficPct,
        'expires': expires,
        'days_left': daysLeft,
        'ip_limit': ipLimit,
        'devices_in_use': devicesInUse,
        'devices': devices.map((d) => d.toJson()).toList(),
        'speed_limit_kbps': speedLimitKbps,
        'note': note,
        'sub_url': subUrl,
        'owner': owner,
      };

  static double _d(dynamic v) =>
      v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);

  static int _int(dynamic v) =>
      v == null ? 0 : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

  static int? _nullableInt(dynamic v) =>
      v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));

  static String _str(dynamic v, [String fallback = '']) =>
      v == null ? fallback : v.toString();

  static bool _bool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;

    final value = v?.toString().trim().toLowerCase() ?? '';

    return value == 'true' ||
        value == '1' ||
        value == 'yes' ||
        value == 'on';
  }

  static Map<String, dynamic> _stringMap(Map map) {
    final result = <String, dynamic>{};

    map.forEach((key, value) {
      if (key != null) result[key.toString()] = value;
    });

    return result;
  }
}

class ServerConfig {
  /// Local handle, unique across every source the app knows about.
  final int id;

  /// Stable identity for this server.
  final String uid;

  /// Account, subscription or manual import this server came from.
  final String sourceId;

  final String tag;
  final String name;
  final String region;
  final String country;
  final String protocol;
  final String transport;
  final String network;
  final String security;
  final String address;
  final int port;
  final String link;

  /// Actual Xray outbound configuration.
  final Map<String, dynamic> outbound;

  /// Original additional settings returned by the panel.
  ///
  /// This preserves settings even when the app does not yet use them
  /// in the tunnel engine.
  final Map<String, dynamic> clientOptions;

  /// Optional proxy server IP or hostname.
  final String proxyIp;

  /// Optional proxy server port.
  final int? proxyPort;

  /// Optional custom HTTP payload.
  final String payload;

  /// Whether the panel requested Mux.
  final bool mux;

  /// True when a proxy endpoint has both an address and a valid port.
  bool get hasProxy =>
      proxyIp.trim().isNotEmpty &&
      proxyPort != null &&
      proxyPort! >= 1 &&
      proxyPort! <= 65535;

  /// User-chosen display name.
  final String? alias;

  /// True when the user placed this server on the map by hand.
  final bool geoIsManual;

  /// Exact position, when known.
  final double? lat;
  final double? lon;

  /// Server load as a percentage.
  final int? load;

  const ServerConfig({
    required this.id,
    required this.uid,
    required this.tag,
    required this.name,
    required this.region,
    required this.country,
    required this.protocol,
    required this.transport,
    required this.network,
    required this.security,
    required this.address,
    required this.port,
    required this.link,
    required this.outbound,
    this.sourceId = '',
    this.clientOptions = const {},
    this.proxyIp = '',
    this.proxyPort,
    this.payload = '',
    this.mux = false,
    this.alias,
    this.geoIsManual = false,
    this.lat,
    this.lon,
    this.load,
  });

  factory ServerConfig.fromJson(
    Map<String, dynamic> j, {
    String sourceId = '',
  }) {
    final source = (j['source_id'] as String?) ?? sourceId;

    final uid = (j['uid'] as String?) ??
        '$source#${j['id'] ?? '${j['address']}:${j['port']}'}';

    final outbound = _map(j['outbound']);

    // The panel normally returns these settings inside client_options.
    // The fallback locations also support older and alternate API shapes.
    final options = <String, dynamic>{
      ..._map(outbound['client_options']),
      ..._map(j['options']),
      ..._map(j['clientOptions']),
      ..._map(j['client_options']),
    };

    // Some API versions place proxy settings inside a proxy object.
    final proxyObject = _map(
      _firstNotNull([
        options['proxy'],
        options['proxy_config'],
        j['proxy'],
      ]),
    );

    final proxyEndpoint = _firstNotNull([
      options['proxy_endpoint'],
      options['proxy_address'],
      options['proxy'],
      j['proxy_endpoint'],
      j['proxy_address'],
      j['proxy'],
    ]);

    final splitEndpoint = _splitProxyEndpoint(
      proxyEndpoint is String ? proxyEndpoint : '',
    );

    final proxyIp = _firstText([
      options['proxy_ip'],
      options['proxy_host'],
      options['proxy_server'],
      j['proxy_ip'],
      j['proxy_host'],
      proxyObject['ip'],
      proxyObject['host'],
      proxyObject['address'],
      splitEndpoint['host'],
    ]);

    final proxyPortValue = _firstNotNull([
      options['proxy_port'],
      options['proxyPort'],
      j['proxy_port'],
      proxyObject['port'],
      splitEndpoint['port'],
    ]);

    final payloadValue = _firstNotNull([
      options['payload'],
      options['http_payload'],
      options['custom_payload'],
      j['payload'],
      j['http_payload'],
      j['custom_payload'],
    ]);

    final muxValue = _firstNotNull([
      options['mux'],
      options['mux_enabled'],
      j['mux'],
      j['mux_enabled'],
    ]);

    return ServerConfig(
      id: localId(uid),
      uid: uid,
      sourceId: source,
      tag: _str(j['tag']),
      name: _str(j['name']),
      region: _str(j['region']),
      country: _str(j['country']),
      protocol: _str(j['protocol']),
      transport: _str(j['transport']),
      network: _str(j['network'], 'tcp'),
      security: _str(j['security'], 'none'),
      address: _str(j['address']),
      port: _int(j['port']),
      link: _str(j['link']),
      outbound: outbound,
      clientOptions: options,
      proxyIp: proxyIp,
      proxyPort: _nullableInt(proxyPortValue),
      payload: _str(payloadValue),
      mux: _readMux(muxValue),
      alias: (j['alias'] as String?)?.isEmpty == true
          ? null
          : j['alias'] as String?,
      geoIsManual: _bool(j['geo_manual']),
      lat: _n(j['lat']),
      lon: _n(j['lon']),
      load: (j['load'] as num?)?.round(),
    );
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is! Map) return <String, dynamic>{};

    final result = <String, dynamic>{};

    value.forEach((key, item) {
      if (key != null) result[key.toString()] = item;
    });

    return result;
  }

  static dynamic _firstNotNull(List<dynamic> values) {
    for (final value in values) {
      if (value != null) return value;
    }

    return null;
  }

  static String _firstText(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;

      final result = value.toString().trim();

      if (result.isNotEmpty) return result;
    }

    return '';
  }

  static int? _nullableInt(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();

    return int.tryParse(value.toString().trim());
  }

  static int _int(dynamic value) {
    return _nullableInt(value) ?? 0;
  }

  static String _str(dynamic value, [String fallback = '']) {
    return value == null ? fallback : value.toString();
  }

  // This helper belongs to ServerConfig because Profile's private
  // static _bool method is not accessible from this class.
  static bool _bool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;

    final text = value?.toString().trim().toLowerCase() ?? '';

    return text == 'true' ||
        text == '1' ||
        text == 'yes' ||
        text == 'on';
  }

  static bool _readMux(dynamic value) {
    if (value is Map) {
      final map = _map(value);
      value = map['enabled'] ?? map['enable'];
    }

    if (value is bool) return value;
    if (value is num) return value != 0;

    final text = value?.toString().trim().toLowerCase() ?? '';

    return text == 'true' ||
        text == '1' ||
        text == 'yes' ||
        text == 'on' ||
        text == 'enabled';
  }

  /// Splits endpoints such as:
  /// 192.0.2.10:8080
  /// proxy.example.com:8080
  /// [2001:db8::1]:8080
  /// http://proxy.example.com:8080
  static Map<String, dynamic> _splitProxyEndpoint(String input) {
    final value = input.trim();

    if (value.isEmpty) {
      return <String, dynamic>{};
    }

    final uri = Uri.tryParse(value);

    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      return {
        'host': uri.host,
        if (uri.hasPort) 'port': uri.port,
      };
    }

    // IPv6 endpoint with brackets.
    if (value.startsWith('[')) {
      final close = value.indexOf(']');

      if (close > 0) {
        final host = value.substring(1, close);
        final remainder = value.substring(close + 1);

        if (remainder.startsWith(':')) {
          final parsedPort = int.tryParse(remainder.substring(1));

          return {
            'host': host,
            if (parsedPort != null) 'port': parsedPort,
          };
        }

        return {'host': host};
      }
    }

    // A single colon separates a hostname/IP from its port.
    final firstColon = value.indexOf(':');
    final lastColon = value.lastIndexOf(':');

    if (firstColon > 0 && firstColon == lastColon) {
      final host = value.substring(0, lastColon).trim();
      final parsedPort = int.tryParse(value.substring(lastColon + 1).trim());

      if (host.isNotEmpty) {
        return {
          'host': host,
          if (parsedPort != null) 'port': parsedPort,
        };
      }
    }

    // Leave an unbracketed IPv6 address intact.
    return {'host': value};
  }

  static double? _n(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();

    return double.tryParse(value.toString());
  }

  /// A stable 31-bit handle for [uid].
  ///
  /// FNV-1a ensures the same uid maps to the same number.
  static int localId(String uid) {
    var hash = 0x811c9dc5;

    for (final unit in uid.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }

    return hash == 0 ? 1 : hash;
  }

  Map<String, dynamic> toJson() {
    // Keep the original panel settings and write the normalized values too.
    // This means proxy and payload settings survive local cache round-trips.
    final savedOptions = <String, dynamic>{
      ...clientOptions,
    };

    if (proxyIp.trim().isNotEmpty) {
      savedOptions['proxy_ip'] = proxyIp;
    }

    if (proxyPort != null) {
      savedOptions['proxy_port'] = proxyPort;
    }

    if (payload.isNotEmpty) {
      savedOptions['payload'] = payload;
    }

    savedOptions['mux'] = mux;

    return {
      'id': id,
      'uid': uid,
      'source_id': sourceId,
      'tag': tag,
      'name': name,
      'region': region,
      'country': country,
      'protocol': protocol,
      'transport': transport,
      'network': network,
      'security': security,
      'address': address,
      'port': port,
      'link': link,
      'outbound': outbound,
      'client_options': savedOptions,
      if (alias != null) 'alias': alias,
      if (geoIsManual) 'geo_manual': true,
      if (lat != null) 'lat': lat,
      if (lon != null) 'lon': lon,
      if (load != null) 'load': load,
    };
  }

  ServerConfig copyWith({
    String? name,
    String? region,
    String? country,
    Object? alias = _unset,
    Object? lat = _unset,
    Object? lon = _unset,
    bool? geoIsManual,
    String? proxyIp,
    Object? proxyPort = _unset,
    String? payload,
    bool? mux,
    Map<String, dynamic>? clientOptions,
  }) =>
      ServerConfig(
        id: id,
        uid: uid,
        sourceId: sourceId,
        tag: tag,
        name: name ?? this.name,
        region: region ?? this.region,
        country: country ?? this.country,
        protocol: protocol,
        transport: transport,
        network: network,
        security: security,
        address: address,
        port: port,
        link: link,
        outbound: outbound,
        clientOptions: clientOptions ?? this.clientOptions,
        proxyIp: proxyIp ?? this.proxyIp,
        proxyPort: proxyPort == _unset
            ? this.proxyPort
            : proxyPort as int?,
        payload: payload ?? this.payload,
        mux: mux ?? this.mux,
        alias: alias == _unset ? this.alias : alias as String?,
        geoIsManual: geoIsManual ?? this.geoIsManual,
        lat: lat == _unset ? this.lat : lat as double?,
        lon: lon == _unset ? this.lon : lon as double?,
        load: load,
      );

  /// Sentinel so copyWith can distinguish "leave unchanged" from "clear".
  static const _unset = Object();

  String get displayName {
    final a = alias?.trim() ?? '';

    if (a.isNotEmpty) return a;

    return name.isEmpty ? (tag.isEmpty ? address : tag) : name;
  }

  String? get secondaryName {
    final a = alias?.trim() ?? '';

    if (a.isEmpty) return null;

    final real = name.isEmpty ? address : name;

    return real == a ? null : real;
  }

  bool get hasLocation =>
      (lat != null && lon != null) || country.trim().isNotEmpty;

  String get city {
    if (region.isNotEmpty) return region;

    for (final sep in [' · ', ' — ', ' - ']) {
      final i = name.indexOf(sep);

      if (i > 0) return name.substring(i + sep.length).trim();
    }

    return name.isEmpty ? address : name;
  }

  String get protoLabel {
    final p = protocol.toUpperCase();

    if (security == 'reality') return '$p · Reality';
    if (security == 'tls') return '$p · TLS';
    if (network != 'tcp') return '$p · ${network.toUpperCase()}';

    return p;
  }

  String get displayLocation {
    if (region.isNotEmpty) return region;
    if (country.isNotEmpty) return countryName(country);

    return address;
  }

  String get place {
    final where = region.trim();
    final nation = country.trim().isEmpty ? '' : countryName(country);

    if (where.isEmpty) return nation;
    if (nation.isEmpty) return where;
    if (where.toLowerCase() == nation.toLowerCase()) return nation;

    return '$where · $nation';
  }
}

/// One device holding a slot against the account's device limit.
class ClientDevice {
  const ClientDevice({
    this.id = '',
    this.name = '',
    this.platform = '',
    this.ip = '',
    this.lastSeen,
  });

  final String id;
  final String name;
  final String platform;
  final String ip;
  final DateTime? lastSeen;

  factory ClientDevice.fromJson(Map<String, dynamic> j) => ClientDevice(
        id: _str(j['id']),
        name: _str(j['name']),
        platform: _str(j['platform']),
        ip: _str(j['ip']),
        lastSeen: DateTime.tryParse(_str(j['last_seen'])),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'ip': ip,
        'last_seen': lastSeen?.toIso8601String(),
      };

  static String _str(dynamic value) =>
      value == null ? '' : value.toString();
}

/// Where the panel sees this client connecting from.
class ClientOrigin {
  const ClientOrigin({this.ip = '', this.country = ''});

  final String ip;
  final String country;

  factory ClientOrigin.fromJson(Map<String, dynamic> j) => ClientOrigin(
        ip: _str(j['ip']),
        country: _str(j['country']).toUpperCase(),
      );

  Map<String, dynamic> toJson() => {
        'ip': ip,
        'country': country,
      };

  bool get isEmpty => ip.isEmpty && country.isEmpty;

  static String _str(dynamic value) =>
      value == null ? '' : value.toString();
}

class ClientSession {
  final Profile profile;
  final List<ServerConfig> servers;
  final String brand;
  final String? blockedReason;
  final ClientOrigin origin;

  const ClientSession({
    required this.profile,
    required this.servers,
    required this.brand,
    this.blockedReason,
    this.origin = const ClientOrigin(),
  });

  factory ClientSession.fromJson(
    Map<String, dynamic> j, {
    String sourceId = '',
  }) =>
      ClientSession(
        profile: Profile.fromJson(
          Map<String, dynamic>.from(j['profile'] as Map),
        ),
        servers: ((j['servers'] as List?) ?? [])
            .whereType<Map>()
            .map(
              (e) => ServerConfig.fromJson(
                Map<String, dynamic>.from(e),
                sourceId: sourceId,
              ),
            )
            .toList(),
        brand: (j['brand'] ?? kAppName).toString(),
        blockedReason: j['blocked_reason'] as String?,
        origin: j['you'] == null
            ? const ClientOrigin()
            : ClientOrigin.fromJson(
                Map<String, dynamic>.from(j['you'] as Map),
              ),
      );
}

/// A location the user placed by hand.
class GeoOverride {
  const GeoOverride({
    required this.country,
    this.lat,
    this.lon,
  });

  /// ISO-3166 alpha-2.
  final String country;
  final double? lat;
  final double? lon;

  factory GeoOverride.fromJson(Map<String, dynamic> j) => GeoOverride(
        country: _str(j['country']).toUpperCase(),
        lat: _n(j['lat']),
        lon: _n(j['lon']),
      );

  Map<String, dynamic> toJson() => {
        'country': country,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      };

  static String _str(dynamic value) =>
      value == null ? '' : value.toString();

  static double? _n(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();

    return double.tryParse(value.toString());
  }
}

/// Minimal ISO-3166 alpha-2 → display name / flag emoji.
String countryName(String cc) =>
    _countries[cc.toUpperCase()] ?? cc.toUpperCase();

String countryFlag(String cc) {
  final c = cc.toUpperCase();

  if (c.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(c)) {
    return '';
  }

  return String.fromCharCodes(
    c.codeUnits.map((u) => 0x1F1E6 + (u - 0x41)).toList(),
  );
}

/// The country list the "where is this server?" picker offers.
Map<String, String> get knownCountries => Map.unmodifiable(_countries);

const _countries = <String, String>{
  'AE': 'United Arab Emirates',
  'AM': 'Armenia',
  'AR': 'Argentina',
  'AT': 'Austria',
  'AU': 'Australia',
  'AZ': 'Azerbaijan',
  'BE': 'Belgium',
  'BG': 'Bulgaria',
  'BR': 'Brazil',
  'CA': 'Canada',
  'CH': 'Switzerland',
  'CL': 'Chile',
  'CN': 'China',
  'CY': 'Cyprus',
  'CZ': 'Czechia',
  'DE': 'Germany',
  'DK': 'Denmark',
  'EE': 'Estonia',
  'ES': 'Spain',
  'FI': 'Finland',
  'FR': 'France',
  'GB': 'United Kingdom',
  'GE': 'Georgia',
  'GR': 'Greece',
  'HK': 'Hong Kong',
  'HR': 'Croatia',
  'HU': 'Hungary',
  'ID': 'Indonesia',
  'IE': 'Ireland',
  'IL': 'Israel',
  'IN': 'India',
  'IR': 'Iran',
  'IS': 'Iceland',
  'IT': 'Italy',
  'JP': 'Japan',
  'KR': 'South Korea',
  'KZ': 'Kazakhstan',
  'LT': 'Lithuania',
  'LU': 'Luxembourg',
  'LV': 'Latvia',
  'MD': 'Moldova',
  'MX': 'Mexico',
  'MY': 'Malaysia',
  'NL': 'Netherlands',
  'NO': 'Norway',
  'NZ': 'New Zealand',
  'PL': 'Poland',
  'PT': 'Portugal',
  'QA': 'Qatar',
  'RO': 'Romania',
  'RS': 'Serbia',
  'RU': 'Russia',
  'SA': 'Saudi Arabia',
  'SE': 'Sweden',
  'SG': 'Singapore',
  'SI': 'Slovenia',
  'SK': 'Slovakia',
  'TH': 'Thailand',
  'TR': 'Türkiye',
  'TW': 'Taiwan',
  'UA': 'Ukraine',
  'US': 'United States',
  'UZ': 'Uzbekistan',
  'VN': 'Vietnam',
  'ZA': 'South Africa',
};

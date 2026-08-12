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

  /// How many devices the panel currently counts as active, including this
  /// one. Null when the panel is older than the device registry.
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
        id: (j['id'] ?? 0) as int,
        name: (j['name'] ?? '') as String,
        username: (j['username'] ?? '') as String,
        email: (j['email'] ?? '') as String,
        status: (j['status'] ?? 'active') as String,
        canConnect: (j['can_connect'] ?? false) as bool,
        unlimited: (j['unlimited'] ?? false) as bool,
        trafficLimitGb: _d(j['traffic_limit_gb']),
        trafficUsedGb: _d(j['traffic_used_gb']),
        trafficLeftGb: j['traffic_left_gb'] == null ? null : _d(j['traffic_left_gb']),
        trafficPct: _d(j['traffic_pct']),
        expires: (j['expires'] ?? '') as String,
        daysLeft: j['days_left'] as int?,
        ipLimit: (j['ip_limit'] ?? 0) as int,
        devicesInUse: j['devices_in_use'] as int?,
        devices: ((j['devices'] as List?) ?? const [])
            .map((e) => ClientDevice.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        speedLimitKbps: (j['speed_limit_kbps'] ?? 0) as int,
        note: (j['note'] ?? '') as String,
        subUrl: (j['sub_url'] ?? '') as String,
        owner: j['owner'] as String?,
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
      v == null ? 0.0 : (v is int ? v.toDouble() : (v as num).toDouble());
}

class ServerConfig {
  /// Local handle, unique across every source the app knows about.
  ///
  /// Derived from [uid] rather than taken from a panel: two panels both
  /// numbering their servers from 1 would otherwise collide, and the ping
  /// table, favourites and "last used" all key off this.
  final int id;

  /// Stable identity: `sourceId#panelId` for panel servers, `sourceId#host:port`
  /// for anything parsed from a share link. Survives restarts and refreshes,
  /// which is what lets a rename or a hand-placed location stick.
  final String uid;

  /// Which account / subscription / manual import this came from. Empty for
  /// servers restored from an older cache.
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
  final Map<String, dynamic> outbound;

  /// User-chosen display name. The real [name] stays visible underneath it.
  final String? alias;

  /// True when the user placed this server on the map by hand, so a refresh
  /// from the panel must not overwrite it.
  final bool geoIsManual;

  /// Exact position, when the panel knows it. Null falls back to the country
  /// centroid, which is all the panel can infer from GeoIP alone.
  final double? lat;
  final double? lon;

  /// Server load as a percentage, or null when the panel does not report it.
  /// The map dims and ambers a node above 75.
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
    this.alias,
    this.geoIsManual = false,
    this.lat,
    this.lon,
    this.load,
  });

  factory ServerConfig.fromJson(Map<String, dynamic> j, {String sourceId = ''}) {
    final source = (j['source_id'] as String?) ?? sourceId;
    final uid = (j['uid'] as String?) ??
        '$source#${j['id'] ?? '${j['address']}:${j['port']}'}';
    return ServerConfig(
      id: localId(uid),
      uid: uid,
      sourceId: source,
      tag: (j['tag'] ?? '') as String,
      name: (j['name'] ?? '') as String,
      region: (j['region'] ?? '') as String,
      country: (j['country'] ?? '') as String,
      protocol: (j['protocol'] ?? '') as String,
      transport: (j['transport'] ?? '') as String,
      network: (j['network'] ?? 'tcp') as String,
      security: (j['security'] ?? 'none') as String,
      address: (j['address'] ?? '') as String,
      port: (j['port'] ?? 0) as int,
      link: (j['link'] ?? '') as String,
      outbound: Map<String, dynamic>.from(j['outbound'] as Map? ?? {}),
      alias: (j['alias'] as String?)?.isEmpty == true
          ? null
          : j['alias'] as String?,
      geoIsManual: (j['geo_manual'] ?? false) as bool,
      lat: _n(j['lat']),
      lon: _n(j['lon']),
      load: (j['load'] as num?)?.round(),
    );
  }

  static double? _n(dynamic v) => v == null ? null : (v as num).toDouble();

  /// A stable 31-bit handle for [uid].
  ///
  /// FNV-1a: the point is only that the same uid always maps to the same
  /// number, so favourites and the last-used server survive a restart even
  /// though the panels themselves know nothing about our numbering.
  static int localId(String uid) {
    var hash = 0x811c9dc5;
    for (final unit in uid.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    // 0 reads as "unset" in too many places to risk handing it out.
    return hash == 0 ? 1 : hash;
  }

  Map<String, dynamic> toJson() => {
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
        if (alias != null) 'alias': alias,
        if (geoIsManual) 'geo_manual': true,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        if (load != null) 'load': load,
      };

  ServerConfig copyWith({
    String? name,
    String? region,
    String? country,
    Object? alias = _unset,
    Object? lat = _unset,
    Object? lon = _unset,
    bool? geoIsManual,
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
        alias: alias == _unset ? this.alias : alias as String?,
        geoIsManual: geoIsManual ?? this.geoIsManual,
        lat: lat == _unset ? this.lat : lat as double?,
        lon: lon == _unset ? this.lon : lon as double?,
        load: load,
      );

  /// Sentinel so [copyWith] can tell "leave it" from "set it to null".
  static const _unset = Object();

  /// What the user asked this location to be called, falling back to the real
  /// name.
  String get displayName {
    final a = alias?.trim() ?? '';
    if (a.isNotEmpty) return a;
    return name.isEmpty ? (tag.isEmpty ? address : tag) : name;
  }

  /// The real name, shown small underneath [displayName] — but only when the
  /// two differ, otherwise it is just noise.
  String? get secondaryName {
    final a = alias?.trim() ?? '';
    if (a.isEmpty) return null;
    final real = name.isEmpty ? address : name;
    return real == a ? null : real;
  }

  /// True when we know where in the world this is, either from the panel or
  /// because the user placed it.
  bool get hasLocation =>
      (lat != null && lon != null) || country.trim().isNotEmpty;

  /// Short geography label for the map, and the second line of a picker row.
  ///
  /// Deliberately *not* the thing a row leads with. [region] is whatever the
  /// panel worked out from GeoIP, which for most inbounds is the country and
  /// nothing else — so leading with it replaced every config's own name with
  /// "Germany". The name is the thing the operator chose and the thing the
  /// customer was told to look for; it leads. See [displayName].
  String get city {
    if (region.isNotEmpty) return region;
    // Panel names are usually "Germany · Frankfurt" or "Germany - Frankfurt".
    for (final sep in [' · ', ' — ', ' - ']) {
      final i = name.indexOf(sep);
      if (i > 0) return name.substring(i + sep.length).trim();
    }
    return name.isEmpty ? address : name;
  }

  /// "VLESS · Reality" style label used on the cards.
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

  /// "Frankfurt · Germany" — where this is, for the line under the name.
  ///
  /// Collapses to one part when the panel's region already *is* the country,
  /// which is the common case: repeating "Germany · Germany" reads as a bug.
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
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        platform: (j['platform'] ?? '') as String,
        ip: (j['ip'] ?? '') as String,
        lastSeen: DateTime.tryParse((j['last_seen'] ?? '') as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'ip': ip,
        'last_seen': lastSeen?.toIso8601String(),
      };
}

/// Where the panel sees this client connecting from.
///
/// Comes from the panel rather than a third-party geolocation service: it
/// already terminates the request, so nothing new learns the user's address.
class ClientOrigin {
  const ClientOrigin({this.ip = '', this.country = ''});

  final String ip;
  final String country;

  factory ClientOrigin.fromJson(Map<String, dynamic> j) => ClientOrigin(
        ip: (j['ip'] ?? '') as String,
        country: ((j['country'] ?? '') as String).toUpperCase(),
      );

  Map<String, dynamic> toJson() => {'ip': ip, 'country': country};

  bool get isEmpty => ip.isEmpty && country.isEmpty;
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

  factory ClientSession.fromJson(Map<String, dynamic> j,
          {String sourceId = ''}) =>
      ClientSession(
        profile: Profile.fromJson(Map<String, dynamic>.from(j['profile'] as Map)),
        servers: ((j['servers'] as List?) ?? [])
            .map((e) => ServerConfig.fromJson(
                  Map<String, dynamic>.from(e as Map),
                  sourceId: sourceId,
                ))
            .toList(),
        brand: (j['brand'] ?? kAppName) as String,
        blockedReason: j['blocked_reason'] as String?,
        origin: j['you'] == null
            ? const ClientOrigin()
            : ClientOrigin.fromJson(Map<String, dynamic>.from(j['you'] as Map)),
      );
}

/// A location the user placed by hand.
///
/// Configs pasted from a clipboard or pulled from someone else's subscription
/// carry no geography at all, so they cannot be drawn on the map or grouped by
/// continent until somebody says where they are.
class GeoOverride {
  const GeoOverride({required this.country, this.lat, this.lon});

  /// ISO-3166 alpha-2. Enough on its own — the country centroid is used when
  /// no exact position is given.
  final String country;
  final double? lat;
  final double? lon;

  factory GeoOverride.fromJson(Map<String, dynamic> j) => GeoOverride(
        country: ((j['country'] ?? '') as String).toUpperCase(),
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'country': country,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
      };
}

/// Minimal ISO-3166 alpha-2 → display name / flag emoji.
String countryName(String cc) => _countries[cc.toUpperCase()] ?? cc.toUpperCase();

String countryFlag(String cc) {
  final c = cc.toUpperCase();
  if (c.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(c)) return '';
  return String.fromCharCodes(
      c.codeUnits.map((u) => 0x1F1E6 + (u - 0x41)).toList());
}

/// The country list the "where is this server?" picker offers.
Map<String, String> get knownCountries => Map.unmodifiable(_countries);

const _countries = <String, String>{
  'AE': 'United Arab Emirates', 'AM': 'Armenia', 'AR': 'Argentina',
  'AT': 'Austria', 'AU': 'Australia', 'AZ': 'Azerbaijan', 'BE': 'Belgium',
  'BG': 'Bulgaria', 'BR': 'Brazil', 'CA': 'Canada', 'CH': 'Switzerland',
  'CL': 'Chile', 'CN': 'China', 'CY': 'Cyprus', 'CZ': 'Czechia',
  'DE': 'Germany', 'DK': 'Denmark', 'EE': 'Estonia', 'ES': 'Spain',
  'FI': 'Finland', 'FR': 'France', 'GB': 'United Kingdom', 'GE': 'Georgia',
  'GR': 'Greece', 'HK': 'Hong Kong', 'HR': 'Croatia', 'HU': 'Hungary',
  'ID': 'Indonesia', 'IE': 'Ireland', 'IL': 'Israel', 'IN': 'India',
  'IR': 'Iran', 'IS': 'Iceland', 'IT': 'Italy', 'JP': 'Japan',
  'KR': 'South Korea', 'KZ': 'Kazakhstan', 'LT': 'Lithuania', 'LU': 'Luxembourg',
  'LV': 'Latvia', 'MD': 'Moldova', 'MX': 'Mexico', 'MY': 'Malaysia',
  'NL': 'Netherlands', 'NO': 'Norway', 'NZ': 'New Zealand', 'PL': 'Poland',
  'PT': 'Portugal', 'QA': 'Qatar', 'RO': 'Romania', 'RS': 'Serbia',
  'RU': 'Russia', 'SA': 'Saudi Arabia', 'SE': 'Sweden', 'SG': 'Singapore',
  'SI': 'Slovenia', 'SK': 'Slovakia', 'TH': 'Thailand', 'TR': 'Türkiye',
  'TW': 'Taiwan', 'UA': 'Ukraine', 'US': 'United States', 'UZ': 'Uzbekistan',
  'VN': 'Vietnam', 'ZA': 'South Africa',
};

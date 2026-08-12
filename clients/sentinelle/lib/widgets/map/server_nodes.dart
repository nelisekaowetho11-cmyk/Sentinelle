import 'dart:math' as math;
import 'dart:ui';

import '../../models/models.dart';
import '../../services/geo/world_atlas.dart';
import 'map_canvas.dart';

/// Country centroids, used when the panel cannot give an exact position.
const Map<String, LonLat> countryCentroid = {
  'AE': Offset(54.0, 24.0), 'AM': Offset(45.0, 40.1), 'AR': Offset(-58.4, -34.6),
  'AT': Offset(14.5, 47.5), 'AU': Offset(133.8, -25.3), 'AZ': Offset(49.9, 40.4),
  'BE': Offset(4.5, 50.5), 'BG': Offset(25.5, 42.7), 'BR': Offset(-51.9, -14.2),
  'CA': Offset(-106.3, 56.1), 'CH': Offset(8.2, 46.8), 'CL': Offset(-71.5, -35.7),
  'CN': Offset(104.2, 35.9), 'CY': Offset(33.4, 35.1), 'CZ': Offset(15.5, 49.8),
  'DE': Offset(10.5, 51.2), 'DK': Offset(9.5, 56.3), 'EE': Offset(25.0, 58.6),
  'ES': Offset(-3.7, 40.5), 'FI': Offset(25.7, 61.9), 'FR': Offset(2.2, 46.6),
  'GB': Offset(-3.4, 55.4), 'GE': Offset(43.4, 42.3), 'GR': Offset(21.8, 39.1),
  'HK': Offset(114.2, 22.3), 'HR': Offset(15.2, 45.1), 'HU': Offset(19.5, 47.2),
  'ID': Offset(113.9, -0.8), 'IE': Offset(-8.2, 53.4), 'IL': Offset(34.9, 31.0),
  'IN': Offset(79.0, 20.6), 'IR': Offset(53.7, 32.4), 'IS': Offset(-19.0, 65.0),
  'IT': Offset(12.6, 41.9), 'JP': Offset(138.3, 36.2), 'KR': Offset(127.8, 35.9),
  'KZ': Offset(66.9, 48.0), 'LT': Offset(23.9, 55.2), 'LU': Offset(6.1, 49.8),
  'LV': Offset(24.6, 56.9), 'MD': Offset(28.4, 47.4), 'MX': Offset(-102.6, 23.6),
  'MY': Offset(101.98, 4.2), 'NL': Offset(5.3, 52.1), 'NO': Offset(8.5, 60.5),
  'NZ': Offset(174.9, -40.9), 'PL': Offset(19.1, 51.9), 'PT': Offset(-8.2, 39.4),
  'QA': Offset(51.2, 25.4), 'RO': Offset(25.0, 45.9), 'RS': Offset(21.0, 44.0),
  'RU': Offset(60.0, 61.5), 'SA': Offset(45.1, 23.9), 'SE': Offset(18.6, 60.1),
  'SG': Offset(103.8, 1.35), 'SI': Offset(15.0, 46.2), 'SK': Offset(19.7, 48.7),
  'TH': Offset(101.0, 15.9), 'TR': Offset(35.2, 39.0), 'TW': Offset(121.0, 23.7),
  'UA': Offset(31.2, 48.4), 'US': Offset(-98.6, 39.8), 'UZ': Offset(64.6, 41.4),
  'VN': Offset(108.3, 14.1), 'ZA': Offset(22.9, -30.6),
};

/// Well-known city coordinates, so a panel that names a region gets a real
/// position instead of the middle of the country.
const Map<String, LonLat> _cities = {
  'amsterdam': Offset(4.90, 52.37), 'ashburn': Offset(-77.49, 39.04),
  'atlanta': Offset(-84.39, 33.75), 'bangalore': Offset(77.59, 12.97),
  'bangkok': Offset(100.50, 13.75), 'berlin': Offset(13.40, 52.52),
  'bucharest': Offset(26.10, 44.43), 'budapest': Offset(19.04, 47.50),
  'chicago': Offset(-87.63, 41.88), 'copenhagen': Offset(12.57, 55.68),
  'dallas': Offset(-96.80, 32.78),
  'dubai': Offset(55.27, 25.20), 'dublin': Offset(-6.26, 53.35),
  'dusseldorf': Offset(6.77, 51.23), 'frankfurt': Offset(8.68, 50.11),
  'helsinki': Offset(24.94, 60.17), 'hong kong': Offset(114.17, 22.32),
  'istanbul': Offset(28.98, 41.01), 'jakarta': Offset(106.85, -6.21),
  'johannesburg': Offset(28.05, -26.20), 'kyiv': Offset(30.52, 50.45),
  'las vegas': Offset(-115.14, 36.17), 'lisbon': Offset(-9.14, 38.72),
  'london': Offset(-0.13, 51.51), 'los angeles': Offset(-118.24, 34.05),
  'luxembourg': Offset(6.13, 49.61), 'madrid': Offset(-3.70, 40.42),
  'manchester': Offset(-2.24, 53.48), 'marseille': Offset(5.37, 43.30),
  'melbourne': Offset(144.96, -37.81), 'miami': Offset(-80.19, 25.76),
  'milan': Offset(9.19, 45.46), 'montreal': Offset(-73.57, 45.50),
  'moscow': Offset(37.62, 55.76), 'mumbai': Offset(72.88, 19.08),
  'munich': Offset(11.58, 48.14), 'new york': Offset(-74.01, 40.71),
  'osaka': Offset(135.50, 34.69), 'oslo': Offset(10.75, 59.91),
  'paris': Offset(2.35, 48.86), 'prague': Offset(14.44, 50.08),
  'riga': Offset(24.11, 56.95), 'rome': Offset(12.50, 41.90),
  'san francisco': Offset(-122.42, 37.77), 'santiago': Offset(-70.67, -33.45),
  'sao paulo': Offset(-46.63, -23.55), 'seattle': Offset(-122.33, 47.61),
  'seoul': Offset(126.98, 37.57), 'singapore': Offset(103.82, 1.35),
  'sofia': Offset(23.32, 42.70), 'stockholm': Offset(18.07, 59.33),
  'sydney': Offset(151.21, -33.87), 'taipei': Offset(121.56, 25.03),
  'tallinn': Offset(24.75, 59.44), 'tel aviv': Offset(34.78, 32.08),
  'tokyo': Offset(139.69, 35.69), 'toronto': Offset(-79.38, 43.65),
  'vancouver': Offset(-123.12, 49.28), 'vienna': Offset(16.37, 48.21),
  'vilnius': Offset(25.28, 54.69), 'warsaw': Offset(21.01, 52.23),
  'zurich': Offset(8.54, 47.37),
};

/// Best position we can work out for a server.
///
/// Panel coordinates win; then a city name we recognise; then the country
/// centroid. Null when we know nothing, so the caller can park it somewhere
/// harmless rather than drop it on Null Island.
LonLat? serverCoords(ServerConfig s) {
  if (s.lat != null && s.lon != null) return Offset(s.lon!, s.lat!);

  final haystack = '${s.region} ${s.name}'.toLowerCase();
  for (final entry in _cities.entries) {
    if (haystack.contains(entry.key)) return entry.value;
  }
  return countryCentroid[s.country.toUpperCase()];
}

/// Turns the account's servers into map nodes, nudging co-located ones apart.
///
/// Servers in the same city land on the same pixel otherwise, and whichever is
/// painted last swallows every tap.
List<MapNode> buildNodes(
  List<ServerConfig> servers, {
  required Map<int, int?> pings,
  Set<int> dimmed = const {},
}) {
  final placed = <int, LonLat>{};
  final unknown = <ServerConfig>[];

  for (final s in servers) {
    final c = serverCoords(s);
    if (c == null) {
      unknown.add(s);
    } else {
      placed[s.id] = c;
    }
  }

  // Unknown locations get parked in the mid-Atlantic rather than dropped, so
  // they stay reachable from the map as well as the list.
  for (var i = 0; i < unknown.length; i++) {
    placed[unknown[i].id] = Offset(-38.0 + (i % 4) * 5, 30.0 - (i ~/ 4) * 5);
  }

  _spread(servers, placed);

  return [
    for (final s in servers)
      MapNode(
        id: s.id,
        coords: placed[s.id]!,
        label: s.city,
        name: s.displayName,
        cc: s.country.toUpperCase(),
        ping: pings[s.id],
        load: s.load ?? 0,
        dimmed: dimmed.contains(s.id),
        subtitle: s.address,
      ),
  ];
}

/// Pushes coincident servers onto a small ring around their shared point.
void _spread(List<ServerConfig> servers, Map<int, LonLat> placed) {
  final groups = <String, List<int>>{};
  for (final s in servers) {
    final p = placed[s.id]!;
    // Quantised so "same place" tolerates a fraction of a degree.
    groups.putIfAbsent('${p.dx.toStringAsFixed(1)},${p.dy.toStringAsFixed(1)}',
        () => []).add(s.id);
  }
  for (final ids in groups.values) {
    if (ids.length < 2) continue;
    final centre = placed[ids.first]!;
    // 2.2° is about a marker's width at the default fit.
    const r = 2.2;
    for (var i = 0; i < ids.length; i++) {
      final a = i / ids.length * 2 * math.pi;
      placed[ids[i]] = Offset(
        centre.dx + math.cos(a) * r / math.cos(centre.dy * math.pi / 180).abs()
            .clamp(0.3, 1.0),
        centre.dy + math.sin(a) * r,
      );
    }
  }
}

/// Continent buckets for the picker's group headings.
String continentOf(String cc) {
  const europe = {
    'AT','BE','BG','CH','CY','CZ','DE','DK','EE','ES','FI','FR','GB','GR','HR',
    'HU','IE','IS','IT','LT','LU','LV','MD','NL','NO','PL','PT','RO','RS','RU',
    'SE','SI','SK','UA',
  };
  const asia = {
    'AE','AM','AZ','CN','GE','HK','ID','IL','IN','IR','JP','KR','KZ','MY','QA',
    'SA','SG','TH','TR','TW','UZ','VN',
  };
  const americas = {'AR','BR','CA','CL','MX','US'};
  const oceania = {'AU','NZ'};
  const africa = {'ZA'};

  final c = cc.toUpperCase();
  if (europe.contains(c)) return 'Europe';
  if (asia.contains(c)) return 'Asia & Middle East';
  if (americas.contains(c)) return 'Americas';
  if (oceania.contains(c)) return 'Oceania';
  if (africa.contains(c)) return 'Africa';
  return 'Other';
}

const continentOrder = [
  'Europe',
  'Asia & Middle East',
  'Americas',
  'Oceania',
  'Africa',
  'Other',
];

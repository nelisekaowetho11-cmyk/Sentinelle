import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/api.dart';

/// Regression test for panels behind a proxy that 301s http -> https.
///
/// dart:io downgrades a redirected POST to a GET, which made every POST
/// endpoint answer 405. PanelApi must follow redirects itself, keeping the
/// method and body intact.
void main() {
  late HttpServer origin; // the "redirector"
  late HttpServer target; // the "real panel"
  final methodsSeenByTarget = <String>[];
  final bodiesSeenByTarget = <String>[];

  setUp(() async {
    target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((req) async {
      methodsSeenByTarget.add('${req.method} ${req.uri.path}');
      bodiesSeenByTarget.add(await utf8.decoder.bind(req).join());

      if (req.uri.path == '/api/client/ping') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true, 'panel': 'Bridge Panel', 'api': 1}));
      } else if (req.uri.path == '/api/client/login' && req.method == 'POST') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'token': 'tok-123',
            'expires_in': 100,
            'brand': 'Bridge Panel',
            'servers': [],
            'profile': {
              'id': 1,
              'name': 'Demo',
              'username': 'pvb10001',
              'status': 'active',
              'can_connect': true,
              'unlimited': false,
              'traffic_limit_gb': 50,
              'traffic_used_gb': 1,
              'traffic_left_gb': 49,
              'traffic_pct': 2,
              'expires': '2027-01-01',
              'days_left': 100,
            },
          }));
      } else {
        // Exactly what the real panel does for a downgraded POST.
        req.response
          ..statusCode = 405
          ..headers.contentType = ContentType.html
          ..write('<html><title>405 Method Not Allowed</title></html>');
      }
      await req.response.close();
    });

    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((req) async {
      req.response
        ..statusCode = 301
        ..headers.set('Location',
            'http://127.0.0.1:${target.port}${req.uri.path}')
        ..headers.contentType = ContentType.html
        ..write('<html><title>301 Moved Permanently</title></html>');
      await req.response.close();
    });
  });

  tearDown(() async {
    await origin.close(force: true);
    await target.close(force: true);
    methodsSeenByTarget.clear();
    bodiesSeenByTarget.clear();
  });

  test('POST survives a 301 with its method and body intact', () async {
    final api = PanelApi(baseUrl: 'http://127.0.0.1:${origin.port}');
    final res = await api.login('pvb10001', 's3cret!!');

    expect(res.token, 'tok-123');
    expect(res.session.profile.username, 'pvb10001');
    expect(methodsSeenByTarget, contains('POST /api/client/login'));
    expect(bodiesSeenByTarget.last, contains('s3cret!!'));
    api.close();
  });

  test('base URL is upgraded to the redirect target for later calls', () async {
    final api = PanelApi(baseUrl: 'http://127.0.0.1:${origin.port}');
    expect(api.baseUrl, 'http://127.0.0.1:${origin.port}');

    await api.ping();
    expect(api.baseUrl, 'http://127.0.0.1:${target.port}');

    // The follow-up call must go straight to the resolved origin.
    methodsSeenByTarget.clear();
    await api.login('pvb10001', 'pw123456');
    expect(methodsSeenByTarget, ['POST /api/client/login']);
    api.close();
  });

  test('a non-JSON error page produces a readable message', () async {
    final api = PanelApi(baseUrl: 'http://127.0.0.1:${target.port}');
    expect(
      () => api.session(),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 405)
          .having((e) => e.message, 'message', contains('405'))),
    );
    api.close();
  });
}

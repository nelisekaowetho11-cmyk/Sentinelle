import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/vpn/local_proxy.dart';

void main() {
  setUp(LocalProxy.clear);
  tearDown(LocalProxy.clear);

  group('with nothing tunnelling', () {
    test('everything goes direct', () {
      expect(LocalProxy.find(Uri.parse('https://example.com')), 'DIRECT');
      expect(LocalProxy.find(Uri.parse('http://1.2.3.4:5000')), 'DIRECT');
    });
  });

  group('with a proxy-mode tunnel up', () {
    setUp(() => LocalProxy.use('127.0.0.1', 10809));

    test('the app\'s own requests go through the tunnel', () {
      // The bug this exists for: dart:io ignores the system proxy, so in proxy
      // mode the panel saw the user's real address and reported it back as
      // their exit IP — "connected, and I can see my own IP".
      expect(LocalProxy.find(Uri.parse('https://panel.example.com/api')),
          'PROXY 127.0.0.1:10809');
      expect(LocalProxy.find(Uri.parse('http://203.0.113.9:8080')),
          'PROXY 127.0.0.1:10809');
    });

    test('a panel on this machine stays direct', () {
      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        expect(LocalProxy.find(Uri.parse('http://$host:5000')), 'DIRECT',
            reason: host);
      }
    });

    test('a panel on the LAN stays direct', () {
      // Reachable without the tunnel, and routing it through one only adds a
      // way to fail — including the way that matters, where the tunnel is down
      // and the app can no longer ask the panel why.
      for (final host in ['192.168.1.10', '10.0.0.5', '172.16.4.2', '172.31.9.9']) {
        expect(LocalProxy.find(Uri.parse('http://$host:5000')), 'DIRECT',
            reason: host);
      }
    });

    test('a public address that merely looks private is not', () {
      for (final host in ['172.15.0.1', '172.32.0.1', '11.0.0.1', '193.176.243.160']) {
        expect(LocalProxy.find(Uri.parse('http://$host')),
            'PROXY 127.0.0.1:10809',
            reason: host);
      }
    });

    test('a bare hostname is treated as local, as Windows does', () {
      expect(LocalProxy.find(Uri.parse('http://panel:5000')), 'DIRECT');
    });
  });
}

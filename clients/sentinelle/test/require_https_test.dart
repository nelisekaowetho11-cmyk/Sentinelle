// The Play build tells Google's Data safety form that everything it collects
// is encrypted in transit. That is only true if there is no plaintext path at
// all — the sign-in carries an account password, and `_guessScheme` prefers
// `http` for exactly the `address:port` panels most resellers run.
//
// These run twice, because the two builds are meant to differ:
//
//   flutter test test/require_https_test.dart
//       → the sideloaded build; the http fallback must still work
//   flutter test test/require_https_test.dart --dart-define=VEIL_REQUIRE_HTTPS=true
//       → the Play build; nothing may reach for http
//
// `tool/build_release.ps1` passes the define for the Play bundle and nothing
// else, so a regression here is a regression in what the store listing claims.

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/branding.dart';
import 'package:veil_client/services/api.dart';

void main() {
  group('sideload build (no define)', () {
    test('keeps the http guess for address:port panels', () {
      if (kRequireHttps) return; // the other configuration covers this
      expect(PanelApi.normalizeBaseUrl('1.2.3.4:5000'), 'http://1.2.3.4:5000');
      expect(PanelApi.normalizeBaseUrl('panel.example.com'),
          'https://panel.example.com');
    });

    test('accepts an http:// address without complaint', () {
      if (kRequireHttps) return;
      expect(PanelApi.plaintextRefusal('http://1.2.3.4:5000'), isNull);
    });
  });

  group('Play build (VEIL_REQUIRE_HTTPS=true)', () {
    test('never guesses http, even for a bare address:port', () {
      if (!kRequireHttps) return;
      expect(PanelApi.normalizeBaseUrl('1.2.3.4:5000'), 'https://1.2.3.4:5000');
      expect(PanelApi.normalizeBaseUrl('localhost:8000'),
          'https://localhost:8000');
      expect(PanelApi.normalizeBaseUrl('panel.example.com'),
          'https://panel.example.com');
    });

    test('refuses an http:// address with something the user can act on', () {
      if (!kRequireHttps) return;
      final why = PanelApi.plaintextRefusal('http://1.2.3.4:5000');
      expect(why, isNotNull);
      expect(why, contains('https://'),
          reason: 'the message has to say what to ask the provider for');
    });

    test('leaves https:// and non-URL input alone', () {
      if (!kRequireHttps) return;
      expect(PanelApi.plaintextRefusal('https://panel.example.com'), isNull);
      expect(PanelApi.plaintextRefusal('panel.example.com'), isNull);
      expect(PanelApi.plaintextRefusal(''), isNull);
    });

    test('is case-insensitive about the scheme', () {
      if (!kRequireHttps) return;
      expect(PanelApi.plaintextRefusal('HTTP://1.2.3.4:5000'), isNotNull);
      expect(PanelApi.plaintextRefusal('  http://1.2.3.4  '), isNotNull);
    });
  });

  test('the flag defaults to off so the sideload build is unaffected', () {
    // Guards against someone flipping the default and silently breaking every
    // reseller on an address:port panel at their next update.
    const declared = bool.fromEnvironment('VEIL_REQUIRE_HTTPS');
    expect(kRequireHttps, declared,
        reason: 'kRequireHttps must come from the define, with false default');
  });
}

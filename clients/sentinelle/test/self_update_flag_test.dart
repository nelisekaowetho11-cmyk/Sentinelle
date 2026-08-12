import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/branding.dart';
import 'package:veil_client/services/api.dart';
import 'package:veil_client/services/update_service.dart';

/// The Play build must never offer to install anything.
///
/// Play's Device and Network Abuse policy treats an app that updates itself
/// outside the store as an account-level problem, so this is worth a test that
/// runs in both configurations rather than a comment:
///
///   flutter test                                          # sideload default
///   flutter test --dart-define=VEIL_SELF_UPDATE=false     # the Play build
void main() {
  UpdateInfo withUrl(String url) => UpdateInfo(
        available: true,
        latest: '9.9.9',
        current: '1.0.0',
        url: url,
        notes: '',
        mandatory: false,
      );

  test('installable follows the build flavour', () {
    final offered = withUrl('https://panel.example.com/dl/app.apk');

    if (kSelfUpdate) {
      // The sideload build is the only distribution channel its users have.
      expect(
        offered.installable,
        Platform.isAndroid || Platform.isWindows,
        reason: 'the self-updating build should offer the install it can do',
      );
    } else {
      expect(offered.installable, isFalse,
          reason: 'the Play build may not install anything itself');
    }
  });

  test('a build that cannot install never offers a URL-less update', () {
    expect(withUrl('').installable, isFalse);
    expect(withUrl('not a url').installable, isFalse);
  });

  test(
    'the Play build reports no update rather than an unreachable one',
    () async {
      // `check` short-circuits before touching the network when self-update
      // is off, so this panel is never actually asked anything — which is the
      // point: an address that does not resolve still yields "no update".
      final api = PanelApi(baseUrl: 'https://panel.invalid');
      addTearDown(api.close);
      final result = await UpdateService.check(api);
      expect(result.available, isFalse);
      expect(result.latest, isEmpty);
    },
    skip: kSelfUpdate ? 'only meaningful in the Play configuration' : false,
  );
}

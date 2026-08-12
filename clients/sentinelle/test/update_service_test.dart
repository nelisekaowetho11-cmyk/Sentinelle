import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/update_service.dart';

void main() {
  group('version comparison', () {
    int cmp(String a, String b) => UpdateService.compareVersions(a, b);

    test('an installed build is not offered its own update', () {
      // The bug this exists for: pubspec `1.2.0+3` reports version "1.2.0", so
      // the panel compared its published "1.2.0.3" against "1.2.0", found it
      // newer, and went on saying so after the user had already updated.
      expect(cmp('1.2.0.3', '1.2.0+3'), 0);
      expect(cmp('1.2.0.3', '1.2.0.3'), 0);
      expect(cmp('1.2.0-3', '1.2.0+3'), 0);
    });

    test('a genuinely newer build still wins', () {
      expect(cmp('1.2.1', '1.2.0+3') > 0, isTrue);
      expect(cmp('1.2.0+4', '1.2.0+3') > 0, isTrue);
      expect(cmp('2.0.0', '1.9.9+99') > 0, isTrue);
    });

    test('an older published build is not an update', () {
      expect(cmp('1.1.9', '1.2.0+3') < 0, isTrue);
      expect(cmp('1.2.0', '1.2.0+3') < 0, isTrue);
    });

    test('missing trailing components count as zero, not as older', () {
      expect(cmp('1.2', '1.2.0'), 0);
      expect(cmp('1.2.0', '1.2.0+0'), 0);
    });

    test('numbers compare numerically, not as text', () {
      expect(cmp('1.10.0', '1.9.0') > 0, isTrue);
      expect(cmp('1.2.0+10', '1.2.0+9') > 0, isTrue);
    });

    test('decoration around the numbers is ignored', () {
      expect(cmp('v1.2.0', '1.2.0'), 0);
      expect(cmp('1.2.0-beta', '1.2.0'), 0);
      expect(cmp('', ''), 0);
    });
  });
}

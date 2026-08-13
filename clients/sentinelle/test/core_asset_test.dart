// The macOS build could never install a core.
//
// sing-box publishes its macOS builds under `darwin`, and as tarballs; the app
// asked for `sing-box-<version>-macos-<arch>.zip`, which is a 404 on GitHub and
// on all three mirrors. The failure arrived as "could not download sing-box"
// with no hint that the name was the problem, so it is pinned here per platform
// rather than left to whichever machine happens to run the tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/vpn/core_manager.dart';

void main() {
  test('sing-box macOS assets are darwin tarballs', () {
    expect(
      CoreManager.assetName(CoreKind.singbox, '1.13.18',
          os: 'macos', arch: 'arm64'),
      'sing-box-1.13.18-darwin-arm64.tar.gz',
    );
    expect(
      CoreManager.assetName(CoreKind.singbox, '1.13.18',
          os: 'macos', arch: 'amd64'),
      'sing-box-1.13.18-darwin-amd64.tar.gz',
    );
  });

  test('sing-box ships a zip for Windows and a tarball everywhere else', () {
    expect(
      CoreManager.assetName(CoreKind.singbox, '1.13.18',
          os: 'windows', arch: 'amd64'),
      'sing-box-1.13.18-windows-amd64.zip',
    );
    expect(
      CoreManager.assetName(CoreKind.singbox, '1.13.18',
          os: 'linux', arch: 'amd64'),
      'sing-box-1.13.18-linux-amd64.tar.gz',
    );
  });

  // Xray disagrees with sing-box about what macOS is called, which is the whole
  // reason the platform token is not shared between them.
  test('Xray macOS assets keep saying macos', () {
    expect(
      CoreManager.assetName(CoreKind.xray, '25.3.6', os: 'macos', arch: 'arm64'),
      'Xray-macos-arm64-v8a.zip',
    );
    expect(
      CoreManager.assetName(CoreKind.xray, '25.3.6', os: 'macos', arch: 'amd64'),
      'Xray-macos-64.zip',
    );
  });
}

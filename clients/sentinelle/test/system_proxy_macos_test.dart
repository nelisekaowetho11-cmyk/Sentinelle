// macOS used to record nothing about the proxy it was replacing, so
// disconnecting turned off whatever the user already had and left it off. The
// restore now replays what was there, which starts with reading it correctly —
// `networksetup` answers in prose, and the parsing is the part worth pinning.

import 'package:flutter_test/flutter_test.dart';
import 'package:veil_client/services/vpn/system_proxy.dart';

void main() {
  test('a configured proxy is read back field by field', () {
    final parsed = SystemProxy.parseProxyOutput('''
Enabled: Yes
Server: proxy.corp.example
Port: 8080
Authenticated Proxy Enabled: 0
''');

    expect(parsed['enabled'], 'Yes');
    expect(parsed['server'], 'proxy.corp.example');
    expect(parsed['port'], '8080');
  });

  // The shape every ordinary Mac answers with, and the one that must end up
  // switched off rather than "restored" to a server that is not there.
  test('an unconfigured service reads as disabled with no server', () {
    final parsed = SystemProxy.parseProxyOutput('''
Enabled: No
Server:
Port: 0
Authenticated Proxy Enabled: 0
''');

    expect(parsed['enabled'], 'No');
    expect(parsed['server'], isEmpty);
    expect(parsed['port'], '0');
  });

  // `networksetup` answers an unknown service with an error line, and that line
  // has a colon in it like every other line does. It does not matter what the
  // junk parses to — only that it can never look like a proxy worth restoring,
  // because the restore reads `enabled` and turns the service off without it.
  test('an error reply cannot be mistaken for a configured proxy', () {
    final parsed =
        SystemProxy.parseProxyOutput('** Error: The parameters were not valid.');

    expect(parsed['enabled'], isNull);
    expect(parsed['server'], isNull);
  });
}

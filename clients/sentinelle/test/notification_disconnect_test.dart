// Two bugs that both presented as "the notification fights the app":
//
//   1. Tapping DISCONNECT stopped the tunnel, and seconds later it came back.
//   2. Tapping the notification *body* opened the app and killed the tunnel.
//
// They had different causes but one shape: something outside Dart stopped or
// started the core, and the app's own recovery machinery reacted to it as if
// the tunnel had failed.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veil_client/services/storage.dart';
import 'package:veil_client/services/vpn/vpn_engine.dart';
import 'package:veil_client/state/app_state.dart';

import 'support/fake_engine.dart';

void main() {
  setUp(() async {
    Storage.resetForTests();
    SharedPreferences.setMockInitialValues({});
    await Storage.init();
  });

  test('a tunnel already up at launch is adopted, not torn down', () async {
    // Tapping the ongoing notification cold-starts the app into a process that
    // is still tunnelling. The startup sweep used to stop the core on sight,
    // so opening the app from the notification disconnected the VPN.
    final engine = FakeVpnEngine();
    final state = AppState(engine: engine, adoptedTunnel: true);

    expect(state.adoptedTunnel, isTrue,
        reason: 'the flag has to reach AppState for bootstrap to act on it');
    expect(engine.disconnectCalls, 0,
        reason: 'adopting must never stop the running core');

    state.dispose();
  });

  test('a launch with no tunnel adopts nothing', () async {
    final engine = FakeVpnEngine();
    final state = AppState(engine: engine);
    expect(state.adoptedTunnel, isFalse);
    expect(state.isConnected, isFalse);
    state.dispose();
  });

  test('an external stop does not trigger a reconnect', () async {
    // The kill switch exists for a tunnel that died. A stop somebody asked for
    // — the notification button, the tile, the widget — is not that, and
    // treating it as one is what made DISCONNECT read as "reconnect".
    await Storage.I.setKillSwitch(true);
    final engine = FakeVpnEngine();
    final state = AppState(engine: engine);

    engine.emitState(VpnState.connecting);
    engine.emitState(VpnState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(state.isConnected, isTrue);

    final connectsBefore = engine.connectCalls;
    engine.emitState(VpnState.disconnected);
    // Well past the recovery loop's first tick had one been started.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(engine.connectCalls, connectsBefore,
        reason: 'nothing may re-dial after a stop the user asked for');
    expect(state.isConnected, isFalse);

    state.dispose();
  });
}

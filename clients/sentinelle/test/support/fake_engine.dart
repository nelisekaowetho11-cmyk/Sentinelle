import 'dart:async';

import 'package:veil_client/models/models.dart';
import 'package:veil_client/services/vpn/vpn_engine.dart';

/// A VpnEngine whose streams the test drives by hand, so UI behaviour can be
/// checked without starting a real core.
class FakeVpnEngine implements VpnEngine {
  final _stateCtrl = StreamController<VpnState>.broadcast();
  final _statsCtrl = StreamController<VpnStats>.broadcast();

  VpnState _state = VpnState.disconnected;
  VpnStats _stats = VpnStats.zero;

  int connectCalls = 0;
  int disconnectCalls = 0;
  ServerConfig? lastServer;
  int delayToReturn = 42;

  @override
  Stream<VpnState> get stateStream => _stateCtrl.stream;
  @override
  Stream<VpnStats> get statsStream => _statsCtrl.stream;
  @override
  VpnState get state => _state;
  @override
  VpnStats get stats => _stats;

  /// Push a state change as the real engine would.
  void emitState(VpnState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  /// Push a stats sample as the real engine would (once a second, live).
  void emitStats(VpnStats s) {
    _stats = s;
    _statsCtrl.add(s);
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<bool> isReady() async => true;
  @override
  Future<bool> requestPermission() async => true;

  /// When set, [connect] hangs until [finishConnect] is called instead of
  /// coming up instantly.
  ///
  /// A real core takes a second or two to start, and the interesting question
  /// is what the UI does during that window — instant success hides it.
  bool stallConnect = false;
  Completer<void>? _stalled;

  void finishConnect({VpnState end = VpnState.connected}) {
    emitState(end);
    _stalled?.complete();
    _stalled = null;
  }

  @override
  Future<void> connect(ServerConfig server, VpnEngineOptions options) async {
    connectCalls++;
    lastServer = server;
    if (stallConnect) {
      _stalled = Completer<void>();
      return _stalled!.future;
    }
    emitState(VpnState.connecting);
    emitState(VpnState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    // Releases a stalled attempt, the way both real engines do: a cancel kills
    // the core, so whatever `connect` was waiting on gives up and returns.
    _stalled?.complete();
    _stalled = null;
    emitState(VpnState.disconnected);
    emitStats(VpnStats.zero);
  }

  @override
  Future<int> measureDelay(ServerConfig server, VpnEngineOptions options) async =>
      delayToReturn;

  @override
  Future<String> coreVersion() async => 'fake-core 1.0';

  @override
  String? lastFailure;

  @override
  void dispose() {
    _stateCtrl.close();
    _statsCtrl.close();
  }
}

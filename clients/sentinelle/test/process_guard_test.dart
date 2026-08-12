import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:veil_client/services/vpn/process_guard.dart';

/// path_provider has no implementation in a plain test VM, so point it at a
/// temp directory.
class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('veil-guard');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A process that just sits there, so we can prove we can kill it.
  ({String exe, List<String> args}) longRunnerCommand() => Platform.isWindows
      ? (exe: 'cmd', args: ['/c', 'ping -t 127.0.0.1 > NUL'])
      : (exe: 'sleep', args: ['600']);

  test('a second run() replaces the first process instead of stacking', () async {
    final guard = ProcessGuard(name: 'veil-test-runner');
    final cmd = longRunnerCommand();

    final first = await guard.run(cmd.exe, cmd.args);
    final firstPid = first.pid;
    expect(guard.isRunning, isTrue);

    final second = await guard.run(cmd.exe, cmd.args);
    expect(second.pid, isNot(firstPid), reason: 'should be a new process');
    expect(guard.isRunning, isTrue);

    // The first one must be gone — this is the bug where switching servers
    // left a core behind.
    await first.exitCode.timeout(const Duration(seconds: 10));

    await guard.stop();
    expect(guard.isRunning, isFalse);
    await second.exitCode.timeout(const Duration(seconds: 10));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('stop() kills the process and clears the pid file', () async {
    final guard = ProcessGuard(name: 'veil-test-stop');
    final cmd = longRunnerCommand();
    final proc = await guard.run(cmd.exe, cmd.args);

    final pidFile = File('${tmp.path}${Platform.pathSeparator}veil-test-stop.pid');
    expect(await pidFile.exists(), isTrue);
    expect((await pidFile.readAsString()).trim(), '${proc.pid}');

    await guard.stop();
    await proc.exitCode.timeout(const Duration(seconds: 10));
    expect(await pidFile.exists(), isFalse);
    expect(guard.isRunning, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('onExit fires for a crash but not for a stop we asked for', () async {
    // The engine treats onExit as "the tunnel died under me": it diagnoses a
    // failure, shows a red panel and, in proxy mode, holds the system proxy
    // shut. Firing it for a deliberate teardown turned pressing Cancel into an
    // error report — and, worse, into a kill switch nobody triggered.
    final guard = ProcessGuard(name: 'veil-test-exit');
    final cmd = longRunnerCommand();

    var exits = 0;
    final proc = await guard.run(cmd.exe, cmd.args, onExit: (_) => exits++);
    await guard.stop();
    await proc.exitCode.timeout(const Duration(seconds: 10));
    // Give any queued callback a chance to be wrong.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(exits, 0, reason: 'a stop we asked for is not an event');

    // A process that ends on its own still has to be reported, or a dead core
    // would leave the app claiming a tunnel it no longer has.
    final quick = Platform.isWindows
        ? (exe: 'cmd', args: ['/c', 'exit 3'])
        : (exe: 'sh', args: ['-c', 'exit 3']);
    var crashCode = -1;
    await guard.run(quick.exe, quick.args, onExit: (c) {
      exits++;
      crashCode = c;
    });
    for (var i = 0; i < 50 && exits == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(exits, 1);
    expect(crashCode, 3);
    expect(guard.isRunning, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('sweepOrphans removes a stale pid file', () async {
    final pidFile = File('${tmp.path}${Platform.pathSeparator}ghost-core.pid');
    // A pid that is almost certainly not alive.
    await pidFile.writeAsString('999999');
    await ProcessGuard.sweepOrphans(['ghost-core']);
    expect(await pidFile.exists(), isFalse);
  });

  test('stop() on a guard that never ran is harmless', () async {
    final guard = ProcessGuard(name: 'veil-test-idle');
    await guard.stop();
    expect(guard.isRunning, isFalse);
  });

  group('Mutex', () {
    test('serialises overlapping work', () async {
      final mutex = Mutex();
      final order = <String>[];

      Future<void> job(String tag, int ms) => mutex.run(() async {
            order.add('$tag-start');
            await Future<void>.delayed(Duration(milliseconds: ms));
            order.add('$tag-end');
          });

      await Future.wait([job('a', 60), job('b', 10), job('c', 5)]);

      // No interleaving: each job finishes before the next starts.
      expect(order, [
        'a-start', 'a-end',
        'b-start', 'b-end',
        'c-start', 'c-end',
      ]);
    });

    test('a failure does not wedge the queue', () async {
      final mutex = Mutex();
      await expectLater(
        mutex.run(() async => throw StateError('boom')),
        throwsStateError,
      );
      expect(await mutex.run(() async => 42), 42);
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Owns the lifetime of the core process so it can never outlive the app.
///
/// Three things went wrong before and are all handled here:
///  * a second `connect()` could start a core while the first was still up —
///    every start now goes through [run], which stops the previous one first;
///  * `kill()` only signals the direct child, so a core that spawned helpers
///    (or ignored the signal) survived — Windows now gets `taskkill /T /F`;
///  * killing the app window left the core running forever — the pid is
///    written to disk and swept on the next launch.
class ProcessGuard {
  ProcessGuard({required this.name});

  /// Used for the pid file name and for the orphan sweep.
  final String name;

  Process? _proc;
  int? _pid;

  Process? get process => _proc;
  int? get pid => _pid;
  bool get isRunning => _proc != null;

  static Future<File> _pidFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name.pid');
  }

  // ── Crash marker ───────────────────────────────────────────────────────────
  //
  // The pid files alone cannot answer "did the last session end cleanly?" —
  // they are deleted when a core stops, which is also what happens on a normal
  // exit. This marker exists for exactly as long as a tunnel is meant to be
  // up, so finding one at startup means the app went down without tidying up.

  static const _markerName = 'tunnel.session';

  static Future<File> _marker() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_markerName');
  }

  /// Records that tunnels are running, so a crash is detectable next launch.
  static Future<void> markSessionOpen() async {
    try {
      await (await _marker())
          .writeAsString(DateTime.now().toIso8601String(), flush: true);
    } catch (_) {
      // A missing marker only costs us the crash *report*, not the sweep.
    }
  }

  static Future<void> markSessionClosed() async {
    try {
      final f = await _marker();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// True when the previous run left a tunnel open — i.e. it crashed or was
  /// killed. Consumes the marker, so it only reports once.
  static Future<bool> consumeCrashMarker() async {
    try {
      final f = await _marker();
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Kills anything left over from a previous run. Safe to call at startup.
  static Future<void> sweepOrphans(Iterable<String> names) async {
    for (final name in names) {
      try {
        final f = await _pidFile(name);
        if (!await f.exists()) continue;
        final pid = int.tryParse((await f.readAsString()).trim());
        if (pid != null && pid > 0) {
          await _killTree(pid, expectedName: name);
        }
        await f.delete();
      } catch (_) {
        // A failed sweep must never stop the app from starting.
      }
    }
  }

  /// Starts [executable]; any process this guard previously started is stopped
  /// first, so there is never more than one core alive per guard.
  Future<Process> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    void Function(String line)? onOutput,
    void Function(int exitCode)? onExit,
  }) async {
    await stop();

    final proc = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    _proc = proc;
    _pid = proc.pid;

    try {
      final f = await _pidFile(name);
      await f.writeAsString('${proc.pid}', flush: true);
    } catch (_) {
      // Not fatal — we still hold the handle for this session.
    }

    if (onOutput != null) {
      void pipe(Stream<List<int>> s) => s
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onOutput, onError: (Object _) {});
      pipe(proc.stdout);
      pipe(proc.stderr);
    }

    unawaited(proc.exitCode.then((code) async {
      // [stop] detaches the process from the guard *before* killing it, so a
      // field that still points at this one means nobody asked for the exit.
      // That is the only case worth reporting: [onExit] is how the engine
      // learns the tunnel died under it, and a core we shot ourselves is not
      // news. Calling it unconditionally meant a deliberate teardown that
      // happened to reach the process before the state was updated arrived at
      // the user as "the tunnel stopped unexpectedly".
      final unexpected = identical(_proc, proc);
      if (unexpected) {
        _proc = null;
        _pid = null;
        await _clearPidFile();
        onExit?.call(code);
      }
    }));

    return proc;
  }

  /// Stops the running core and waits for the OS to reap it.
  Future<void> stop() async {
    final proc = _proc;
    final pid = _pid;
    _proc = null;
    _pid = null;

    if (proc == null) {
      await _clearPidFile();
      return;
    }

    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {}

    // Give it a moment to exit cleanly, then take the whole tree down.
    var exited = false;
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
      exited = true;
    } on TimeoutException {
      exited = false;
    } catch (_) {
      exited = true;
    }

    if (!exited && pid != null) {
      await _killTree(pid, expectedName: name);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    await _clearPidFile();
  }

  Future<void> _clearPidFile() async {
    try {
      final f = await _pidFile(name);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Terminates a pid and all of its children.
  ///
  /// [expectedName] guards against pid reuse: we only kill the process if its
  /// image name still looks like our core.
  static Future<void> _killTree(int pid, {String? expectedName}) async {
    if (Platform.isWindows) {
      if (expectedName != null && !await _windowsPidMatches(pid, expectedName)) {
        return;
      }
      try {
        await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
      } catch (_) {}
      return;
    }
    // POSIX: kill the process group if we can, otherwise just the pid.
    try {
      await Process.run('kill', ['-TERM', '$pid']);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await Process.run('kill', ['-KILL', '$pid']);
    } catch (_) {}
  }

  static Future<bool> _windowsPidMatches(int pid, String expectedName) async {
    try {
      final r = await Process.run(
        'tasklist',
        ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
      );
      final out = (r.stdout as String).toLowerCase();
      return out.contains(expectedName.toLowerCase());
    } catch (_) {
      // If we cannot tell, do not kill an unknown pid.
      return false;
    }
  }
}

/// Minimal async mutex — keeps overlapping connect/disconnect calls from
/// interleaving and starting two cores.
class Mutex {
  Future<void> _last = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _last;
    _last = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

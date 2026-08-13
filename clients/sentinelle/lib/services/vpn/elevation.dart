import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Administrator/root detection and self-relaunch.
///
/// VPN (TUN) mode creates a network device, which needs elevation on every
/// desktop platform. Rather than failing at connect time, the app can restart
/// itself elevated.
class Elevation {
  /// True when the current process can create a TUN device.
  static bool get isElevated {
    if (Platform.isWindows) return _windowsIsElevated();
    if (Platform.isLinux || Platform.isMacOS) {
      // Cheap and reliable: only root can read this.
      try {
        final r = Process.runSync('id', ['-u']);
        return (r.stdout as String).trim() == '0';
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  static bool _windowsIsElevated() {
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final isUserAnAdmin = shell32
          .lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      return isUserAnAdmin() != 0;
    } catch (_) {
      return false;
    }
  }

  /// True when [relaunchElevated] can actually do something. Elsewhere the UI
  /// shows [manualInstruction] instead of a button that would do nothing.
  ///
  /// macOS is deliberately not on this list even though `osascript` could raise
  /// the authentication sheet. Elevating the *app* there moves its home
  /// directory to root's, so the relaunched copy would come up with no account
  /// signed in and none of the settings — a worse surprise than being told to
  /// use `sudo`. Doing it properly needs a privileged helper installed with
  /// `SMAppService`, and that needs a Developer ID-signed build.
  static bool get canRelaunch => Platform.isWindows;

  /// Relaunches this executable with elevation. Returns true when the new
  /// process was started, in which case the caller should quit.
  ///
  /// On Windows this is the UAC prompt; the user can decline, and then nothing
  /// happens and we carry on unelevated.
  static Future<bool> relaunchElevated() async {
    if (!Platform.isWindows) {
      // No good cross-desktop equivalent — pkexec/sudo need a terminal or a
      // policy file, so the UI asks the user to relaunch instead.
      return false;
    }
    final arena = Arena();
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final shellExecute = shell32.lookupFunction<
          IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, Pointer<Utf16>, Int32),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, int)>('ShellExecuteW');

      const swShowNormal = 1;
      final result = shellExecute(
        0,
        'runas'.toNativeUtf16(allocator: arena),
        Platform.resolvedExecutable.toNativeUtf16(allocator: arena),
        nullptr,
        File(Platform.resolvedExecutable).parent.path.toNativeUtf16(allocator: arena),
        swShowNormal,
      );
      // ShellExecute returns >32 on success; 5 is ERROR_ACCESS_DENIED, which is
      // what a declined UAC prompt gives.
      return result > 32;
    } catch (_) {
      return false;
    } finally {
      arena.releaseAll();
    }
  }

  /// Human-readable instruction for when we cannot elevate ourselves.
  static String get manualInstruction {
    if (Platform.isWindows) {
      return 'Right-click Sentinelle and choose "Run as administrator".';
    }
    if (Platform.isMacOS) {
      // The full path, because the binary inside the bundle is what has to be
      // run — `sudo open -a Sentinelle` launches it as the ordinary user and
      // looks like the instruction simply did not work.
      return 'VPN mode needs root on macOS. Quit Sentinelle, then run: '
          'sudo "${Platform.resolvedExecutable}"';
    }
    return 'Start Sentinelle with sudo, or grant it CAP_NET_ADMIN.';
  }
}

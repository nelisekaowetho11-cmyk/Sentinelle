import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows proxy configuration through the documented WinINet API.
///
/// Writing `ProxyEnable`/`ProxyServer` under `Internet Settings` is only half
/// the story: WinINet's real state lives in the `DefaultConnectionSettings`
/// blob, and code that reads the proxy (including Python's `urllib`) can keep
/// seeing a dead 127.0.0.1 proxy long after the registry DWORD says 0. Setting
/// `INTERNET_OPTION_PER_CONNECTION_OPTION` updates both, which is what makes
/// "disconnect" actually restore the machine.
final class _PerConnOption extends Struct {
  @Uint32()
  external int dwOption;

  // The union is a pointer or a FILETIME; 8 bytes either way on x64. A 4-byte
  // hole sits between dwOption and the union for alignment.
  @Uint32()
  // ignore: unused_field
  external int _alignmentHole;

  external Pointer<Void> value;
}

final class _PerConnOptionList extends Struct {
  @Uint32()
  external int dwSize;
  @Uint32()
  // ignore: unused_field
  external int _alignmentHole;
  external Pointer<Utf16> pszConnection;
  @Uint32()
  external int dwOptionCount;
  @Uint32()
  external int dwOptionError;
  external Pointer<_PerConnOption> pOptions;
}

typedef _InternetSetOptionNative = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Void>, Uint32);
typedef _InternetSetOptionDart = int Function(
    Pointer<Void>, int, Pointer<Void>, int);

class WinInetProxy {
  static const _optionPerConnection = 75;
  static const _optionSettingsChanged = 39;
  static const _optionRefresh = 37;

  static const _perConnFlags = 1;
  static const _perConnProxyServer = 2;
  static const _perConnProxyBypass = 3;

  static const _proxyTypeDirect = 0x00000001;
  static const _proxyTypeProxy = 0x00000002;

  /// Turns the system proxy on. Returns false if the API could not be used, so
  /// the caller can fall back to the registry.
  static bool enable(String server, String bypass) =>
      _apply(useProxy: true, server: server, bypass: bypass);

  /// Turns the system proxy off and clears the stale server/bypass strings.
  static bool disable() => _apply(useProxy: false, server: '', bypass: '');

  static bool _apply({
    required bool useProxy,
    required String server,
    required String bypass,
  }) {
    if (!Platform.isWindows) return false;

    final arena = Arena();
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<_InternetSetOptionNative,
          _InternetSetOptionDart>('InternetSetOptionW');

      final options = arena<_PerConnOption>(3);

      options[0].dwOption = _perConnFlags;
      options[0].value = Pointer<Void>.fromAddress(
          useProxy ? (_proxyTypeProxy | _proxyTypeDirect) : _proxyTypeDirect);

      final serverPtr = server.toNativeUtf16(allocator: arena);
      options[1].dwOption = _perConnProxyServer;
      options[1].value = serverPtr.cast<Void>();

      final bypassPtr = bypass.toNativeUtf16(allocator: arena);
      options[2].dwOption = _perConnProxyBypass;
      options[2].value = bypassPtr.cast<Void>();

      final list = arena<_PerConnOptionList>();
      list.ref.dwSize = sizeOf<_PerConnOptionList>();
      list.ref.pszConnection = nullptr; // null = the LAN connection
      list.ref.dwOptionCount = 3;
      list.ref.dwOptionError = 0;
      list.ref.pOptions = options;

      final ok = setOption(
        nullptr,
        _optionPerConnection,
        list.cast<Void>(),
        sizeOf<_PerConnOptionList>(),
      );
      if (ok == 0) return false;

      // Make already-running apps pick the change up.
      setOption(nullptr, _optionSettingsChanged, nullptr, 0);
      setOption(nullptr, _optionRefresh, nullptr, 0);
      return true;
    } catch (_) {
      return false;
    } finally {
      arena.releaseAll();
    }
  }
}

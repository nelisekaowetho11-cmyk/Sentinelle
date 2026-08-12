import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Makes Windows draw its own menus — the tray's right-click menu above all —
/// in the same light or dark as the app.
///
/// Those menus are painted by the system, not by us, so they came up in the
/// default light grey no matter what the window looked like. There is no public
/// API for this: the menu theme is switched through two unnamed `uxtheme.dll`
/// exports that File Explorer itself uses, reachable only by ordinal.
///
/// `DynamicLibrary.lookup` needs a name, so this goes through `GetProcAddress`
/// directly — an ordinal is passed to it as a pointer whose *address* is the
/// ordinal number, which is what `MAKEINTRESOURCE` does in C.
///
/// Everything degrades to "leave the menus alone" when the exports are missing:
/// they arrived in Windows 10 1809 and are undocumented, so they may move.
class WinDarkMenu {
  WinDarkMenu._();

  // SetPreferredAppMode's argument.
  static const _appModeDefault = 0;
  static const _appModeForceDark = 2;
  static const _appModeForceLight = 3;

  static const _ordSetPreferredAppMode = 135;
  static const _ordFlushMenuThemes = 136;

  static bool? _lastDark;

  /// Repaints the system menu theme. Cheap to call repeatedly — it no-ops
  /// unless the mode actually changed.
  static void apply({required bool dark}) {
    if (!Platform.isWindows) return;
    if (_lastDark == dark) return;
    _lastDark = dark;

    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getModuleHandle = kernel32.lookupFunction<
          Pointer<Void> Function(Pointer<Utf16>),
          Pointer<Void> Function(Pointer<Utf16>)>('GetModuleHandleW');
      final getProcAddress = kernel32.lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>)>(
        'GetProcAddress',
      );

      // Already loaded: the Flutter runner links against it, and every themed
      // window in the process has pulled it in.
      final uxtheme = _uxthemeHandle(getModuleHandle);
      if (uxtheme == nullptr) return;

      final setMode = getProcAddress(
          uxtheme, Pointer<Uint8>.fromAddress(_ordSetPreferredAppMode));
      if (setMode != nullptr) {
        setMode
            .cast<NativeFunction<Int32 Function(Int32)>>()
            .asFunction<int Function(int)>()(
          dark ? _appModeForceDark : _appModeForceLight,
        );
      }

      // Drops the cached menu theme; without it the change only lands on menus
      // created after the next system theme change.
      final flush = getProcAddress(
          uxtheme, Pointer<Uint8>.fromAddress(_ordFlushMenuThemes));
      if (flush != nullptr) {
        flush
            .cast<NativeFunction<Void Function()>>()
            .asFunction<void Function()>()();
      }
    } catch (_) {
      // A menu that stays grey is not worth an exception.
    }
  }

  /// Puts the system back to deciding for itself. Called on the way out so a
  /// forced mode does not outlive the process in any shared state.
  static void reset() {
    if (!Platform.isWindows || _lastDark == null) return;
    _lastDark = null;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final getModuleHandle = kernel32.lookupFunction<
          Pointer<Void> Function(Pointer<Utf16>),
          Pointer<Void> Function(Pointer<Utf16>)>('GetModuleHandleW');
      final getProcAddress = kernel32.lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>)>(
        'GetProcAddress',
      );
      final uxtheme = _uxthemeHandle(getModuleHandle);
      if (uxtheme == nullptr) return;
      final setMode = getProcAddress(
          uxtheme, Pointer<Uint8>.fromAddress(_ordSetPreferredAppMode));
      if (setMode != nullptr) {
        setMode
            .cast<NativeFunction<Int32 Function(Int32)>>()
            .asFunction<int Function(int)>()(_appModeDefault);
      }
    } catch (_) {}
  }

  static Pointer<Void> _uxthemeHandle(
    Pointer<Void> Function(Pointer<Utf16>) getModuleHandle,
  ) {
    final arena = Arena();
    try {
      // Already loaded: every themed window in the process has pulled it in.
      return getModuleHandle('uxtheme.dll'.toNativeUtf16(allocator: arena));
    } finally {
      arena.releaseAll();
    }
  }
}

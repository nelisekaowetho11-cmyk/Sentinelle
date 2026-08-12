import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'branding.dart';
import 'screens/login_screen.dart';
import 'screens/shell.dart';
import 'services/desktop_notifier.dart';
import 'services/single_instance.dart';
import 'services/storage.dart';
import 'services/tray_service.dart';
import 'services/win_dark_menu.dart';
import 'services/vpn/android_engine.dart';
import 'services/vpn/desktop_engine.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/common.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Storage.init();

  if (_isDesktop) {
    // Before anything else: a second copy would start its own core, fight for
    // the same local ports and undo the first one's system-proxy changes.
    // Opening the app again is a request to *see* it, so raise the window that
    // is already running and stand down.
    final only = await SingleInstance.claim(onSecondLaunch: () async {
      await windowManager.show();
      await windowManager.focus();
    });
    if (!only) {
      exit(0);
    }

    await DesktopNotifier.initialize();

    // Anything a previous run left behind dies before we start a new core.
    await DesktopVpnEngine.sweepOrphans();

    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(1020, 700),
        center: true,
        backgroundColor: VeilColors.bg,
        // We draw our own title bar and buttons.
        titleBarStyle: TitleBarStyle.hidden,
        title: kAppWindowTitle,
      ),
      () async {
        // Fixed size: only our own maximise button changes it.
        await windowManager.setResizable(false);
        await windowManager.setPreventClose(true);
      },
    );
    // Showing the window is deliberately left to the first frame — see
    // _VeilAppState.initState and windows/runner/flutter_window.cpp.
  } else {
    if (Platform.isAndroid) {
      // Same guard as the desktop sweep above: a crash leaves the VpnService
      // running, and Android will happily keep tunnelling without us.
      await AndroidVpnEngine.sweepOrphans();
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ));
  }

  runApp(const VeilApp());
}

class VeilApp extends StatefulWidget {
  const VeilApp({super.key});

  @override
  State<VeilApp> createState() => _VeilAppState();
}

class _VeilAppState extends State<VeilApp>
    with WindowListener, WidgetsBindingObserver {
  final AppState _state = AppState();
  TrayService? _tray;

  bool _quitting = false;

  @override
  void initState() {
    super.initState();
    // The tokens in VeilColors are read from a global palette rather than from
    // an InheritedWidget, so the brightness has to be settled before the first
    // build — and re-settled whenever either input changes.
    WidgetsBinding.instance.addObserver(this);
    _state.addListener(_onStateChanged);
    _state.bootstrap();
    if (_isDesktop) {
      windowManager.addListener(this);
      _tray = TrayService(_state, onQuit: quit);
      _trayReady = _tray!.install();
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealWindow());
    }
  }

  /// Puts the window on screen once there is something to show — unless the
  /// user asked to start in the tray.
  ///
  /// The runner used to do this from the engine's own first-frame callback,
  /// which ran regardless of any preference and is why "start minimised" did
  /// nothing. Waiting for the first frame here keeps what that bought us (no
  /// flash of an empty window) while leaving the decision in Dart, where the
  /// setting actually lives.
  Future<void> _revealWindow() async {
    if (_shown) return;
    _shown = true;
    if (Storage.I.startMinimised) {
      // Nothing to do: the window was created hidden. Only the tray icon is
      // left, which is what the setting promises — and if the tray failed to
      // install there would be no way back, so show it anyway. Waiting on the
      // install first, because it is still in flight on the first frame.
      await _trayReady;
      if (_tray?.supportedAndInstalled ?? false) return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  bool _shown = false;
  Future<void>? _trayReady;

  /// The OS switched between light and dark while we were running.
  @override
  void didChangePlatformBrightness() {
    if (_state.themeMode == AppThemeMode.system) setState(() {});
  }

  /// The app came back to the foreground.
  ///
  /// Everything on screen — the quota, the location list, whether the account
  /// is still allowed to connect — was fetched when the app was last open, and
  /// on a phone that can be days ago: Android suspends our timers along with
  /// the process, so the five-minute refresh does not tick in the background.
  /// Reopening the app is exactly when someone looks at those numbers, so it
  /// is the right moment to go and get them.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_state.refreshOnOpen());
    }
  }

  /// Repaints the whole app when the theme setting changes; every other state
  /// change is already handled by the AnimatedBuilder below.
  AppThemeMode _lastMode = AppThemeMode.system;
  void _onStateChanged() {
    if (_state.themeMode == _lastMode) return;
    _lastMode = _state.themeMode;
    setState(() {});
  }

  /// Android draws the status and navigation bars itself, and it needs telling
  /// which way round to draw their icons — light-on-dark was baked in at
  /// startup, which left them invisible against a light page.
  Brightness? _chromeFor;
  void _syncSystemChrome(Brightness brightness) {
    if (_isDesktop || _chromeFor == brightness) return;
    _chromeFor = brightness;
    final icons =
        brightness == Brightness.dark ? Brightness.light : Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    ));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.removeListener(_onStateChanged);
    if (_isDesktop) windowManager.removeListener(this);
    _tray?.dispose();
    _state.dispose();
    super.dispose();
  }

  /// Desktop's version of "the app was opened".
  ///
  /// A window that spends its life hidden in the tray never reports a
  /// lifecycle resume, so the callback above would not fire for the one case
  /// this feature exists for: clicking the tray icon after leaving the machine
  /// overnight. `refreshOnOpen` rate-limits itself, so wiring this to plain
  /// focus — which also catches alt-tabbing back — costs nothing.
  @override
  void onWindowFocus() => unawaited(_state.refreshOnOpen());

  @override
  void onWindowRestore() => unawaited(_state.refreshOnOpen());

  /// Close either hides to the tray or quits — but never leaves a core behind.
  @override
  void onWindowClose() async {
    if (Storage.I.closeToTray && (_tray?.supportedAndInstalled ?? false)) {
      await windowManager.hide();
      return;
    }
    await quit();
  }

  /// The single exit path, shared by the close button and the tray menu.
  ///
  /// Everything that must survive the app (core stopped, system proxy put back,
  /// pid file removed) is awaited *first*, then the process ends immediately.
  /// Letting Flutter tear itself down instead raced our in-flight async work
  /// against a dead engine and crashed with a fatal callback exception.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await _state.shutdown();
    } catch (e) {
      debugPrint('quit: shutdown failed: $e');
    }
    try {
      await _tray?.dispose();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.hide();
    } catch (_) {}
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final mode = _state.themeMode;
    final brightness = VeilTheme.resolve(
      mode,
      MediaQuery.maybePlatformBrightnessOf(context) ??
          View.of(context).platformDispatcher.platformBrightness,
    );
    // Settled before the tree below is built, because everything in it reads
    // the palette straight off VeilColors rather than out of a Theme.
    VeilTheme.apply(brightness);
    _syncSystemChrome(brightness);
    // The tray's right-click menu is drawn by Windows, not by us, so it has to
    // be told separately which way the app has gone.
    if (_isDesktop) {
      WinDarkMenu.apply(dark: brightness == Brightness.dark);
    }

    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      // Both are built from the same palette, so whichever themeMode picks
      // matches what VeilColors is handing out.
      theme: buildVeilTheme(brightness),
      darkTheme: buildVeilTheme(brightness),
      themeMode: mode.material,
      home: AnimatedBuilder(
        animation: _state,
        builder: (context, _) {
          final Widget page = switch (_state.authStage) {
            AuthStage.checking => const _SplashScreen(),
            AuthStage.loggedOut => LoginScreen(state: _state),
            AuthStage.loggedIn => VeilShell(state: _state),
          };
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: child,
            ),
            child: KeyedSubtree(
              key: ValueKey(_state.authStage),
              child: page,
            ),
          );
        },
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Container(
          decoration: veilPageGlow(opacity: 0.12),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const VeilMark(size: 52),
                const SizedBox(height: 18),
                Text(kAppName, style: VeilText.display(size: 24, weight: 700)),
                const SizedBox(height: 22),
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: VeilColors.accent),
                ),
              ],
            ),
          ),
        ),
      );
}

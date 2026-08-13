import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../branding.dart';
import '../models/models.dart';
import '../services/storage.dart';
import '../services/vpn/vpn_engine.dart';
import '../state/app_state.dart';

/// System-tray icon, menu and state text. Desktop only.
class TrayService with TrayListener {
  TrayService(this.state, {required this.onQuit});

  final AppState state;

  /// Routed back to the app so quitting from the tray takes exactly the same
  /// path as the close button.
  final Future<void> Function() onQuit;
  bool _installed = false;

  /// Everything the menu is drawn from, flattened. The tray menu is rebuilt
  /// through a platform channel, so it is only worth doing when something it
  /// actually shows has changed — and that is far more than the tunnel state:
  /// latency readings, favourites and the location list all move.
  String? _lastSignature;

  /// Locations offered for one-click connection, in the order the menu lists
  /// them.
  static const _sectionLimit = 5;

  static bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Only true once an icon is actually sitting in the tray — closing to a
  /// tray that failed to install would make the app impossible to get back.
  bool get supportedAndInstalled => supported && _installed;

  String get _iconPath =>
      Platform.isWindows ? 'assets/icons/tray.ico' : 'assets/icons/tray.png';

  Future<void> install() async {
    if (!supported || _installed) return;
    try {
      trayManager.addListener(this);
      // A template image is drawn as a silhouette that follows the menu bar,
      // which is the only way an icon stays visible on macOS across light,
      // dark and a tinted desktop behind a translucent bar. Ignored elsewhere.
      await trayManager.setIcon(_iconPath, isTemplate: Platform.isMacOS);
      await _rebuildMenu();
      _installed = true;
      state.addListener(_onStateChanged);
      _onStateChanged();
    } catch (_) {
      // A missing tray (bare WM on Linux, for instance) must not break the app.
      _installed = false;
    }
  }

  Future<void> dispose() async {
    if (!_installed) return;
    state.removeListener(_onStateChanged);
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {}
    _installed = false;
  }

  void _onStateChanged() {
    if (!_installed) return;
    final signature = _signature();
    if (_lastSignature == signature) return;
    _lastSignature = signature;
    _rebuildMenu();
    final label = switch (state.vpnState) {
      VpnState.connected => '$kAppName — connected'
          '${state.activeServer == null ? '' : ' · ${state.activeServer!.displayName}'}',
      VpnState.connecting => '$kAppName — connecting…',
      VpnState.disconnecting => '$kAppName — disconnecting…',
      VpnState.error => '$kAppName — error',
      VpnState.disconnected => '$kAppName — not connected',
    };
    trayManager.setToolTip(label).catchError((_) {});
  }

  String _signature() => [
        state.vpnState.name,
        state.isBusyConnecting,
        state.activeServer?.uid ?? '',
        Storage.I.lastServerId ?? '',
        for (final s in _menuServers()) '${s.uid}:${state.pings[s.id] ?? ''}',
      ].join('|');

  // ── Menu contents ──────────────────────────────────────────────────────────

  /// The last location used, whether or not a tunnel is up.
  ServerConfig? get _recent => state.activeServer ?? state.selectedServer;

  List<ServerConfig> get _favourites {
    final starred = Storage.I.favourites.toSet();
    return state.servers
        .where((s) => starred.contains(s.id))
        .take(_sectionLimit)
        .toList();
  }

  /// The five quickest locations we have a reading for.
  ///
  /// Only measured ones: guessing an order from nothing would put whatever
  /// happens to be first in the list under a heading that claims it is fast.
  List<ServerConfig> get _fastest {
    final measured = [
      for (final s in state.servers)
        if ((state.pings[s.id] ?? -1) >= 0) s,
    ]..sort((a, b) => state.pings[a.id]!.compareTo(state.pings[b.id]!));
    return measured.take(_sectionLimit).toList();
  }

  /// Every location the menu mentions, deduplicated — used for the signature
  /// and for resolving a click back to a server.
  List<ServerConfig> _menuServers() {
    final seen = <String>{};
    return [
      for (final s in [
        ?_recent,
        ..._favourites,
        ..._fastest,
      ])
        if (seen.add(s.uid)) s,
    ];
  }

  /// "🇩🇪 Frankfurt · 42 ms".
  ///
  /// The flag is an emoji rather than an icon file: the alternative is
  /// shipping and unpacking 200 bitmaps to draw a picture the menu shows at
  /// 16 px. Windows renders regional-indicator pairs as a lettered badge
  /// rather than a flag, which still names the country.
  String _label(ServerConfig s) {
    final flag = countryFlag(s.country);
    final ping = state.pings[s.id];
    final name = s.displayName;
    return [
      if (flag.isNotEmpty) flag else if (s.country.isNotEmpty) s.country.toUpperCase(),
      name,
      if (ping != null && ping >= 0) '· $ping ms',
    ].join(' ');
  }

  MenuItem _serverItem(ServerConfig s) => MenuItem(
        key: '$_connectPrefix${s.uid}',
        label: _label(s),
        toolTip: '${s.address}:${s.port}',
        checked: state.isConnected && state.activeServer?.uid == s.uid,
      );

  static const _connectPrefix = 'connect:';

  MenuItem _heading(String text) =>
      MenuItem(key: 'heading', label: text, disabled: true);

  Future<void> _rebuildMenu() async {
    final connected = state.isConnected;
    final busy = state.isBusyConnecting;
    final server = _recent;
    final favourites = _favourites;
    final fastest = _fastest;

    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(
          key: 'status',
          label: connected
              ? 'Connected · ${server?.displayName ?? ''}'
              : busy
                  ? 'Working…'
                  : 'Not connected',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(
          key: connected ? 'disconnect' : 'connect',
          label: connected ? 'Disconnect' : 'Connect',
          disabled: busy || (!connected && server == null),
        ),

        // Everything below is "connect to this one" — the whole point of the
        // tray icon for anyone who keeps the window closed.
        if (server != null) ...[
          MenuItem.separator(),
          _heading('Recent'),
          _serverItem(server),
        ],
        if (favourites.isNotEmpty) ...[
          MenuItem.separator(),
          _heading('Favourites'),
          for (final s in favourites) _serverItem(s),
        ],
        if (fastest.isNotEmpty) ...[
          MenuItem.separator(),
          _heading('Fastest'),
          for (final s in fastest) _serverItem(s),
        ],

        MenuItem.separator(),
        MenuItem(key: 'show', label: 'Open $kAppName'),
        MenuItem(key: 'quit', label: 'Quit'),
      ]));
    } catch (_) {}
  }

  Future<void> showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    if (key.startsWith(_connectPrefix)) {
      final uid = key.substring(_connectPrefix.length);
      final target = state.servers.where((s) => s.uid == uid).firstOrNull;
      if (target == null) return;
      // Clicking the location that is already carrying the tunnel means "stop
      // it" — the same thing the checkmark beside it is saying.
      if (state.isConnected && state.activeServer?.uid == uid) {
        state.disconnect();
      } else {
        state.connect(server: target);
      }
      return;
    }
    switch (key) {
      case 'connect':
        state.connect();
        break;
      case 'disconnect':
        state.disconnect();
        break;
      case 'show':
        showWindow();
        break;
      case 'quit':
        onQuit();
        break;
    }
  }
}

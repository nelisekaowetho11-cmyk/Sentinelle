import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/sources.dart';
import '../services/geo/projection.dart';
import '../services/geo/world_atlas.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/map/map_canvas.dart';
import '../widgets/map/server_nodes.dart';
import 'shell.dart' show mobileTabBarClearance;

/// Which subset of the account's servers the picker is showing.
enum LocationFilter { all, fastest, favourites }

extension on LocationFilter {
  String get label => switch (this) {
        LocationFilter.all => 'All',
        LocationFilter.fastest => 'Fastest',
        LocationFilter.favourites => 'Favourites',
      };
}

/// Location picker — a map and a list that are two views of one selection,
/// built to the `Client Map Picker` mockup.
class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key, required this.state, this.onSelected});

  final AppState state;
  final VoidCallback? onSelected;

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  final _search = TextEditingController();
  LocationFilter _filter = LocationFilter.all;
  bool _pinging = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // ── Data ───────────────────────────────────────────────────────────────────

  String get _query => _search.text.trim().toLowerCase();

  bool _matches(ServerConfig s) {
    if (_filter == LocationFilter.favourites && !Storage.I.isFavourite(s.id)) {
      return false;
    }
    if (_filter == LocationFilter.fastest) {
      final p = widget.state.pings[s.id];
      if (p == null || p < 0 || p > 120) return false;
    }
    final q = _query;
    if (q.isEmpty) return true;
    return s.name.toLowerCase().contains(q) ||
        s.city.toLowerCase().contains(q) ||
        s.address.toLowerCase().contains(q) ||
        countryName(s.country).toLowerCase().contains(q) ||
        s.protocol.toLowerCase().contains(q);
  }

  List<ServerConfig> get _visible =>
      widget.state.servers.where(_matches).toList();

  /// The list, sectioned for display.
  ///
  /// With one source it stays a plain continent list — the way it has always
  /// looked. With several, each account / subscription / import gets its own
  /// heading first, because "which of my accounts is this server on" is the
  /// question that matters once there is more than one.
  List<_Section> get _sections {
    final visible = _visible;
    final sourceIds = visible.map((s) => s.sourceId).toSet();

    if (sourceIds.length <= 1) return _byContinent(visible);

    final out = <_Section>[];
    for (final source in widget.state.sources.sources) {
      if (!source.enabled) continue;
      final mine = visible.where((s) => s.sourceId == source.id).toList();
      if (mine.isEmpty) continue;
      out.add(_Section.source(source, mine.length));
      out.addAll(_byContinent(mine));
    }
    // Anything whose source has gone away still deserves to be reachable.
    final orphans =
        visible.where((s) => !_knownSource(s.sourceId)).toList();
    if (orphans.isNotEmpty) {
      out.add(const _Section(title: 'Other', kind: _SectionKind.continent));
      out.addAll(_byContinent(orphans));
    }
    return out;
  }

  bool _knownSource(String id) =>
      widget.state.sources.sources.any((s) => s.id == id);

  List<_Section> _byContinent(List<ServerConfig> servers) {
    final grouped = <String, List<ServerConfig>>{};
    for (final s in servers) {
      // A config with no country at all is not "Other" in the geographic
      // sense — it is unplaced, and saying so is what tells the user they can
      // fix it.
      final key = s.hasLocation ? continentOf(s.country) : _unplaced;
      grouped.putIfAbsent(key, () => []).add(s);
    }
    return [
      for (final name in [...continentOrder, _unplaced])
        if (grouped[name] != null)
          _Section(
            title: name,
            kind: _SectionKind.continent,
            items: grouped[name]!,
          ),
    ];
  }

  static const _unplaced = 'No location set';

  ServerConfig? get _selected => widget.state.selectedServer;

  LonLat? get _home {
    final cc = widget.state.origin.country;
    return cc.isEmpty ? null : countryCentroid[cc];
  }

  Future<void> _pingAll() async {
    setState(() => _pinging = true);
    await widget.state.pingAll();
    if (mounted) setState(() => _pinging = false);
  }

  Future<void> _select(Object id) async {
    final s = widget.state.servers.firstWhere((x) => x.id == id);
    await widget.state.selectServer(s);
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final s = _selected;
    if (s == null) return;
    await widget.state.connect(server: s);
    widget.onSelected?.call();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return wide ? _desktop() : _phone();
  }

  /// [phone] keeps the cropped, sheet-aware fit while still accepting drag and
  /// pinch. The two used to be the same switch, which is why the phone map
  /// could not be moved at all.
  Widget _map({
    required bool labels,
    required bool interactive,
    bool phone = false,
    double sheetHeight = 0,
  }) {
    final dimmed = {
      for (final s in widget.state.servers)
        if (!_matches(s)) s.id,
    };
    final nodes = buildNodes(
      widget.state.servers,
      pings: widget.state.pings,
      dimmed: dimmed,
    );
    final st = widget.state;

    return MapCanvas(
      nodes: nodes,
      home: _home,
      selectedId: _selected?.id,
      onSelect: _select,
      onNodeTap: (_) => _connect(),
      arc: _selected == null
          ? ArcState.none
          : st.isConnected
              ? ArcState.connected
              : st.isBusyConnecting
                  ? ArcState.connecting
                  : ArcState.selected,
      showLabels: labels,
      interactive: interactive,
      // Zoom buttons and hover tooltips are desktop affordances; the phone
      // pinches and taps instead.
      showZoomControls: interactive && !phone,
      showTooltip: interactive && !phone,
      // Flying the viewport on every selection fights a user who has just
      // dragged the map somewhere on purpose.
      flyToSelection: interactive && !phone,
      // The phone frames the user and their locations; the desktop shows the
      // whole world. Framing the data rather than covering the viewport is
      // what makes the phone map identical on every handset — see
      // [NaturalEarth.fitPoints].
      fitPoints: phone ? _fitPoints(nodes) : const [],
      // The desktop stage sits beside the location list, leaving a tall narrow
      // box that a contain-fit barely fills.
      maxCrop: phone ? 0.0 : 0.22,
      padding:
          phone ? EdgeInsets.only(bottom: sheetHeight) : EdgeInsets.zero,
    );
  }

  /// Everything the phone map has to have in frame: the user, and every
  /// location they can actually pick.
  ///
  /// Filtered-out nodes are excluded — a search for "germany" should tighten
  /// the map onto Germany, not keep it framed around a Tokyo server that is
  /// greyed out.
  List<LonLat> _fitPoints(List<MapNode> nodes) {
    return [
      ?_home,
      for (final n in nodes)
        if (!n.dimmed) n.coords,
    ];
  }

  /// The sheet rests covering a little under two thirds of the pane and can be
  /// pulled — or scrolled — up to nearly full height.
  ///
  /// Deliberately past halfway: at 0.52 the list showed two and a bit rows and
  /// the third was cut off exactly at the fold, so there was nothing to suggest
  /// the sheet moved at all. A partially visible fourth row is the affordance.
  static const _sheetMinFraction = 0.62;
  static const _sheetMaxFraction = 0.92;

  // ── Desktop: side list + map stage ─────────────────────────────────────────

  Widget _desktop() {
    return SafeArea(
      bottom: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 252, child: _sideList()),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 16, 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(VeilRadius.lg),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _map(labels: true, interactive: true),
                    ),
                    Positioned(top: 14, left: 14, child: _hud()),
                    Positioned(left: 14, right: 14, bottom: 14, child: _dock()),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sideList() {
    final sections = _sections;
    final countries =
        _visible.map((s) => s.country.toUpperCase()).toSet().length;

    return Container(
      decoration: BoxDecoration(
        color: VeilColors.surface,
        border: Border(right: BorderSide(color: VeilColors.borderSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Locations',
                              style: VeilText.display(size: 16, weight: 600)),
                          Text(
                            '${_visible.length} servers · $countries countries',
                            style: VeilText.ui(
                                size: 11, color: VeilColors.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Test all servers',
                      onPressed: _pinging ? null : _pingAll,
                      icon: _pinging
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.speed_rounded, size: 18),
                      color: VeilColors.text2,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _searchField(),
                const SizedBox(height: 10),
                _filterTabs(),
              ],
            ),
          ),
          Expanded(
            child: sections.isEmpty
                ? _empty()
                : _noScrollbar(
                    ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: _sectionRows(sections),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// The mockup's lists scroll without a visible bar on every platform.
  Widget _noScrollbar(Widget child) => ScrollConfiguration(
        behavior: const _NoScrollbar(),
        child: child,
      );

  Widget _searchField() => TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        style: VeilText.ui(size: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search city or country…',
          prefixIcon: Icon(Icons.search_rounded,
              size: 17, color: VeilColors.muted),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  onPressed: () => setState(_search.clear),
                  icon: Icon(Icons.close_rounded,
                      size: 15, color: VeilColors.muted),
                ),
        ),
      );

  Widget _filterTabs() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: VeilColors.surface2,
          border: Border.all(color: VeilColors.border),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            for (final f in LocationFilter.values)
              Expanded(
                child: Clickable(child: GestureDetector(
                  onTap: () => setState(() => _filter = f),
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: _filter == f ? VeilColors.elev : null,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: _filter == f
                          ? [
                              BoxShadow(
                                  color: VeilColors.shadow(0.35),
                                  blurRadius: 3,
                                  offset: Offset(0, 1))
                            ]
                          : null,
                    ),
                    child: Text(
                      f.label,
                      textAlign: TextAlign.center,
                      style: VeilText.ui(
                        size: 11.5,
                        weight: 500,
                        color:
                            _filter == f ? VeilColors.text : VeilColors.muted,
                      ),
                    ),
                  ),
                )),
              ),
          ],
        ),
      );

  List<Widget> _sectionRows(List<_Section> sections) => [
        for (final section in sections) ...[
          if (section.kind == _SectionKind.source)
            _sourceHeader(section)
          else
            _groupLabel(section.title),
          for (final s in section.items) _row(s),
        ],
      ];

  Widget _groupLabel(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(
          s.toUpperCase(),
          style: VeilText.mono(
              size: 10.5, color: VeilColors.muted, letterSpacing: 1.5),
        ),
      );

  /// Heavier than a continent label on purpose: with several accounts in play
  /// this is the boundary that matters, and it has to read as one at a glance.
  Widget _sourceHeader(_Section section) => Container(
        margin: const EdgeInsets.fromLTRB(0, 14, 0, 2),
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        decoration: BoxDecoration(
          color: VeilColors.surface2,
          border: Border(
            top: BorderSide(color: VeilColors.border),
            bottom: BorderSide(color: VeilColors.borderSoft),
          ),
        ),
        child: Row(
          children: [
            Icon(section.icon, size: 14, color: VeilColors.text2),
            const SizedBox(width: 9),
            Expanded(
              child: Text(section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(size: 12.5, weight: 600)),
            ),
            if (section.subtitle != null)
              Text(section.subtitle!,
                  style: VeilText.ui(size: 10, color: VeilColors.muted)),
          ],
        ),
      );

  Widget _row(ServerConfig s) => _ServerRow(
        server: s,
        selected: s.id == _selected?.id,
        ping: widget.state.pings[s.id],
        favourite: Storage.I.isFavourite(s.id),
        onTap: () => _select(s.id),
        onEdit: () => _editServer(s),
      );

  /// Rename / place / favourite, from the row itself.
  Future<void> _editServer(ServerConfig s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: VeilColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded,
                  size: 19),
              title: Text(s.alias == null ? 'Give it a name' : 'Change name',
                  style: VeilText.ui(size: 13.5)),
              subtitle: Text(s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: VeilText.ui(size: 11, color: VeilColors.muted)),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.place_outlined, size: 19),
              title: Text(
                  s.hasLocation ? 'Change location' : 'Set location on the map',
                  style: VeilText.ui(size: 13.5)),
              subtitle: Text(
                s.hasLocation
                    ? countryName(s.country)
                    : 'Unplaced — pick a country to see it on the map',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: VeilText.ui(size: 11, color: VeilColors.muted),
              ),
              onTap: () => Navigator.pop(context, 'geo'),
            ),
            ListTile(
              leading: Icon(
                  Storage.I.isFavourite(s.id)
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 19),
              title: Text(
                  Storage.I.isFavourite(s.id)
                      ? 'Remove favourite'
                      : 'Add to favourites',
                  style: VeilText.ui(size: 13.5)),
              onTap: () => Navigator.pop(context, 'fav'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'rename':
        await _renameServer(s);
      case 'geo':
        await _placeServer(s);
      case 'fav':
        await Storage.I.toggleFavourite(s.id);
        if (mounted) setState(() {});
    }
  }

  Future<void> _renameServer(ServerConfig s) async {
    final name = await promptForText(
      context,
      title: 'Name this location',
      hint: s.name,
      initial: s.alias ?? '',
      helper: 'The real name stays visible underneath. Clear the field to go '
          'back to it.',
    );
    if (name == null) return;
    await widget.state.setServerAlias(s, name);
    if (mounted) setState(() {});
  }

  Future<void> _placeServer(ServerConfig s) async {
    final geo = await showLocationPicker(context, s);
    if (geo == null) return;
    await widget.state.setServerLocation(s, geo.clear ? null : geo.value);
    if (mounted) setState(() {});
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.state.servers.isEmpty
                    ? 'No locations yet. Add an account, a subscription, or '
                        'paste your own configs from the Accounts tab.'
                    : 'No locations match.',
                textAlign: TextAlign.center,
                style: VeilText.ui(
                    size: 12.5, color: VeilColors.muted, height: 1.5),
              ),
            ],
          ),
        ),
      );

  // ── Stage chrome ───────────────────────────────────────────────────────────

  Widget _hud() {
    final sel = _selected;
    final home = _home;
    final origin = widget.state.origin;
    final distance = (home != null && sel != null)
        ? serverCoords(sel) == null
            ? null
            : distanceKm(home, serverCoords(sel)!)
        : null;

    // Wraps rather than a Row: the stage is only ~520px wide once the sidebar
    // and the location list have taken their share, and three fixed cards
    // overflowed it.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!origin.isEmpty)
          _HudCard(
            dot: VeilColors.info,
            label: 'You',
            value: origin.country.isEmpty
                ? origin.ip
                : countryName(origin.country),
          ),
        if (sel != null)
          _HudCard(label: 'Selected', value: sel.displayName),
        if (distance != null)
          _HudCard(label: 'Distance', value: '${_thousands(distance)} km'),
      ],
    );
  }

  static String _thousands(int n) {
    final s = '$n';
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(' ');
      out.write(s[i]);
    }
    return out.toString();
  }

  Widget _dock() {
    final s = _selected;
    if (s == null) return const SizedBox.shrink();
    final ping = widget.state.pings[s.id];
    final fav = Storage.I.isFavourite(s.id);
    final st = widget.state;
    final live = st.isConnected && st.activeServer?.id == s.id;

    return _Dock(
      server: s,
      ping: ping,
      favourite: fav,
      connected: live,
      busy: st.isBusyConnecting,
      onFavourite: () async {
        await Storage.I.toggleFavourite(s.id);
        if (mounted) setState(() {});
      },
      onConnect: live ? st.disconnect : _connect,
      onCancel: st.disconnect,
    );
  }

  // ── Phone: full-bleed map with a sheet ─────────────────────────────────────

  Widget _phone() {
    // The sheet sizes itself as a fraction of *this* box, not of the screen:
    // `DraggableScrollableSheet` measures its parent. The map's bottom padding
    // used to be a fraction of `MediaQuery.height` instead, and the two differ
    // by the status bar, the navigation bar and the title bar — by a different
    // amount on every device. That mismatch fed straight into the projection's
    // scale, which is the other half of "every phone shows the map
    // differently". One LayoutBuilder, one number, both consumers.
    return LayoutBuilder(
      builder: (context, box) =>
          _phoneBody(box.maxHeight * _sheetMinFraction),
    );
  }

  Widget _phoneBody(double sheetHeight) {
    final sections = _sections;
    final live = _selected != null &&
        widget.state.isConnected &&
        widget.state.activeServer?.id == _selected!.id;

    return Stack(
      children: [
        Positioned.fill(
          child: _map(
            labels: false,
            interactive: true,
            phone: true,
            sheetHeight: sheetHeight,
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Row(
              children: [
                Text('Choose location',
                    style: VeilText.display(size: 17, weight: 600)),
                const Spacer(),
                IconButton(
                  tooltip: 'Test all servers',
                  onPressed: _pinging ? null : _pingAll,
                  icon: _pinging
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.speed_rounded, size: 18),
                  color: VeilColors.text2,
                ),
              ],
            ),
          ),
        ),
        _Sheet(
          minFraction: _sheetMinFraction,
          maxFraction: _sheetMaxFraction,
          listBuilder: (scrollController) => sections.isEmpty
              ? _empty()
              : _noScrollbar(
                  ListView(
                    // Owned by the sheet: dragging the list past its top edge
                    // is what pulls the sheet taller, so more of the world's
                    // locations are visible at once.
                    controller: scrollController,
                    padding: const EdgeInsets.only(bottom: 10),
                    children: _sectionRows(sections),
                  ),
                ),
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_selected != null) _sheetHeader(_selected!),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: _searchField(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: _filterTabs(),
              ),
            ],
          ),
          footer: _selected == null
              ? null
              : Padding(
                  padding: EdgeInsets.fromLTRB(
                      14, 8, 14, 10 + mobileTabBarClearance(context)),
                  child: PrimaryActionButton(
                    label: live
                        ? 'Disconnect'
                        : 'Connect to ${_selected!.displayName}',
                    busy: widget.state.isBusyConnecting,
                    danger: live,
                    onTap: live ? widget.state.disconnect : _connect,
                    onCancel: widget.state.disconnect,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _sheetHeader(ServerConfig s) {
    final ping = widget.state.pings[s.id];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Row(
        children: [
          CountryFlagBox(country: s.country, fallback: s.name, width: 38, height: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VeilText.display(size: 14.5, weight: 600)),
                const SizedBox(height: 1),
                Text(
                  [
                    if (s.place.isNotEmpty) s.place,
                    if (ping != null && ping >= 0) '$ping ms',
                    if (s.load != null) '${s.load}% load',
                    s.protoLabel,
                  ].join(' · '),
                  style: VeilText.ui(size: 11, color: VeilColors.muted),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: VeilColors.accentTint,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('SELECTED',
                style: VeilText.ui(
                    size: 8.5,
                    weight: 600,
                    color: VeilColors.accent,
                    letterSpacing: 1)),
          ),
        ],
      ),
    );
  }
}

enum _SectionKind { source, continent }

/// One heading in the picker, plus the rows under it.
class _Section {
  const _Section({
    required this.title,
    required this.kind,
    this.items = const [],
    this.subtitle,
    this.icon,
  });

  factory _Section.source(LocationSource source, int count) => _Section(
        title: source.displayLabel,
        kind: _SectionKind.source,
        subtitle: '${source.kind.label} · $count',
        icon: switch (source.kind) {
          SourceKind.account => Icons.account_circle_rounded,
          SourceKind.subscription => Icons.rss_feed_rounded,
          SourceKind.manual => Icons.content_paste_rounded,
        },
      );

  final String title;
  final _SectionKind kind;
  final List<ServerConfig> items;
  final String? subtitle;
  final IconData? icon;
}

/// Scroll behaviour with no visible bar, which the mockup's lists rely on.
class _NoScrollbar extends ScrollBehavior {
  const _NoScrollbar();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails d) =>
      child;

  @override
  Widget buildOverscrollIndicator(
          BuildContext context, Widget child, ScrollableDetails d) =>
      child;
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.selected,
    required this.ping,
    required this.favourite,
    required this.onTap,
    required this.onEdit,
  });

  final ServerConfig server;
  final bool selected;
  final int? ping;
  final bool favourite;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Clickable(
      child: GestureDetector(
      onTap: onTap,
      // Long-press anywhere on the row is the phone's way in; the trailing
      // button is the pointer's.
      onLongPress: onEdit,
      onSecondaryTap: onEdit,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        color: selected ? VeilColors.accentTint : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        child: Row(
          children: [
            // Selected marker rail, matching the mockup's ::before bar.
            Container(
              width: 2,
              height: 26,
              margin: const EdgeInsets.only(right: 9),
              decoration: BoxDecoration(
                color: selected ? VeilColors.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
                boxShadow: selected
                    ? [
                        BoxShadow(
                            color: VeilColors.accent.withValues(alpha: 0.7),
                            blurRadius: 10)
                      ]
                    : null,
              ),
            ),
            CountryFlagBox(
                country: server.country,
                fallback: server.name,
                selected: selected),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(_primary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VeilText.ui(size: 13, weight: 600)),
                      ),
                      if (favourite) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: VeilColors.accentTint,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text('FAV',
                              style: VeilText.ui(
                                  size: 8.5,
                                  weight: 600,
                                  color: VeilColors.accent,
                                  letterSpacing: 1)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    _secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // A user-set name sits above the real one, and the real
                    // one is deliberately quieter — it is there to identify,
                    // not to compete.
                    style: server.alias != null
                        ? VeilText.mono(
                            size: 10, color: VeilColors.muted.withValues(alpha: 0.8))
                        : VeilText.ui(size: 11, color: VeilColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ping == null ? '— ms' : (ping! < 0 ? 'fail' : '$ping ms'),
                  style: VeilText.mono(
                      size: 11, weight: 500, color: pingColour(ping)),
                ),
                const SizedBox(height: 3),
                SignalBars(ping: ping),
              ],
            ),
            SizedBox(
              width: 26,
              child: IconButton(
                tooltip: 'Rename or place this location',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                iconSize: 15,
                color: VeilColors.muted,
                onPressed: onEdit,
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// The config's own name — the user's alias if they set one, otherwise
  /// whatever the panel called it.
  ///
  /// This used to be [ServerConfig.city], which prefers the panel's
  /// GeoIP-derived region: an inbound named "DE-Frankfurt-01" was listed as
  /// "Germany", and every German inbound looked identical. The name is what
  /// the operator chose and what the customer was told to pick, so it leads.
  String get _primary => server.displayName;

  /// Under the name: where it is, plus the real name when an alias is hiding
  /// it — or a prompt when nobody has said where this is.
  String get _secondary {
    final real = server.secondaryName;
    if (!server.hasLocation) {
      return real == null ? 'Location not set' : '$real · Location not set';
    }
    final place = server.place;
    if (real == null) return place.isEmpty ? server.address : place;
    return place.isEmpty ? real : '$real · $place';
  }
}

/// Result of the location picker: either a position, or an instruction to
/// forget the one that was set.
class GeoChoice {
  const GeoChoice.set(this.value) : clear = false;
  const GeoChoice.cleared()
      : value = null,
        clear = true;

  final GeoOverride? value;
  final bool clear;
}

/// Lets the user say where a config actually is.
///
/// Subscriptions and pasted links carry no geography, so without this they can
/// never appear anywhere sensible on the world map — they sit in a holding
/// pen in the mid-Atlantic. A country is enough; latitude and longitude are
/// there for anyone who wants the pin exact.
Future<GeoChoice?> showLocationPicker(
    BuildContext context, ServerConfig server) {
  return showDialog<GeoChoice>(
    context: context,
    builder: (context) => _LocationPickerDialog(server: server),
  );
}

class _LocationPickerDialog extends StatefulWidget {
  const _LocationPickerDialog({required this.server});

  final ServerConfig server;

  @override
  State<_LocationPickerDialog> createState() => _LocationPickerDialogState();
}

class _LocationPickerDialogState extends State<_LocationPickerDialog> {
  late String _country = widget.server.country.toUpperCase();
  late final _search = TextEditingController();
  late final _lat = TextEditingController(
      text: widget.server.lat == null ? '' : '${widget.server.lat}');
  late final _lon = TextEditingController(
      text: widget.server.lon == null ? '' : '${widget.server.lon}');

  @override
  void dispose() {
    _search.dispose();
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }

  List<MapEntry<String, String>> get _countries {
    final q = _search.text.trim().toLowerCase();
    final all = knownCountries.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (q.isEmpty) return all;
    return all
        .where((e) =>
            e.value.toLowerCase().contains(q) ||
            e.key.toLowerCase() == q)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VeilColors.surface,
      title: Text('Where is this server?',
          style: VeilText.display(size: 16, weight: 600)),
      content: SizedBox(
        width: 380,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: VeilText.ui(size: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search country…',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 17, color: VeilColors.muted),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: _countries.length,
                itemBuilder: (context, i) {
                  final e = _countries[i];
                  final on = e.key == _country;
                  return InkWell(
                    onTap: () => setState(() => _country = e.key),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 9),
                      color: on ? VeilColors.accentTint : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 30,
                            child: Text(e.key,
                                style: VeilText.mono(
                                    size: 11,
                                    weight: 600,
                                    color: on
                                        ? VeilColors.accent
                                        : VeilColors.muted)),
                          ),
                          Expanded(
                            child: Text(e.value,
                                style: VeilText.ui(
                                    size: 12.5,
                                    color: on
                                        ? VeilColors.accent
                                        : VeilColors.text)),
                          ),
                          if (on)
                            Icon(Icons.check_rounded,
                                size: 15, color: VeilColors.accent),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _coordField(_lat, 'Latitude')),
                const SizedBox(width: 8),
                Expanded(child: _coordField(_lon, 'Longitude')),
              ],
            ),
            const SizedBox(height: 6),
            Text('Optional — the country centre is used when these are blank.',
                style: VeilText.ui(size: 10.5, color: VeilColors.muted)),
          ],
        ),
      ),
      actions: [
        if (widget.server.geoIsManual)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const GeoChoice.cleared()),
            child: Text('Clear',
                style: VeilText.ui(size: 12.5, color: VeilColors.danger)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _country.isEmpty ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _coordField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(
            decimal: true, signed: true),
        style: VeilText.mono(size: 12),
        decoration: InputDecoration(isDense: true, labelText: label),
      );

  void _save() {
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    Navigator.pop(
      context,
      GeoChoice.set(GeoOverride(
        country: _country,
        // Out-of-range numbers would put the pin off the projection entirely,
        // so a bad value is treated as "not given" rather than obeyed.
        lat: (lat != null && lat.abs() <= 90) ? lat : null,
        lon: (lon != null && lon.abs() <= 180) ? lon : null,
      )),
    );
  }
}

/// Latency colour ramp shared by the rows, dock and map.
Color pingColour(int? ping) {
  if (ping == null) return VeilColors.muted;
  if (ping < 0) return VeilColors.danger;
  if (ping < 25) return VeilColors.accent;
  if (ping < 50) return VeilColors.warn;
  return VeilColors.danger;
}

/// Four ascending bars, lit according to latency.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.ping});

  final int? ping;

  @override
  Widget build(BuildContext context) {
    final p = ping;
    final lit = p == null || p < 0
        ? 0
        : p < 20
            ? 4
            : p < 32
                ? 3
                : p < 55
                    ? 2
                    : 1;
    final colour = pingColour(p);
    const heights = [4.0, 7.0, 9.0, 11.0];

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < heights.length; i++) ...[
          if (i > 0) const SizedBox(width: 1.5),
          Container(
            width: 2.5,
            height: heights[i],
            decoration: BoxDecoration(
              color: i < lit ? colour : VeilColors.muted.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ],
    );
  }
}

class _HudCard extends StatelessWidget {
  const _HudCard({required this.label, required this.value, this.dot});

  final String label;
  final String value;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: VeilColors.surface.withValues(alpha: 0.82),
          border: Border.all(color: VeilColors.border),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dot,
                  boxShadow: [
                    BoxShadow(color: dot!.withValues(alpha: 0.8), blurRadius: 9)
                  ],
                ),
              ),
              const SizedBox(width: 9),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label.toUpperCase(),
                      style: VeilText.ui(
                          size: 9.5,
                          weight: 600,
                          color: VeilColors.muted,
                          letterSpacing: 1.4)),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VeilText.mono(size: 11.5, weight: 600)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _Dock extends StatelessWidget {
  const _Dock({
    required this.server,
    required this.ping,
    required this.favourite,
    required this.connected,
    required this.busy,
    required this.onFavourite,
    required this.onConnect,
    required this.onCancel,
  });

  final ServerConfig server;
  final int? ping;
  final bool favourite;
  final bool connected;
  final bool busy;
  final VoidCallback onFavourite;
  final VoidCallback onConnect;

  /// Abandons an attempt that is still in flight.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(server.id),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
        decoration: BoxDecoration(
          color: VeilColors.surface.withValues(alpha: 0.88),
          border: Border.all(color: VeilColors.border),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: VeilColors.shadow(0.50), blurRadius: 44, offset: Offset(0, 18)),
          ],
        ),
        child: Row(
          children: [
            CountryFlagBox(
                country: server.country,
                fallback: server.name,
                width: 40,
                height: 30,
                selected: true),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(server.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: VeilText.display(size: 15, weight: 600)),
                  const SizedBox(height: 3),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 190),
                        child: Text(server.address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: VeilText.mono(
                                size: 11.5, color: VeilColors.muted)),
                      ),
                      const _DockSep(),
                      Text(
                        ping == null
                            ? '— ms'
                            : (ping! < 0 ? 'fail' : '$ping ms'),
                        style:
                            VeilText.mono(size: 11.5, color: pingColour(ping)),
                      ),
                      if (server.load != null) ...[
                        const _DockSep(),
                        Text('load',
                            style: VeilText.ui(
                                size: 11.5, color: VeilColors.muted)),
                        const SizedBox(width: 6),
                        _LoadMeter(percent: server.load!),
                        const SizedBox(width: 6),
                        Text('${server.load}%',
                            style: VeilText.mono(
                                size: 11.5, color: VeilColors.muted)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _GhostButton(
              label: favourite ? 'Remove favourite' : 'Add to favourites',
              icon: favourite ? Icons.star_rounded : Icons.star_outline_rounded,
              onTap: onFavourite,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 150,
              child: PrimaryActionButton(
                label: connected ? 'Disconnect' : 'Connect',
                busy: busy,
                danger: connected,
                onTap: onConnect,
                onCancel: onCancel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockSep extends StatelessWidget {
  const _DockSep();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7),
        child: Text('·', style: VeilText.ui(size: 11.5, color: VeilColors.muted)),
      );
}

class _LoadMeter extends StatelessWidget {
  const _LoadMeter({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 60,
        height: 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: Stack(
            children: [
              Container(color: VeilColors.borderSoft),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: (percent / 100).clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => FractionallySizedBox(
                  widthFactor: v,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [VeilColors.accentLo, VeilColors.accentHi],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: Clickable(child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: VeilColors.surface2,
              border: Border.all(color: VeilColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: VeilColors.text2),
                const SizedBox(width: 7),
                Text('Favourite',
                    style: VeilText.ui(
                        size: 13, weight: 600, color: VeilColors.text2)),
              ],
            ),
          ),
        )),
      );
}

/// The phone's bottom sheet.
///
/// Draggable rather than a fixed slab: scrolling the location list drags the
/// sheet up first, so a long list gets the room it needs instead of being read
/// through a half-screen slot.
class _Sheet extends StatefulWidget {
  const _Sheet({
    required this.header,
    required this.listBuilder,
    required this.minFraction,
    required this.maxFraction,
    this.footer,
  });

  final Widget header;
  final Widget Function(ScrollController) listBuilder;
  final Widget? footer;
  final double minFraction;
  final double maxFraction;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  /// Lets the grab handle move the sheet.
  ///
  /// `DraggableScrollableSheet` only responds to the scrollable it hands the
  /// builder, so dragging the handle — or the search box, or the header, which
  /// is the whole top third of the sheet — did nothing at all. That is the
  /// "cannot move it up" half of the bug.
  final _controller = DraggableScrollableController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dragBy(double dy) {
    if (!_controller.isAttached) return;
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    final next = (_controller.size - dy / height)
        .clamp(widget.minFraction, widget.maxFraction);
    _controller.jumpTo(next);
  }

  /// Settle to whichever stop is nearer, so a half-drag never sticks.
  void _settle() {
    if (!_controller.isAttached) return;
    final mid = (widget.minFraction + widget.maxFraction) / 2;
    _controller.animateTo(
      _controller.size >= mid ? widget.maxFraction : widget.minFraction,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggle() {
    if (!_controller.isAttached) return;
    final mid = (widget.minFraction + widget.maxFraction) / 2;
    _controller.animateTo(
      _controller.size >= mid ? widget.minFraction : widget.maxFraction,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeOutCubic,
      builder: (context, t, sheet) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 60 * (1 - t)), child: sheet),
      ),
      child: DraggableScrollableSheet(
        controller: _controller,
        initialChildSize: widget.minFraction,
        minChildSize: widget.minFraction,
        maxChildSize: widget.maxFraction,
        snap: true,
        snapSizes: [widget.minFraction, widget.maxFraction],
        builder: (context, scrollController) => DecoratedBox(
          decoration: BoxDecoration(
            color: VeilColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            border: Border(top: BorderSide(color: VeilColors.border)),
            boxShadow: [
              BoxShadow(
                  color: VeilColors.shadow(0.55),
                  blurRadius: 50,
                  offset: Offset(0, -20)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The handle and the header are one grab area — that is where
              // people put their thumb.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
                onVerticalDragEnd: (_) => _settle(),
                child: Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(top: 11, bottom: 8),
                    decoration: BoxDecoration(
                      color: VeilColors.muted,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onVerticalDragUpdate: (d) => _dragBy(d.delta.dy),
                onVerticalDragEnd: (_) => _settle(),
                child: widget.header,
              ),
              Expanded(child: widget.listBuilder(scrollController)),
              ?widget.footer,
            ],
          ),
        ),
      ),
    );
  }
}

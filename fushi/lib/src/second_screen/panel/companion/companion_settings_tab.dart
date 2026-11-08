import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/settings_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_settings_controller.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The companion's Settings tab (S4): a search field, the settings of what
/// the top screen shows ("For this screen · Reader"), then every category.
/// Categories and long choice lists open as pages in the tab's own
/// navigator. Values live in the main process: every page asks the main
/// engine (`settings.*` requests), writes go back to it, and a
/// `settingsChanged` ping reloads what is shown.
class CompanionSettingsTab extends ConsumerStatefulWidget {
  const CompanionSettingsTab({super.key});

  @override
  ConsumerState<CompanionSettingsTab> createState() =>
      _CompanionSettingsTabState();
}

/// Keeps a page's feeds in step with the main engine: a `settingsChanged`
/// ping (or [contextInvalidates]) marks them stale; the shown one reloads at
/// once while the page is visible (its tab is selected and no page is pushed
/// on top of it), the others when they are shown again.
mixin _CompanionSettingsLive<W extends StatefulWidget> on State<W> {
  late CompanionPanelSession _session;
  int _revision = 0;
  bool _visible = false;
  final Set<CompanionSettingsFeed> _staleFeeds = <CompanionSettingsFeed>{};

  /// Every feed of the page.
  List<CompanionSettingsFeed> get liveFeeds;

  /// The feed the page shows right now.
  CompanionSettingsFeed get shownFeed;

  /// Also reload when this returns true on a session change (the overview
  /// follows the top screen's context).
  bool contextInvalidates() => false;

  void startLive(CompanionPanelSession session) {
    _session = session;
    _revision = session.settingsRevision;
    _staleFeeds.addAll(liveFeeds);
    session.addListener(_onSession);
  }

  void _onSession() {
    final bool revised = _session.settingsRevision != _revision;
    _revision = _session.settingsRevision;
    final bool moved = contextInvalidates();
    if (!revised && !moved) return;
    _staleFeeds.addAll(liveFeeds);
    syncLive();
  }

  /// Reloads the shown feed if it is stale and the page is visible.
  void syncLive() {
    if (!_visible) return;
    final CompanionSettingsFeed feed = shownFeed;
    if (_staleFeeds.remove(feed)) unawaited(feed.refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    syncLive();
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    super.dispose();
  }
}

class _CompanionSettingsTabState extends ConsumerState<CompanionSettingsTab>
    with _CompanionSettingsLive<CompanionSettingsTab> {
  late final CompanionPanelSession _panel;
  late final CompanionSettingsFeed _overview;
  late final CompanionSettingsFeed _search;
  late CompanionContext _context;
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'companion-settings');

  @override
  void initState() {
    super.initState();
    _panel = ref.read(companionPanelSessionProvider);
    _overview = CompanionSettingsFeed.overview(_panel);
    _search = CompanionSettingsFeed.search(_panel);
    _context = _panel.context;
    _query.text = _panel.uiState.settingsQuery;
    startLive(_panel);
    if (_searching) {
      _staleFeeds.remove(_search);
      unawaited(_search.search(_query.text.trim()));
    }
  }

  /// The category page pushed on this tab (its id); null on the overview.
  String? _openCategory;

  /// Reports the search and the open category page (a relaunched panel
  /// shows them again).
  void _reportUi() => _panel.updateUi(
    (CompanionPanelUiState ui) => ui.copyWith(
      settingsCategory: () => _openCategory,
      settingsQuery: _query.text.trim(),
    ),
  );

  /// The main engine handed back the last panel's state: its search and its
  /// category page (unless one is open already). Not reported back (it is
  /// what the session holds already).
  void _restoreUi() {
    final CompanionPanelUiState ui = _panel.uiState;
    if (_query.text.trim() != ui.settingsQuery) {
      _query.text = ui.settingsQuery;
      _applyQuery();
    }
    final String? id = ui.settingsCategory;
    if (id != null && _openCategory == null) {
      final String title =
          _overview.view?.categories
              .where((CompanionSettingsCategory c) => c.id == id)
              .firstOrNull
              ?.title ??
          '';
      _showCategory(
        CompanionSettingsCategory(id: id, title: title),
        report: false,
      );
    }
  }

  void _showCategory(CompanionSettingsCategory category, {bool report = true}) {
    _openCategory = category.id;
    if (report) _reportUi();
    unawaited(
      Navigator.of(context)
          .push<void>(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) => _CompanionSettingsCategoryPage(
                session: _panel,
                category: category,
              ),
            ),
          )
          .then((void _) {
            if (!mounted || _openCategory != category.id) return;
            _openCategory = null;
            _reportUi();
          }),
    );
  }

  @override
  void dispose() {
    _overview.dispose();
    _search.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  bool get _searching => _query.text.trim().isNotEmpty;

  @override
  List<CompanionSettingsFeed> get liveFeeds => <CompanionSettingsFeed>[
    _overview,
    _search,
  ];

  @override
  CompanionSettingsFeed get shownFeed => _searching ? _search : _overview;

  @override
  bool contextInvalidates() {
    final CompanionContext now = _panel.context;
    if (now == _context) return false;
    _context = now;
    return true;
  }

  void _onQueryChanged(String _) {
    _applyQuery();
    _reportUi();
  }

  /// Shows the overview or the search results for the field's text.
  void _applyQuery() {
    final String query = _query.text.trim();
    if (query.isEmpty) {
      setState(() {});
      syncLive();
      return;
    }
    // Every keystroke asks once; the feed drops replies a newer query
    // overtook and asks again for the latest one.
    final bool stale = _staleFeeds.remove(_search);
    if (stale || query != _search.query) unawaited(_search.search(query));
    setState(() {});
  }

  void _clearQuery() {
    _query.clear();
    _onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      companionPanelSessionProvider.select(
        (CompanionPanelSession s) => s.uiRestores,
      ),
      (int? _, int _) => _restoreUi(),
    );
    final bool searching = _searching;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: FushiSearchField(
                fieldKey: const ValueKey<String>('companion-settings-search'),
                controller: _query,
                focusNode: _queryFocus,
                hintText: t.second_screen_settings_search_hint,
                onChanged: _onQueryChanged,
                onSubmitted: _onQueryChanged,
                onClear: _clearQuery,
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: fushiMotionDuration(context, FushiMotion.short),
                child: searching
                    ? _FeedBody(
                        key: const ValueKey<String>(
                          'companion-settings-results',
                        ),
                        feed: _search,
                        emptyMessage: t.second_screen_settings_no_match,
                        builder: (CompanionSettingsView view) => _rowItems(
                          context,
                          feed: _search,
                          rows: view.rows,
                          label: t.second_screen_settings_search_results,
                        ),
                        isEmpty: (CompanionSettingsView view) =>
                            view.rows.isEmpty,
                      )
                    : _FeedBody(
                        key: const ValueKey<String>(
                          'companion-settings-overview',
                        ),
                        feed: _overview,
                        emptyMessage: t.second_screen_settings_page_empty,
                        builder: (CompanionSettingsView view) =>
                            _overviewItems(context, view),
                        isEmpty: (CompanionSettingsView view) =>
                            view.rows.isEmpty && view.categories.isEmpty,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _overviewItems(
    BuildContext context,
    CompanionSettingsView view,
  ) {
    final CompanionSettingsCategory? category = view.category;
    return <Widget>[
      if (category != null && view.rows.isNotEmpty) ...<Widget>[
        _Caption(t.second_screen_settings_context(title: category.title)),
        _RowsCard(rows: view.rows, feed: _overview, session: _panel),
      ],
      if (view.categories.isNotEmpty) ...<Widget>[
        _Caption(t.second_screen_settings_all),
        ..._categoryGrid(context, view.categories),
      ],
    ];
  }

  List<Widget> _categoryGrid(
    BuildContext context,
    List<CompanionSettingsCategory> categories,
  ) => <Widget>[
    for (int i = 0; i < categories.length; i += 2)
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: <Widget>[
            Expanded(child: _categoryTile(context, categories[i])),
            const SizedBox(width: 8),
            Expanded(
              child: i + 1 < categories.length
                  ? _categoryTile(context, categories[i + 1])
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
  ];

  Widget _categoryTile(
    BuildContext context,
    CompanionSettingsCategory category,
  ) => _CategoryTile(category: category, onTap: () => _showCategory(category));
}

/// One category's rows, grouped by section, with "Open on main screen".
class _CompanionSettingsCategoryPage extends StatefulWidget {
  const _CompanionSettingsCategoryPage({
    required this.session,
    required this.category,
  });

  final CompanionPanelSession session;
  final CompanionSettingsCategory category;

  @override
  State<_CompanionSettingsCategoryPage> createState() =>
      _CompanionSettingsCategoryPageState();
}

class _CompanionSettingsCategoryPageState
    extends State<_CompanionSettingsCategoryPage>
    with _CompanionSettingsLive<_CompanionSettingsCategoryPage> {
  late final CompanionSettingsFeed _feed;

  @override
  void initState() {
    super.initState();
    _feed = CompanionSettingsFeed.category(widget.session, widget.category.id);
    startLive(widget.session);
  }

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  @override
  List<CompanionSettingsFeed> get liveFeeds => <CompanionSettingsFeed>[_feed];

  @override
  CompanionSettingsFeed get shownFeed => _feed;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PageHeader(
            title: _feed.view?.category?.title ?? widget.category.title,
            trailing: _OpenOnMainButton(
              key: const ValueKey<String>('companion-settings-category-open'),
              onPressed: () => _openOnMain(
                context,
                widget.session,
                category: widget.category.id,
              ),
            ),
          ),
          Expanded(
            child: _FeedBody(
              feed: _feed,
              emptyMessage: t.second_screen_settings_page_empty,
              isEmpty: (CompanionSettingsView view) => view.rows.isEmpty,
              builder: (CompanionSettingsView view) => _rowItems(
                context,
                feed: _feed,
                rows: view.rows,
                session: widget.session,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// [rows] as small section captions + one card per section, under [label].
List<Widget> _rowItems(
  BuildContext context, {
  required CompanionSettingsFeed feed,
  required List<CompanionSettingRow> rows,
  CompanionPanelSession? session,
  String? label,
}) {
  final CompanionPanelSession panel = session ?? feed.session;
  final List<Widget> items = <Widget>[
    ?(label == null ? null : _Caption(label)),
  ];
  int start = 0;
  while (start < rows.length) {
    final String? section = rows[start].section;
    int end = start + 1;
    while (end < rows.length && rows[end].section == section) {
      end++;
    }
    if (section != null) items.add(_Caption(section));
    items.add(
      _RowsCard(rows: rows.sublist(start, end), feed: feed, session: panel),
    );
    start = end;
  }
  return items;
}

/// Loading / error / empty states around a feed's list of items.
class _FeedBody extends StatelessWidget {
  const _FeedBody({
    required this.feed,
    required this.builder,
    required this.isEmpty,
    required this.emptyMessage,
    super.key,
  });

  final CompanionSettingsFeed feed;
  final List<Widget> Function(CompanionSettingsView view) builder;
  final bool Function(CompanionSettingsView view) isEmpty;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: feed,
    builder: (BuildContext context, Widget? _) {
      final CompanionSettingsView? view = feed.view;
      final Widget body;
      if (view == null && feed.failed) {
        body = _Placeholder(
          key: const ValueKey<String>('companion-settings-error'),
          icon: FushiIcons.error,
          message: t.second_screen_settings_load_failed,
          action: FushiFilledButton.tonal(
            key: const ValueKey<String>('companion-settings-retry'),
            onPressed: () => unawaited(feed.retry()),
            child: Text(t.retry),
          ),
        );
      } else if (view == null) {
        body = const Center(
          key: ValueKey<String>('companion-settings-loading'),
          child: FushiCircularProgressIndicator(),
        );
      } else if (isEmpty(view)) {
        body = _Placeholder(
          key: const ValueKey<String>('companion-settings-empty'),
          icon: FushiIcons.settings,
          message: emptyMessage,
        );
      } else {
        final List<Widget> items = builder(view);
        body = FushiEntranceScope(
          key: const ValueKey<String>('companion-settings-list'),
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              4,
              16,
              16 + MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: items.length,
            itemBuilder: fushiStaggeredItemBuilder(
              (BuildContext context, int index) => items[index],
            ),
          ),
        );
      }
      return AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.short),
        child: body,
      );
    },
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => FushiEntranceScope(
    child: FushiStaggeredEntrance(
      index: 0,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: FushiPlaceholderMessage(
            icon: icon,
            message: message,
            action: action,
            tone: action == null
                ? FushiPlaceholderTone.neutral
                : FushiPlaceholderTone.error,
          ),
        ),
      ),
    ),
  );
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
    child: CompanionSectionLabel(text),
  );
}

/// Back + title + an action, on top of a pushed page.
class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 12, 4),
    child: Row(
      children: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('companion-settings-back'),
          icon: FushiIcons.back,
          tooltip: t.back,
          onTap: () => unawaited(Navigator.of(context).maybePop()),
          padTouchTarget: true,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (trailing case final Widget end) ...<Widget>[
          const SizedBox(width: 8),
          end,
        ],
      ],
    ),
  );
}

/// "Appearance ›": opens the category's page.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.onTap});

  final CompanionSettingsCategory category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiPressScale(
      child: Semantics(
        button: true,
        label: category.title,
        excludeSemantics: true,
        child: FushiCard(
          key: ValueKey<String>('companion-settings-category-${category.id}'),
          pressScale: false,
          borderRadius: FushiM3eShape.smallRadius,
          onTap: onTap,
          padding: const EdgeInsetsDirectional.fromSTEB(14, 0, 8, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    category.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                FushiIcon(
                  FushiIcons.chevronRight,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One section's rows on a card, with thin dividers between them.
class _RowsCard extends StatelessWidget {
  const _RowsCard({
    required this.rows,
    required this.feed,
    required this.session,
  });

  final List<CompanionSettingRow> rows;
  final CompanionSettingsFeed feed;
  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => FushiCard(
    pressScale: false,
    stateLayer: false,
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          _SettingRow(
            key: ValueKey<String>('companion-setting-${rows[i].key}'),
            row: rows[i],
            feed: feed,
            session: session,
          ),
        ],
      ],
    ),
  );
}

Future<void> _openOnMain(
  BuildContext context,
  CompanionPanelSession session, {
  String? key,
  String? category,
}) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final bool ok = await companionSettingsOpenOnMain(
    session,
    key: key,
    category: category,
  );
  messenger?.showSnackBar(
    FushiSnackBar(
      content: Text(
        ok
            ? t.second_screen_settings_opened_on_main
            : t.second_screen_settings_open_failed,
      ),
    ),
  );
}

/// "Open on main screen" (open rows, category pages).
class _OpenOnMainButton extends StatelessWidget {
  const _OpenOnMainButton({required this.onPressed, super.key});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FushiPressScale(
    enabled: onPressed != null,
    child: FushiOutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: onPressed,
      icon: const FushiIcon(FushiIcons.openInNew, size: 18),
      label: Text(
        t.second_screen_settings_open_on_main,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// One setting with the control its kind asks for.
class _SettingRow extends StatefulWidget {
  const _SettingRow({
    required this.row,
    required this.feed,
    required this.session,
    super.key,
  });

  final CompanionSettingRow row;
  final CompanionSettingsFeed feed;
  final CompanionPanelSession session;

  @override
  State<_SettingRow> createState() => _SettingRowState();
}

class _SettingRowState extends State<_SettingRow> {
  /// The slider's position while it is dragged (written on release only).
  double? _drag;

  @override
  void didUpdateWidget(_SettingRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.row.value != widget.row.value) _drag = null;
  }

  CompanionSettingRow get row => widget.row;

  bool get _enabled => row.enabled;

  Future<void> _write(Object value) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    final bool ok = await widget.feed.write(row, value);
    if (!ok) {
      messenger?.showSnackBar(
        FushiSnackBar(content: Text(t.second_screen_settings_write_failed)),
      );
    }
  }

  void _commit(Object value) => unawaited(_write(value));

  @override
  Widget build(BuildContext context) {
    final Widget content = switch (row.control) {
      CompanionSettingControl.toggle => _toggle(context),
      CompanionSettingControl.choice => _choice(context),
      CompanionSettingControl.slider => _slider(context),
      CompanionSettingControl.stepper => _stepper(context),
      CompanionSettingControl.number =>
        row.step != null ? _stepper(context) : _number(context),
      CompanionSettingControl.open => _open(context),
    };
    return Opacity(
      opacity: _enabled ? 1 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: content,
      ),
    );
  }

  Widget _title(
    BuildContext context, {
    String? trailing,
    bool subtitle = true,
  }) {
    final ThemeData theme = Theme.of(context);
    final String? sub = subtitle ? row.subtitle : null;
    final String? end = trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                row.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge,
              ),
            ),
            if (end != null && end.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                end,
                maxLines: 1,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
        if (sub != null)
          Text(
            sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Widget _line(BuildContext context, Widget title, Widget control) =>
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: <Widget>[
            Expanded(child: title),
            const SizedBox(width: 12),
            control,
          ],
        ),
      );

  Widget _toggle(BuildContext context) {
    final bool value = row.boolValue ?? false;
    return _line(
      context,
      _title(context),
      adaptiveSwitch(
        context: context,
        value: value,
        onChanged: _enabled ? (bool next) => _commit(next) : null,
      ),
    );
  }

  /// Segmented when the options are few and short enough for ~440 dp.
  bool get _segmented {
    final int n = row.options.length;
    if (n < 2 || n > 4) return false;
    final int longest = row.options
        .map((CompanionSettingOption o) => o.label.length)
        .fold(0, (int a, int b) => a > b ? a : b);
    return n <= 3 ? longest <= 12 : longest <= 8;
  }

  Widget _choice(BuildContext context) {
    final String? current = row.choiceValue;
    if (!_segmented) {
      return _ChoiceLine(
        row: row,
        onTap: _enabled ? () => unawaited(_pick(context)) : null,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _title(context),
          const SizedBox(height: 8),
          adaptiveSegmentedButton<String>(
            context: context,
            segments: <ButtonSegment<String>>[
              for (final CompanionSettingOption o in row.options)
                ButtonSegment<String>(
                  value: o.value,
                  label: Text(o.label, maxLines: 1),
                  enabled: _enabled,
                ),
            ],
            selected: <String>{?current},
            onSelectionChanged: (Set<String> next) {
              if (!_enabled || next.isEmpty || next.first == current) return;
              _commit(next.first);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final String? picked = await Navigator.of(context).push<String>(
      adaptivePageRoute<String>(
        context: context,
        builder: (BuildContext context) => _ChoicePickerPage(row: row),
      ),
    );
    if (picked != null && picked != row.choiceValue && mounted) {
      _commit(picked);
    }
  }

  ({double min, double max}) get _range {
    final double value = row.doubleValue ?? 0;
    final double min = row.min ?? 0;
    double max = row.max ?? (value > 1 ? value : 1);
    if (max <= min) max = min + 1;
    return (min: min, max: max);
  }

  Widget _slider(BuildContext context) {
    final ({double min, double max}) range = _range;
    final double value = (_drag ?? row.doubleValue ?? range.min).clamp(
      range.min,
      range.max,
    );
    final String readout = _drag == null
        ? row.display
        : companionSettingNumber(value, integer: row.integer);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _title(context, trailing: readout),
          SizedBox(
            height: 48,
            child: adaptiveSlider(
              context: context,
              value: value,
              min: range.min,
              max: range.max,
              divisions: row.divisions,
              label: readout,
              onChanged: _enabled
                  ? (double next) => setState(() => _drag = next)
                  : null,
              onChangeEnd: _enabled
                  ? (double end) {
                      if (end == row.doubleValue) {
                        setState(() => _drag = null);
                        return;
                      }
                      setState(() => _drag = end);
                      _commit(end);
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepper(BuildContext context) {
    final ({double min, double max}) range = (
      min: row.min ?? double.negativeInfinity,
      max: row.max ?? double.infinity,
    );
    final double step = row.step ?? 1;
    final double value = row.doubleValue ?? 0;
    final bool canDown = _enabled && value - step >= range.min - 1e-9;
    final bool canUp = _enabled && value + step <= range.max + 1e-9;
    void nudge(double delta) =>
        _commit((value + delta).clamp(range.min, range.max));
    return _line(
      context,
      _title(context),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIconButton(
            key: ValueKey<String>('companion-setting-${row.key}-down'),
            icon: FushiIcons.remove,
            tooltip: t.decrease,
            enabled: canDown,
            onTap: canDown ? () => nudge(-step) : null,
            padTouchTarget: true,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44),
            child: Text(
              row.display,
              textAlign: TextAlign.center,
              maxLines: 1,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          FushiIconButton(
            key: ValueKey<String>('companion-setting-${row.key}-up'),
            icon: FushiIcons.add,
            tooltip: t.increase,
            enabled: canUp,
            onTap: canUp ? () => nudge(step) : null,
            padTouchTarget: true,
          ),
        ],
      ),
    );
  }

  Widget _number(BuildContext context) => _line(
    context,
    _title(context),
    SizedBox(
      width: 112,
      child: _NumberField(
        key: ValueKey<String>('companion-setting-${row.key}-field'),
        row: row,
        onSubmitted: _enabled ? _commit : null,
      ),
    ),
  );

  Widget _open(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? sub = row.display.isNotEmpty ? row.display : row.subtitle;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  row.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
                if (sub != null)
                  Text(
                    sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            flex: 2,
            child: _OpenOnMainButton(
              key: ValueKey<String>('companion-setting-${row.key}-open'),
              onPressed: _enabled
                  ? () => unawaited(
                      _openOnMain(context, widget.session, key: row.key),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A choice with many / long options: the current label, opening a picker.
class _ChoiceLine extends StatelessWidget {
  const _ChoiceLine({required this.row, required this.onTap});

  final CompanionSettingRow row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiPressScale(
      enabled: onTap != null,
      child: Semantics(
        button: true,
        label: row.title,
        value: row.display,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey<String>('companion-setting-${row.key}-pick'),
          onTap: onTap,
          borderRadius: FushiM3eShape.smallRadius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    row.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
                FushiIcon(
                  FushiIcons.chevronRight,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Every option of a long choice; pops with the picked token.
class _ChoicePickerPage extends StatelessWidget {
  const _ChoicePickerPage({required this.row});

  final CompanionSettingRow row;

  @override
  Widget build(BuildContext context) {
    final List<CompanionSettingOption> options = row.options;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _PageHeader(title: row.title),
            Expanded(
              child: FushiEntranceScope(
                child: ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    4,
                    16,
                    16 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount: options.length,
                  separatorBuilder: (BuildContext context, int _) =>
                      const SizedBox(height: 6),
                  itemBuilder: fushiStaggeredItemBuilder(
                    (BuildContext context, int index) => CompanionLineTile(
                      key: ValueKey<String>(
                        'companion-setting-option-${options[index].value}',
                      ),
                      text: options[index].label,
                      selected: options[index].value == row.choiceValue,
                      onTap: () =>
                          Navigator.of(context).pop(options[index].value),
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
}

/// A number typed in place; written on submit (clamped to the row's range).
class _NumberField extends StatefulWidget {
  const _NumberField({required this.row, required this.onSubmitted, super.key});

  final CompanionSettingRow row;
  final ValueChanged<num>? onSubmitted;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _text = TextEditingController(
    text: _shown(widget.row),
  );

  static String _shown(CompanionSettingRow row) {
    final double? v = row.doubleValue;
    return v == null ? '' : companionSettingNumber(v, integer: row.integer);
  }

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.row.value != widget.row.value) {
      _text.text = _shown(widget.row);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final ValueChanged<num>? submit = widget.onSubmitted;
    final double? parsed = double.tryParse(raw.trim());
    if (submit == null || parsed == null) {
      _text.text = _shown(widget.row);
      return;
    }
    final double clamped = parsed.clamp(
      widget.row.min ?? double.negativeInfinity,
      widget.row.max ?? double.infinity,
    );
    final num value = widget.row.integer ? clamped.round() : clamped;
    _text.text = companionSettingNumber(
      value.toDouble(),
      integer: widget.row.integer,
    );
    if (value.toDouble() != widget.row.doubleValue) submit(value);
  }

  @override
  Widget build(BuildContext context) => FushiTextField(
    controller: _text,
    enabled: widget.onSubmitted != null,
    keyboardType: TextInputType.numberWithOptions(
      decimal: !widget.row.integer,
      signed: (widget.row.min ?? -1) < 0,
    ),
    textInputAction: TextInputAction.done,
    onSubmitted: _submit,
  );
}

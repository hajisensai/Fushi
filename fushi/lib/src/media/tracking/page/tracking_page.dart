/// The Tracking page: what needs the user (items to link, failed sends,
/// sites to sign in to again) and every link on every site, with a kind
/// filter and a title search. Opened from the Home Tracking strip and from
/// Settings › Media tracking. Sites, plugins, sign-in and defaults stay on
/// the settings page.
///
/// Reads one [MediaTrackingHomeSnapshot] (local database and preferences,
/// no network) and reloads when the service's status changes. The lists are
/// lazy builders over plain values, so thousands of rows stay smooth.
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/page/tracking_filter_bar.dart';
import 'package:fushi/src/media/tracking/page/tracking_link_dialog.dart';
import 'package:fushi/src/media/tracking/page/tracking_local_targets.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_data.dart';
import 'package:fushi/src/media/tracking/page/tracking_page_rows.dart';
import 'package:fushi/src/media/tracking/page/tracking_row_facts.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiSnackBar;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        FushiDatabase,
        MediaTrackingActivityRow,
        MediaTrackingIgnoredRow,
        MediaTrackingMappingRow;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens the Tracking page. [onOpenSettings] leads to Settings › Media
/// tracking (sites, sign-in). Without [initialTab] the page opens on "Needs
/// attention" when something needs the user, else on "Linked".
Future<void> openTrackingPage(
  BuildContext context, {
  required MediaTrackingService service,
  required FushiDatabase database,
  required VoidCallback onOpenSettings,
  TrackingPageTab? initialTab,
}) => Navigator.of(context).push(
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => TrackingPage(
      service: service,
      database: database,
      onOpenSettings: onOpenSettings,
      initialTab: initialTab,
    ),
  ),
);

class TrackingPage extends StatefulWidget {
  const TrackingPage({
    required this.service,
    required this.database,
    required this.onOpenSettings,
    this.initialTab,
    super.key,
  });

  final MediaTrackingService service;
  final FushiDatabase database;
  final VoidCallback onOpenSettings;
  final TrackingPageTab? initialTab;

  @override
  State<TrackingPage> createState() => _TrackingPageState();
}

class _TrackingPageState extends State<TrackingPage> {
  TrackingPageData? _data;
  TrackingPageTab? _tab;
  Set<TrackingRowKind> _kinds = const <TrackingRowKind>{};

  /// Link groups the user opened (collapsed by default), by group key.
  final Set<String> _expandedGroups = <String>{};
  String _query = '';
  bool _syncing = false;

  /// One reload at a time; a change meanwhile asks for one more.
  bool _loading = false;
  bool _reloadAgain = false;

  /// The Undo bar of the last hand link while it is up (closed when the
  /// page goes away, which lets its held update go).
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _linkSnack;
  ScaffoldMessengerState? _linkSnackMessenger;

  /// The app going to the background sends held hand links at once.
  late final AppLifecycleListener _lifecycle;

  MediaTrackingService get _service => widget.service;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _service.statusRevision.addListener(_onStatusChanged);
    _lifecycle = AppLifecycleListener(
      onPause: _releaseHeldLinks,
      onDetach: _releaseHeldLinks,
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    _service.statusRevision.removeListener(_onStatusChanged);
    _lifecycle.dispose();
    // Leaving the page: a hand link still in its Undo window is sent now
    // (T2 G2), and its Undo bar goes with the page. Closed after this frame:
    // the messenger is an ancestor and must not rebuild during unmount.
    final ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? snack =
        _linkSnack;
    final ScaffoldMessengerState? messenger = _linkSnackMessenger;
    _linkSnack = null;
    if (snack != null && messenger != null) {
      // Not when the whole app (messenger included) is going away.
      scheduleMicrotask(() {
        if (messenger.mounted) snack.close();
      });
    }
    _releaseHeldLinks();
    super.dispose();
  }

  void _releaseHeldLinks() =>
      unawaited(_service.releaseAllLinkHolds().catchError((Object _) {}));

  void _onStatusChanged() => unawaited(_reload());

  Future<void> _reload() async {
    if (_loading) {
      _reloadAgain = true;
      return;
    }
    _loading = true;
    try {
      do {
        _reloadAgain = false;
        final MediaTrackingHomeSnapshot snapshot = await _service
            .loadHomeSnapshot();
        final List<MediaTrackingIgnoredRow> ignored = await _service
            .listIgnored();
        final TrackingIgnoreIndex ignoreIndex = await _service
            .loadIgnoreIndex();
        final TrackingSeriesIndex seriesIndex = await _service
            .loadSeriesIndex();
        final List<MediaTrackingActivityRow> activity = await _service
            .loadActivity();
        final TrackingRowFacts facts = await loadTrackingRowFacts(
          widget.database,
        );
        if (!mounted) return;
        final TrackingPageData data = TrackingPageData.of(
          snapshot,
          ignored: ignored,
          ignoreIndex: ignoreIndex,
          seriesIndex: seriesIndex,
          activity: activity,
          facts: facts,
        );
        setState(() {
          _data = data;
          _tab ??= data.attention.isNotEmpty
              ? TrackingPageTab.attention
              : TrackingPageTab.linked;
        });
      } while (_reloadAgain && mounted);
    } finally {
      _loading = false;
    }
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    _showSnack(ScaffoldMessenger.of(context), message, action: action);
  }

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> _showSnack(
    ScaffoldMessengerState messenger,
    String message, {
    SnackBarAction? action,
    Duration duration = const Duration(milliseconds: 4000),
  }) {
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(
      FushiSnackBar(
        content: Text(message),
        action: action,
        persist: false,
        duration: duration,
      ),
    );
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final MediaTrackingSyncResult result = await _service.syncNow(
        force: true,
      );
      _snack(
        result.isSuccess
            ? t.media_tracking_sync_success
            : t.media_tracking_sync_failed,
      );
    } catch (_) {
      _snack(t.media_tracking_sync_failed);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _reload();
  }

  Future<void> _link(
    MediaTrackingLocalTarget item, {
    MediaTrackingMappingRow? existing,
  }) async {
    // A PDF may be linked as a novel or a manga: the dialog offers both.
    final List<TrackingKind> kinds = await trackingKindChoicesFor(
      widget.database,
      item.type,
      item.key,
    );
    if (!mounted) return;
    final TrackingLinkOutcome? outcome = await showTrackingLinkDialog(
      context,
      service: _service,
      database: widget.database,
      item: kinds.length > 1
          ? MediaTrackingLocalTarget(
              type: item.type,
              key: item.key,
              title: item.title,
              kind: kinds.contains(item.kind) ? item.kind : kinds.first,
              kinds: kinds,
              initialOffset: item.initialOffset,
            )
          : item,
      existing: existing,
      onOpenSettings: widget.onOpenSettings,
    );
    if (outcome == null) return;
    _linkedSnack(outcome);
    await _reload();
  }

  /// "Linked to <entry> on <site>" with Undo for [kTrackingLinkUndoVisible]
  /// (T1 F16, T2 G2/G3). Nothing is sent while it is up: when it closes
  /// any other way than Undo, the link's held update goes out. Undo puts
  /// the site's links back as they were before (no link, or the previous
  /// one).
  void _linkedSnack(TrackingLinkOutcome outcome) {
    if (!mounted) {
      unawaited(_service.releaseLinkHold(outcome.undo));
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> snack =
        _showSnack(
          messenger,
          outcome.held
              ? t.media_tracking_link_linked_held(
                  entry: outcome.entryName,
                  site: outcome.siteName,
                )
              : t.media_tracking_link_linked_to(
                  entry: outcome.entryName,
                  site: outcome.siteName,
                ),
          duration: kTrackingLinkUndoVisible,
          action: SnackBarAction(
            label: t.undo,
            onPressed: () =>
                unawaited(_undoLink(messenger, outcome.undo, outcome.siteName)),
          ),
        );
    _linkSnack = snack;
    _linkSnackMessenger = messenger;
    unawaited(
      snack.closed.then((SnackBarClosedReason reason) async {
        if (identical(_linkSnack, snack)) _linkSnack = null;
        if (reason == SnackBarClosedReason.action) return;
        await _service.releaseLinkHold(outcome.undo);
      }),
    );
  }

  /// Told on [messenger] (taken when the link was made), so the result
  /// shows even after the page closed (T2 G3); the text says truthfully
  /// whether anything had reached the site.
  Future<void> _undoLink(
    ScaffoldMessengerState messenger,
    TrackingLinkUndo undo,
    String site,
  ) async {
    final bool alreadySent = await _service.undoLink(undo);
    if (messenger.mounted) {
      _showSnack(
        messenger,
        alreadySent
            ? t.media_tracking_link_undone_already_sent(site: site)
            : t.media_tracking_link_undone_nothing_sent(site: site),
      );
    }
    if (mounted) await _reload();
  }

  /// Links any local item by hand, with or without progress: the dialog
  /// lists the library.
  Future<void> _linkAnyItem() async {
    final TrackingLinkOutcome? outcome = await showTrackingLinkDialog(
      context,
      service: _service,
      database: widget.database,
      onOpenSettings: widget.onOpenSettings,
    );
    if (outcome == null) return;
    _linkedSnack(outcome);
    await _reload();
  }

  Future<void> _linkUnlinked(MediaTrackingUnlinkedItem item) => _link(
    MediaTrackingLocalTarget(
      type: item.mediaType,
      key: item.mediaKey,
      title: item.mediaTitle,
      kind: item.kind,
      initialOffset: item.episodeNumber,
    ),
  );

  Future<void> _changeLink(MediaTrackingMappingRow mapping) async {
    final TrackingMediaType? type = trackingMediaTypeOfValue(mapping.mediaType);
    if (type == null) return;
    await _link(
      MediaTrackingLocalTarget(
        type: type,
        key: mapping.mediaKey,
        title: mapping.mediaTitle,
        kind: trackingKindOfValue(mapping.kind),
      ),
      existing: mapping,
    );
  }

  /// [title]: how the page names the item (the raw local name the grouped
  /// row shows, else the cleaned title); the confirmation names it
  /// (T2 G8, T3 H3).
  Future<void> _removeLink(
    MediaTrackingMappingRow mapping, {
    String? title,
  }) async {
    final String site = _data?.siteName(mapping.provider) ?? mapping.provider;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.media_tracking_page_remove_link,
      message: t.media_tracking_page_remove_confirm_item(
        title: title ?? mapping.mediaTitle,
        site: site,
      ),
      cancelLabel: t.cancel,
      confirmLabel: t.media_tracking_page_remove_link,
      icon: FushiIcons.linkOff,
      destructive: true,
    );
    if (!confirmed) return;
    await _service.removeLink(mapping);
    await _reload();
  }

  /// Puts an item on the do-not-track list (a collection or season key
  /// covers its members).
  Future<void> _ignore({
    required TrackingMediaType type,
    required String key,
    required String title,
    TrackingKind? kind,
  }) async {
    await _service.ignoreItem(
      mediaType: type,
      mediaKey: key,
      mediaTitle: title,
      kind: kind,
    );
    _snack(
      t.media_tracking_ignore_done(title: title),
      action: SnackBarAction(
        label: t.media_tracking_ignore_undo,
        onPressed: () => unawaited(_trackAgain(type.value, key, title)),
      ),
    );
    await _reload();
  }

  Future<void> _ignoreEntry(TrackingAttentionEntry entry) async {
    final MediaTrackingUnlinkedItem? item = entry.item;
    if (item != null) {
      return _ignore(
        type: item.mediaType,
        key: item.mediaKey,
        title: item.mediaTitle,
        kind: item.kind,
      );
    }
    final MediaTrackingMappingRow? mapping = entry.mapping;
    if (mapping != null) return _ignoreMapping(mapping);
  }

  Future<void> _ignoreMapping(MediaTrackingMappingRow mapping) async {
    final TrackingMediaType? type = trackingMediaTypeOfValue(mapping.mediaType);
    if (type == null) return;
    await _ignore(
      type: type,
      key: mapping.mediaKey,
      title: mapping.mediaTitle,
      kind: trackingKindOfValue(mapping.kind),
    );
  }

  /// "Don't track the series" from a member's row.
  Future<void> _ignoreSeries(TrackingSeriesRef series, TrackingKind? kind) =>
      _ignore(
        type: series.type,
        key: series.key,
        title: series.title,
        kind: kind,
      );

  Future<void> _trackAgain(String type, String key, String title) async {
    await _service.trackAgain(mediaType: type, mediaKey: key);
    _snack(t.media_tracking_ignore_undone(title: title));
    await _reload();
  }

  void _openOnSite(MediaTrackingMappingRow mapping, Uri url) =>
      unawaited(launchUrl(url, mode: LaunchMode.externalApplication));

  @override
  Widget build(BuildContext context) {
    return SettingsKitScaffold(
      title: t.media_tracking_page_title,
      leadingIcon: FushiIcons.tracking,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => _body(context, controller),
    );
  }

  Widget _body(BuildContext context, ScrollController controller) {
    final double top = MediaQuery.paddingOf(context).top;
    final EdgeInsets padding = EdgeInsets.fromLTRB(12, top + 8, 12, 24);
    final TrackingPageData? data = _data;
    final TrackingPageTab? tab = _tab;
    // The module was turned off while the page is open (T2 G15): nothing
    // is listed or offered (nothing is sent while it is off either).
    if (!_service.isOn) {
      return _list(controller, padding, const <Widget>[], <Widget>[
        SettingsEmptyState(
          key: const ValueKey<String>('tracking-page-off'),
          icon: FushiIcons.tracking,
          title: t.media_tracking_page_off_title,
          message: t.media_tracking_page_off_message,
        ),
      ]);
    }
    if (data == null || tab == null) {
      return ListView(
        controller: controller,
        padding: padding,
        children: const <Widget>[
          Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: FushiCircularProgressIndicator(),
            ),
          ),
        ],
      );
    }
    final List<Widget> header = <Widget>[
      TrackingStatusHeader(
        data: data,
        syncing: _syncing,
        onSyncNow: () => unawaited(_syncNow()),
        onOpenSettings: widget.onOpenSettings,
        onLinkItem: () => unawaited(_linkAnyItem()),
      ),
    ];
    if (!data.hasConnectedSite) {
      header.add(
        SettingsEmptyState(
          key: const ValueKey<String>('tracking-page-no-site'),
          icon: FushiIcons.tracking,
          title: t.media_tracking_page_empty_sites_title,
          message: t.media_tracking_page_empty_sites_message,
          action: FushiPressScale(
            child: FushiFilledButton.tonalIcon(
              onPressed: widget.onOpenSettings,
              icon: const FushiIcon(FushiIcons.settings),
              label: Text(t.settings),
            ),
          ),
        ),
      );
      return _list(controller, padding, header, const <Widget>[]);
    }
    // Kinds no longer present are dropped from the filter.
    final List<TrackingRowKind> kinds = data.kindsIn(tab);
    final Set<TrackingRowKind> selectedKinds = _kinds.intersection(
      kinds.toSet(),
    );
    final TrackingPageFilter filter = TrackingPageFilter(
      kinds: selectedKinds,
      query: _query,
    );
    header.add(
      TrackingFilterBar(
        key: const ValueKey<String>('tracking-page-filter-bar'),
        tab: tab,
        attentionCount: data.attention.length,
        linkedCount: data.linked.length,
        ignoredCount: data.ignored.length,
        onTabChanged: (TrackingPageTab value) => setState(() => _tab = value),
        kinds: kinds,
        selectedKinds: selectedKinds,
        onKindsChanged: (Set<TrackingRowKind> value) =>
            setState(() => _kinds = value),
        query: _query,
        onQueryChanged: (String value) => setState(() => _query = value),
      ),
    );
    return switch (tab) {
      TrackingPageTab.attention => _attentionList(
        controller,
        padding,
        header,
        data,
        data.attentionFiltered(filter),
        filtered: !filter.isEmpty,
      ),
      TrackingPageTab.linked => _linkedList(
        controller,
        padding,
        header,
        data,
        data.linkGroupsFiltered(filter),
        filtered: !filter.isEmpty,
      ),
      TrackingPageTab.ignored => _ignoredList(
        controller,
        padding,
        header,
        data,
        data.ignoredFiltered(filter),
        filtered: !filter.isEmpty,
      ),
      TrackingPageTab.activity => _activityList(
        controller,
        padding,
        header,
        data,
        data.activityFiltered(data.activity, filter),
        filtered: !filter.isEmpty,
      ),
    };
  }

  Widget _attentionList(
    ScrollController controller,
    EdgeInsets padding,
    List<Widget> header,
    TrackingPageData data,
    List<TrackingAttentionEntry> rows, {
    required bool filtered,
  }) {
    if (rows.isEmpty) {
      return _list(controller, padding, header, <Widget>[
        filtered
            ? _filterEmpty()
            : SettingsEmptyState(
                key: const ValueKey<String>('tracking-page-attention-empty'),
                icon: FushiIcons.check,
                title: t.media_tracking_page_empty_attention_title,
                message: t.media_tracking_page_empty_attention_message,
              ),
      ]);
    }
    return _lazyList(
      controller,
      padding,
      header,
      rows.length,
      (int i) => TrackingAttentionRow(
        key: ValueKey<String>('tracking-attention-$i-${rows[i].reason.name}'),
        entry: rows[i],
        index: i,
        count: rows.length,
        siteName: rows[i].siteId == null
            ? null
            : data.siteName(rows[i].siteId!),
        busy: _syncing,
        onTap: () => _onAttentionTap(rows[i]),
        onRetry: () => unawaited(_syncNow()),
        onIgnore: rows[i].reason == TrackingAttentionReason.signIn
            ? null
            : () => unawaited(_ignoreEntry(rows[i])),
        onIgnoreSeries: switch (data.seriesOfEntry(rows[i])) {
          final TrackingSeriesRef series => () => unawaited(
            _ignoreSeries(series, rows[i].kind),
          ),
          null => null,
        },
      ),
    );
  }

  Widget _activityList(
    ScrollController controller,
    EdgeInsets padding,
    List<Widget> header,
    TrackingPageData data,
    List<MediaTrackingActivityRow> rows, {
    required bool filtered,
  }) {
    if (rows.isEmpty) {
      return _list(controller, padding, header, <Widget>[
        filtered
            ? _filterEmpty()
            : SettingsEmptyState(
                key: const ValueKey<String>('tracking-page-activity-empty'),
                icon: FushiIcons.history,
                title: t.media_tracking_page_empty_activity_title,
                message: t.media_tracking_page_empty_activity_message,
              ),
      ]);
    }
    return _lazyList(controller, padding, header, rows.length, (int i) {
      final MediaTrackingActivityRow row = rows[i];
      return TrackingActivityRow(
        key: ValueKey<String>('tracking-activity-${row.id}'),
        row: row,
        names: data.activityNames(row),
        index: i,
        count: rows.length,
        siteName: data.siteName(row.provider),
      );
    });
  }

  Widget _ignoredList(
    ScrollController controller,
    EdgeInsets padding,
    List<Widget> header,
    TrackingPageData data,
    List<MediaTrackingIgnoredRow> rows, {
    required bool filtered,
  }) {
    if (rows.isEmpty) {
      return _list(controller, padding, header, <Widget>[
        filtered
            ? _filterEmpty()
            : SettingsEmptyState(
                key: const ValueKey<String>('tracking-page-ignored-empty'),
                icon: FushiIcons.block,
                title: t.media_tracking_page_empty_ignored_title,
                message: t.media_tracking_page_empty_ignored_message,
              ),
      ]);
    }
    return _lazyList(controller, padding, header, rows.length, (int i) {
      final MediaTrackingIgnoredRow row = rows[i];
      return TrackingIgnoredRow(
        key: ValueKey<String>('tracking-ignored-${row.id}'),
        row: row,
        names: data.ignoredNames(row),
        index: i,
        count: rows.length,
        onTrackAgain: () =>
            unawaited(_trackAgain(row.mediaType, row.mediaKey, row.mediaTitle)),
      );
    });
  }

  void _onAttentionTap(TrackingAttentionEntry entry) {
    switch (entry.reason) {
      case TrackingAttentionReason.signIn:
        widget.onOpenSettings();
      case TrackingAttentionReason.failed:
        if (entry.mapping case final MediaTrackingMappingRow mapping) {
          unawaited(_changeLink(mapping));
        }
      case TrackingAttentionReason.unlinked:
        if (entry.item case final MediaTrackingUnlinkedItem item) {
          unawaited(_linkUnlinked(item));
        }
      case TrackingAttentionReason.inert:
      case TrackingAttentionReason.inertMediaServer:
        if (entry.mapping case final MediaTrackingMappingRow mapping) {
          unawaited(_removeLink(mapping, title: entry.rawName ?? entry.title));
        }
    }
  }

  Widget _linkedList(
    ScrollController controller,
    EdgeInsets padding,
    List<Widget> header,
    TrackingPageData data,
    List<TrackingLinkGroup> groups, {
    required bool filtered,
  }) {
    if (groups.isEmpty) {
      return _list(controller, padding, header, <Widget>[
        filtered
            ? _filterEmpty()
            : SettingsEmptyState(
                key: const ValueKey<String>('tracking-page-linked-empty'),
                icon: FushiIcons.link,
                title: t.media_tracking_page_empty_linked_title,
                message: t.media_tracking_page_empty_linked_message,
              ),
      ]);
    }
    // One line per group, plus its links when it is open (a few small
    // records per build; the groups themselves come from the data layer).
    final List<({TrackingLinkGroup group, TrackingLinkedEntry? member})> lines =
        <({TrackingLinkGroup group, TrackingLinkedEntry? member})>[
          for (final TrackingLinkGroup group in groups)
            if (group.isSingle)
              (group: group, member: group.members.single)
            else ...<({TrackingLinkGroup group, TrackingLinkedEntry? member})>[
              (group: group, member: null),
              if (_expandedGroups.contains(group.key))
                for (final TrackingLinkedEntry member in group.members)
                  (group: group, member: member),
            ],
        ];
    return _lazyList(controller, padding, header, lines.length, (int i) {
      final TrackingLinkGroup group = lines[i].group;
      final TrackingLinkedEntry? member = lines[i].member;
      if (member == null) {
        final MediaTrackingMappingRow first = group.members.first.mapping;
        final TrackingKind? kind = trackingKindOfValue(first.kind);
        final Uri? url = kind == null
            ? null
            : _service.subjectPageUrl(group.siteId, group.subjectId, kind);
        final bool expanded = _expandedGroups.contains(group.key);
        return TrackingLinkGroupRow(
          key: ValueKey<String>('tracking-linked-group-${group.key}'),
          group: group,
          index: i,
          count: lines.length,
          siteName: data.siteName(group.siteId),
          expanded: expanded,
          failed: group.members.any(
            (TrackingLinkedEntry e) =>
                data.failedMappingIds.contains(e.mapping.id),
          ),
          onToggle: () => setState(() {
            if (!_expandedGroups.remove(group.key)) {
              _expandedGroups.add(group.key);
            }
          }),
          onOpen: url == null ? null : () => _openOnSite(first, url),
        );
      }
      final Widget row = _linkedRow(
        data,
        member,
        index: i,
        count: lines.length,
        inGroup: !group.isSingle,
      );
      return group.isSingle ? row : TrackingGroupMember(child: row);
    });
  }

  Widget _linkedRow(
    TrackingPageData data,
    TrackingLinkedEntry entry, {
    required int index,
    required int count,
    required bool inGroup,
  }) {
    final MediaTrackingMappingRow mapping = entry.mapping;
    final TrackingKind? kind = trackingKindOfValue(mapping.kind);
    final Uri? url = kind == null
        ? null
        : _service.subjectPageUrl(mapping.provider, mapping.subjectId, kind);
    return TrackingLinkedRow(
      key: ValueKey<String>('tracking-linked-${mapping.id}'),
      entry: entry,
      index: index,
      count: count,
      inGroup: inGroup,
      siteName: data.siteName(mapping.provider),
      failed: data.failedMappingIds.contains(mapping.id),
      onTap: () => unawaited(_changeLink(mapping)),
      onOpen: url == null ? null : () => _openOnSite(mapping, url),
      onRemove: () =>
          unawaited(_removeLink(mapping, title: entry.rawName ?? entry.title)),
      paused: data.isPaused(mapping),
      onIgnore: data.isPaused(mapping)
          ? null
          : () => unawaited(_ignoreMapping(mapping)),
      onIgnoreSeries: switch (data.isPaused(mapping)
          ? null
          : data.seriesOf(mapping.mediaType, mapping.mediaKey)) {
        final TrackingSeriesRef series => () => unawaited(
          _ignoreSeries(series, kind),
        ),
        null => null,
      },
      onTrackAgain: data.isIgnoredDirectly(mapping)
          ? () => unawaited(
              _trackAgain(
                mapping.mediaType,
                mapping.mediaKey,
                mapping.mediaTitle,
              ),
            )
          : null,
    );
  }

  Widget _filterEmpty() => SettingsEmptyState(
    key: const ValueKey<String>('tracking-page-filter-empty'),
    icon: FushiIcons.search,
    title: t.media_tracking_page_empty_filter,
  );

  /// Header widgets, then [rows] (a few, already built). The same list as
  /// [_lazyList]: switching between rows and an empty state keeps the list,
  /// so the search box keeps its focus and nothing replays (T2 G1).
  Widget _list(
    ScrollController controller,
    EdgeInsets padding,
    List<Widget> header,
    List<Widget> rows,
  ) => _lazyList(
    controller,
    padding,
    header,
    rows.length,
    (int index) => rows[index],
  );

  /// Header widgets, then [count] rows built on demand.
  Widget _lazyList(
    ScrollController controller,
    EdgeInsets padding,
    List<Widget> header,
    int count,
    Widget Function(int index) row,
  ) => FushiEntranceScope(
    child: ListView.builder(
      key: const ValueKey<String>('tracking-page-list'),
      controller: controller,
      padding: padding,
      itemCount: header.length + count,
      itemBuilder: fushiStaggeredItemBuilder(
        (BuildContext context, int index) =>
            index < header.length ? header[index] : row(index - header.length),
      ),
    ),
  );
}

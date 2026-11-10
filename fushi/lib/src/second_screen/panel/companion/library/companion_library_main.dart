import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_labels.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_page_route.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_details_page.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// The library page on top's Main-mode snapshot; null while the top is not a
/// library or the page has not published one yet.
CompanionLibraryMainSnapshot? companionLibraryMainSnapshotOf(
  CompanionPanelSession session,
) {
  if (session.context.kind != CompanionContextKind.library) return null;
  final Map<String, Object?>? data = session.snapshot;
  return data == null ? null : CompanionLibraryMainSnapshot.fromJson(data);
}

/// Library tab, Main mode root: the library on the main screen. Shows the
/// item highlighted there (controller focus / long-press / selection) with
/// Continue and Details, and drives the top list's own search, sort and
/// filters ([CompanionLibraryMainActions] commands to the page on top).
class CompanionLibraryMainRoot extends ConsumerStatefulWidget {
  const CompanionLibraryMainRoot({super.key});

  @override
  ConsumerState<CompanionLibraryMainRoot> createState() =>
      _CompanionLibraryMainRootState();
}

class _CompanionLibraryMainRootState
    extends ConsumerState<CompanionLibraryMainRoot> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'companion-main-search');

  /// The query the page on top has (or is about to have, once the command in
  /// flight lands).
  String _sent = '';

  /// A search command is on its way; [_pending] is sent when it lands.
  bool _sending = false;
  String? _pending;

  @override
  void initState() {
    super.initState();
    final CompanionLibraryMainSnapshot? snap = companionLibraryMainSnapshotOf(
      ref.read(companionPanelSessionProvider),
    );
    if (snap != null) {
      _sent = snap.query;
      _query.text = snap.query;
    }
    _queryFocus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _queryFocus.removeListener(_onFocusChanged);
    _queryFocus.dispose();
    _query.dispose();
    super.dispose();
  }

  CompanionPanelSession get _session => ref.read(companionPanelSessionProvider);

  /// Takes the top's query into the field unless the user is typing here
  /// (the field has focus or a search is still on its way).
  void _syncQuery(CompanionLibraryMainSnapshot? snap) {
    if (snap == null || _sending || _queryFocus.hasFocus) return;
    _sent = snap.query;
    if (_query.text != snap.query) _query.text = snap.query;
  }

  void _onFocusChanged() {
    if (!_queryFocus.hasFocus) {
      _syncQuery(companionLibraryMainSnapshotOf(_session));
    }
  }

  /// Sends [text] as the top page's search; while one search is on its way
  /// only the newest text waits (one pending command at a time).
  void _search(String text) {
    if (_sending) {
      _pending = text;
      return;
    }
    if (text == _sent) return;
    _sending = true;
    _sent = text;
    unawaited(
      _session
          .command(CompanionLibraryMainActions.search, <String, Object?>{
            CompanionLibraryMainActions.argQuery: text,
          })
          .whenComplete(() {
            _sending = false;
            final String? next = _pending;
            _pending = null;
            if (!mounted) return;
            if (next != null) _search(next);
          }),
    );
  }

  void _clear() {
    _query.clear();
    _search('');
  }

  void _sort(String id) => unawaited(
    _session.command(CompanionLibraryMainActions.sort, <String, Object?>{
      CompanionLibraryMainActions.argId: id,
    }),
  );

  void _filter(CompanionLibraryOption option) => unawaited(
    _session.command(CompanionLibraryMainActions.filter, <String, Object?>{
      CompanionLibraryMainActions.argId: option.id,
      CompanionLibraryMainActions.argSelected: !option.selected,
    }),
  );

  void _continue() =>
      unawaited(_session.command(CompanionLibraryMainActions.openHighlighted));

  void _details(CompanionLibraryItem item) => unawaited(
    pushCompanionPage<void>(
      context,
      (BuildContext context) =>
          CompanionLibraryDetailsPage(itemRef: item.ref, title: item.title),
    ),
  );

  @override
  Widget build(BuildContext context) {
    ref.listen<CompanionPanelSession>(
      companionPanelSessionProvider,
      (CompanionPanelSession? _, CompanionPanelSession next) =>
          _syncQuery(companionLibraryMainSnapshotOf(next)),
    );
    final CompanionPanelSession session = ref.watch(
      companionPanelSessionProvider,
    );
    final CompanionLibraryKind? shown = session.context.library;
    final CompanionLibraryMainSnapshot? snap = companionLibraryMainSnapshotOf(
      session,
    );
    final CompanionLibraryItem? highlighted = snap?.highlighted;
    int index = 0;
    final List<Widget> tools = <Widget>[
      if (shown != null)
        FushiStaggeredEntrance(
          index: index++,
          child: _Caption(
            t.second_screen_library_main_filtering(
              library: companionLibraryLabel(shown),
            ),
          ),
        ),
      if (snap != null && snap.searchable)
        FushiStaggeredEntrance(
          index: index++,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('companion-library-main-search'),
              controller: _query,
              focusNode: _queryFocus,
              hintText: t.second_screen_library_main_search_hint,
              onChanged: _search,
              onSubmitted: _search,
              onClear: _clear,
            ),
          ),
        ),
      if (snap != null && (snap.sorts.isNotEmpty || snap.filters.isNotEmpty))
        FushiStaggeredEntrance(
          index: index++,
          child: _SortFilterRow(
            snapshot: snap,
            onSort: _sort,
            onFilter: _filter,
          ),
        ),
    ];
    return FushiEntranceScope(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: <Widget>[
          ...tools,
          FushiStaggeredEntrance(
            index: index,
            child: highlighted == null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                    child: FushiPlaceholderMessage(
                      key: const ValueKey<String>(
                        'companion-library-main-hint',
                      ),
                      icon: FushiIcons.touch,
                      message: t.second_screen_library_main_hint,
                    ),
                  )
                : _HighlightedCard(
                    item: highlighted,
                    onContinue: _continue,
                    onDetails: () => _details(highlighted),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// "Sort: <label>" (a menu of the page's sort options) and the page's
/// filters as toggle chips, in one horizontally scrolling row.
class _SortFilterRow extends StatelessWidget {
  const _SortFilterRow({
    required this.snapshot,
    required this.onSort,
    required this.onFilter,
  });

  final CompanionLibraryMainSnapshot snapshot;
  final ValueChanged<String> onSort;
  final ValueChanged<CompanionLibraryOption> onFilter;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    CompanionLibraryOption? sort;
    for (final CompanionLibraryOption o in snapshot.sorts) {
      if (o.selected) sort = o;
    }
    final List<Widget> chips = <Widget>[
      if (snapshot.sorts.isNotEmpty)
        FushiPopupMenuButton<String>(
          key: const ValueKey<String>('companion-library-main-sort'),
          tooltip: t.sort_by,
          initialValue: sort?.id,
          onSelected: onSort,
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            for (final CompanionLibraryOption o in snapshot.sorts)
              CheckedPopupMenuItem<String>(
                key: ValueKey<String>('companion-library-main-sort-${o.id}'),
                value: o.id,
                checked: o.selected,
                child: Text(o.label),
              ),
          ],
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: FushiM3eShape.smallRadius,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiIcon(
                      FushiIcons.sort,
                      size: 18,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      sort == null
                          ? t.sort_by
                          : t.second_screen_library_main_sort(
                              label: sort.label,
                            ),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      for (final CompanionLibraryOption o in snapshot.filters)
        FushiFilterChip(
          key: ValueKey<String>('companion-library-main-filter-${o.id}'),
          label: Text(o.label),
          selected: o.selected,
          onSelected: (bool _) => onFilter(o),
        ),
    ];
    return SizedBox(
      height: 56,
      child: FocusTraversalGroup(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          itemCount: chips.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(width: 6),
          itemBuilder: (BuildContext context, int index) =>
              Center(child: chips[index]),
        ),
      ),
    );
  }
}

/// "Highlighted on top": cover, title, subtitle, progress line + bar,
/// Continue (opens it on top) and Details.
class _HighlightedCard extends StatelessWidget {
  const _HighlightedCard({
    required this.item,
    required this.onContinue,
    required this.onDetails,
  });

  final CompanionLibraryItem item;
  final VoidCallback onContinue;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final double? progress = item.finished
        ? null
        : item.progress?.clamp(0.0, 1.0);
    final String? progressLine = <String>[
      if (item.progressLabel case final String p when p.isNotEmpty) p,
      if (item.finished) t.second_screen_library_browse_finished,
      if (item.count != null)
        t.second_screen_library_browse_item_count(n: item.count!),
    ].join(' · ').nullIfEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FushiCard(
        key: ValueKey<String>('companion-library-main-highlighted-${item.ref}'),
        padding: const EdgeInsets.all(12),
        borderRadius: FushiM3eShape.cardRadius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.second_screen_library_main_highlighted,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CompanionLibraryCover(item: item, width: 64, height: 92),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (item.subtitle case final String s when s.isNotEmpty)
                        Text(
                          s,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      if (progressLine != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          progressLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (progress != null) ...<Widget>[
                        const SizedBox(height: 6),
                        FushiLinearProgressIndicator(value: progress),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FushiPressScale(
                    child: FushiFilledButton(
                      key: const ValueKey<String>(
                        'companion-library-main-continue',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: onContinue,
                      child: Text(t.second_screen_library_main_continue),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FushiPressScale(
                    child: FushiFilledButton.tonal(
                      key: const ValueKey<String>(
                        'companion-library-main-details',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: onDetails,
                      child: Text(t.second_screen_library_browse_details),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

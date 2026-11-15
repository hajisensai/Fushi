import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/second_screen/companion/companion_protocol.dart';
import 'package:fushi/src/second_screen/companion/modules/library_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_page_route.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_actions.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_details_page.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_feed.dart';
import 'package:fushi/src/second_screen/panel/companion/library/companion_library_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart'
    show HorizontalDragScrollable;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// The section a container's list belongs to (`library.list {section,
/// parent}`): servers for media-server items, music for artists /
/// playlists, the collection's own section, else [fallback].
CompanionLibrarySection companionLibrarySectionOf(
  CompanionLibraryItem item,
  CompanionLibrarySection fallback,
) {
  switch (item.kind) {
    case CompanionLibraryItemKind.server:
    case CompanionLibraryItemKind.serverLibrary:
    case CompanionLibraryItemKind.serverFolder:
    case CompanionLibraryItemKind.serverItem:
      return CompanionLibrarySection.servers;
    case CompanionLibraryItemKind.musicArtist:
    case CompanionLibraryItemKind.musicPlaylist:
    case CompanionLibraryItemKind.musicAlbum:
    case CompanionLibraryItemKind.musicTrack:
      return CompanionLibrarySection.music;
    case CompanionLibraryItemKind.collection:
      final String key = CompanionLibraryRef.keyOf(item.ref);
      final int slash = key.indexOf('/');
      if (slash > 0) {
        final String wire = key.substring(0, slash);
        for (final CompanionLibrarySection s
            in CompanionLibrarySection.values) {
          if (s.wire == wire) return s;
        }
      }
      return fallback;
    case CompanionLibraryItemKind.book:
    case CompanionLibraryItemKind.manga:
    case CompanionLibraryItemKind.video:
    case CompanionLibraryItemKind.audiobook:
    case CompanionLibraryItemKind.mainOnly:
      return fallback;
  }
}

/// Activating a Browse item: a container opens its list, a main-only entry
/// opens on the main screen, anything else its details page.
void companionLibraryShowItem(
  BuildContext context,
  WidgetRef ref,
  CompanionLibraryItem item, {
  required CompanionLibrarySection section,
}) {
  if (item.kind == CompanionLibraryItemKind.mainOnly) {
    unawaited(
      companionLibraryOpenOnMain(
        context,
        ref,
        item.mainTarget ?? CompanionLibraryMainTarget.libraryTab,
      ),
    );
    return;
  }
  final Widget page = item.kind.isContainer
      ? CompanionLibraryListPage(
          section: companionLibrarySectionOf(item, section),
          parent: item.ref,
          title: item.title,
        )
      : CompanionLibraryDetailsPage(itemRef: item.ref, title: item.title);
  unawaited(pushCompanionPage<void>(context, (BuildContext context) => page));
}

/// Library tab, Browse mode root: the companion's own library. A search
/// field ("Search everything" on Home, this list's filter inside a section),
/// the section chips, then Home's rows or the section's list.
class CompanionLibraryBrowseRoot extends ConsumerStatefulWidget {
  const CompanionLibraryBrowseRoot({super.key});

  @override
  ConsumerState<CompanionLibraryBrowseRoot> createState() =>
      _CompanionLibraryBrowseRootState();
}

class _CompanionLibraryBrowseRootState
    extends ConsumerState<CompanionLibraryBrowseRoot>
    with CompanionLibraryLive<CompanionLibraryBrowseRoot> {
  late final CompanionPanelSession _session;
  late final CompanionLibraryValueFeed<CompanionLibraryHome> _home;
  late final CompanionLibraryListFeed _search;
  final Map<CompanionLibrarySection, CompanionLibraryListFeed> _sections =
      <CompanionLibrarySection, CompanionLibraryListFeed>{};
  CompanionLibrarySection _section = CompanionLibrarySection.home;
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'companion-library');

  @override
  void initState() {
    super.initState();
    _session = ref.read(companionPanelSessionProvider);
    _home = CompanionLibraryValueFeed.home(_session);
    _search = CompanionLibraryListFeed.search(_session);
    _readSavedUi();
    startLive(_session);
  }

  /// Section and search from [CompanionPanelSession.uiState] (a relaunched
  /// panel puts the user back where the last one was).
  void _readSavedUi() {
    final CompanionPanelUiState ui = _session.uiState;
    _section = ui.librarySection == null
        ? CompanionLibrarySection.home
        : CompanionLibrarySection.fromWire(ui.librarySection);
    _query.text = ui.libraryQuery;
  }

  void _restoreUi() {
    setState(_readSavedUi);
    _syncShown();
  }

  void _reportUi() => _session.updateUi(
    (CompanionPanelUiState ui) => ui.copyWith(
      librarySection: () =>
          _section == CompanionLibrarySection.home ? null : _section.wire,
      libraryQuery: _text,
    ),
  );

  @override
  void dispose() {
    _home.dispose();
    _search.dispose();
    for (final CompanionLibraryListFeed feed in _sections.values) {
      feed.dispose();
    }
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  String get _text => _query.text.trim();

  CompanionLibraryListFeed _sectionFeed(CompanionLibrarySection section) =>
      _sections.putIfAbsent(section, () {
        final CompanionLibraryListFeed feed = CompanionLibraryListFeed.section(
          _session,
          section: section,
        );
        markStale(feed);
        return feed;
      });

  /// The list the page shows: the search on Home while a query is typed,
  /// the section's list elsewhere; null = Home's rows.
  CompanionLibraryListFeed? get _shownList {
    if (_section != CompanionLibrarySection.home) return _sectionFeed(_section);
    return _text.isEmpty ? null : _search;
  }

  @override
  List<CompanionLibraryFeedBase> get liveFeeds => <CompanionLibraryFeedBase>[
    _home,
    _search,
    ..._sections.values,
  ];

  @override
  CompanionLibraryFeedBase? get shownFeed => _shownList ?? _home;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShown();
  }

  /// Applies the typed query to the shown list (reloading it), or reloads
  /// the shown feed when it is stale.
  void _syncShown() {
    final CompanionLibraryListFeed? list = _shownList;
    final String text = _text;
    if (list != null && list.query != text && liveVisible) {
      takeStale(list);
      unawaited(list.setQuery(text));
      return;
    }
    syncLive();
  }

  void _onQueryChanged(String _) {
    setState(() {});
    _syncShown();
    _reportUi();
  }

  void _clearQuery() {
    _query.clear();
    _onQueryChanged('');
  }

  void _selectSection(CompanionLibrarySection section) {
    if (section == _section) return;
    setState(() => _section = section);
    _syncShown();
    _reportUi();
  }

  List<CompanionLibrarySection> _chips() {
    final List<CompanionLibrarySection> offered =
        _home.value?.sections ?? CompanionLibrarySection.values;
    return <CompanionLibrarySection>[
      CompanionLibrarySection.home,
      for (final CompanionLibrarySection s in offered)
        if (s != CompanionLibrarySection.home) s,
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(
      companionPanelSessionProvider.select(
        (CompanionPanelSession s) => s.uiRestores,
      ),
      (int? _, int _) => _restoreUi(),
    );
    final bool home = _section == CompanionLibrarySection.home;
    final CompanionLibraryListFeed? list = _shownList;
    final Widget body;
    if (list != null) {
      body = CompanionLibraryGrid(
        key: ValueKey<String>('companion-library-list-${_section.wire}'),
        feed: list,
        section: _section,
        filtered: _text.isNotEmpty,
      );
    } else {
      body = _HomeBody(
        key: const ValueKey<String>('companion-library-home'),
        feed: _home,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: FushiSearchField(
            fieldKey: const ValueKey<String>('companion-library-search'),
            controller: _query,
            focusNode: _queryFocus,
            hintText: home
                ? t.second_screen_library_browse_search_everything
                : t.second_screen_library_browse_search_list,
            onChanged: _onQueryChanged,
            onSubmitted: _onQueryChanged,
            onClear: _clearQuery,
          ),
        ),
        ListenableBuilder(
          listenable: _home,
          builder: (BuildContext context, Widget? _) => _SectionChips(
            sections: _chips(),
            selected: _section,
            onSelected: _selectSection,
          ),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            child: body,
          ),
        ),
      ],
    );
  }
}

/// Home, Books, Manga ... as a horizontally scrolling row of choice chips.
class _SectionChips extends StatelessWidget {
  const _SectionChips({
    required this.sections,
    required this.selected,
    required this.onSelected,
  });

  final List<CompanionLibrarySection> sections;
  final CompanionLibrarySection selected;
  final ValueChanged<CompanionLibrarySection> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: FocusTraversalGroup(
      child: HorizontalDragScrollable(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: sections.length,
          separatorBuilder: (BuildContext context, int index) =>
              const SizedBox(width: 6),
          itemBuilder: (BuildContext context, int index) {
            final CompanionLibrarySection s = sections[index];
            return Center(
              child: FushiChoiceChip(
                key: ValueKey<String>('companion-library-section-${s.wire}'),
                label: Text(companionLibrarySectionLabel(s)),
                selected: s == selected,
                showCheckmark: false,
                onSelected: (bool _) => onSelected(s),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// Browse's Home: the Continue / server continue / Recently added rows and
/// the "On the main screen" footer.
class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.feed, super.key});

  final CompanionLibraryValueFeed<CompanionLibraryHome> feed;

  static String _rowLabel(CompanionLibraryHomeRowKind kind) => switch (kind) {
    CompanionLibraryHomeRowKind.continueItems =>
      t.second_screen_library_browse_row_continue,
    CompanionLibraryHomeRowKind.continueServer =>
      t.second_screen_library_browse_row_continue_server,
    CompanionLibraryHomeRowKind.recentlyAdded =>
      t.second_screen_library_browse_row_recently_added,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListenableBuilder(
    listenable: feed,
    builder: (BuildContext context, Widget? _) {
      final CompanionLibraryHome? home = feed.value;
      final Widget body;
      if (home == null && feed.failed) {
        body = companionLibraryError(feed);
      } else if (home == null) {
        body = const CompanionLibrarySkeleton();
      } else {
        final List<CompanionLibraryHomeRow> rows = <CompanionLibraryHomeRow>[
          for (final CompanionLibraryHomeRow r in home.rows)
            if (r.items.isNotEmpty) r,
        ];
        final List<Widget> items = <Widget>[
          if (rows.isEmpty)
            Padding(
              key: const ValueKey<String>('companion-library-home-empty'),
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  t.second_screen_library_browse_empty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          for (final CompanionLibraryHomeRow row in rows)
            _HomeRow(label: _rowLabel(row.kind), row: row),
          const _OnMainFooter(),
        ];
        body = FushiEntranceScope(
          key: const ValueKey<String>('companion-library-home-list'),
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
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

/// One Home row: a caption and a horizontal strip of cover cards. Continue
/// rows open the item on top (the card) or its details (the info button).
class _HomeRow extends ConsumerWidget {
  const _HomeRow({required this.label, required this.row});

  final String label;
  final CompanionLibraryHomeRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool continues =
        row.kind != CompanionLibraryHomeRowKind.recentlyAdded;
    return Column(
      key: ValueKey<String>('companion-library-row-${row.kind.wire}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionLibraryCaption(label),
        SizedBox(
          height: kCompanionLibraryCardHeight,
          child: FocusTraversalGroup(
            child: HorizontalDragScrollable(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: row.items.length,
                separatorBuilder: (BuildContext context, int index) =>
                    const SizedBox(width: 10),
                itemBuilder: (BuildContext context, int index) {
                  final CompanionLibraryItem item = row.items[index];
                  final bool opens =
                      continues &&
                      !item.kind.isContainer &&
                      item.kind != CompanionLibraryItemKind.mainOnly;
                  void show() => companionLibraryShowItem(
                    context,
                    ref,
                    item,
                    section: CompanionLibrarySection.home,
                  );
                  return SizedBox(
                    width: kCompanionLibraryCardWidth,
                    child: CompanionLibraryCard(
                      item: item,
                      onTap: opens
                          ? () => unawaited(
                              companionLibraryOpen(
                                context,
                                ref,
                                itemRef: item.ref,
                              ),
                            )
                          : show,
                      onDetails: opens ? show : null,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "On the main screen": pages the companion does not show itself.
class _OnMainFooter extends ConsumerWidget {
  const _OnMainFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget button(
      String key,
      IconData icon,
      String label,
      CompanionLibraryMainTarget target,
    ) => Expanded(
      child: FushiPressScale(
        child: FushiOutlinedButton.icon(
          key: ValueKey<String>(key),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () =>
              unawaited(companionLibraryOpenOnMain(context, ref, target)),
          icon: FushiIcon(icon, size: 18),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionLibraryCaption(t.second_screen_library_browse_on_main_screen),
        Row(
          children: <Widget>[
            button(
              'companion-library-open-statistics',
              FushiIcons.statistics,
              t.second_screen_library_browse_statistics,
              CompanionLibraryMainTarget.statistics,
            ),
            const SizedBox(width: 8),
            button(
              'companion-library-open-dictionaries',
              FushiIcons.dictionary,
              t.second_screen_library_browse_dictionaries,
              CompanionLibraryMainTarget.dictionaries,
            ),
          ],
        ),
      ],
    );
  }
}

/// A paged list as a grid of cover cards, with loading / empty / error
/// states, the next page loaded near the end and a "Load more" button.
class CompanionLibraryGrid extends ConsumerWidget {
  const CompanionLibraryGrid({
    required this.feed,
    required this.section,
    required this.filtered,
    super.key,
  });

  final CompanionLibraryListFeed feed;
  final CompanionLibrarySection section;

  /// A query filters the list (empty = "Nothing matches").
  final bool filtered;

  /// Load the next page when less than this is left below the viewport.
  static const double _nearEnd = 320;

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis == Axis.vertical &&
        notification.metrics.extentAfter < _nearEnd &&
        feed.hasMore &&
        !feed.loadingMore) {
      unawaited(feed.loadMore());
    }
    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListenableBuilder(
    listenable: feed,
    builder: (BuildContext context, Widget? _) {
      final List<CompanionLibraryItem>? items = feed.items;
      final Widget body;
      if (items == null && feed.failed) {
        body = companionLibraryError(feed);
      } else if (items == null) {
        body = const CompanionLibrarySkeleton();
      } else if (items.isEmpty) {
        body = CompanionLibraryMessage(
          key: const ValueKey<String>('companion-library-empty'),
          icon: filtered ? FushiIcons.searchOff : FushiIcons.books,
          message: filtered
              ? t.second_screen_library_browse_no_match
              : t.second_screen_library_browse_list_empty,
        );
      } else {
        final bool more = feed.hasMore || feed.moreFailed;
        body = FushiEntranceScope(
          key: const ValueKey<String>('companion-library-grid'),
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 120,
                          mainAxisExtent: kCompanionLibraryCardHeight,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 12,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      fushiStaggeredItemBuilder(
                        (BuildContext context, int index) =>
                            CompanionLibraryCard(
                              item: items[index],
                              onTap: () => companionLibraryShowItem(
                                context,
                                ref,
                                items[index],
                                section: section,
                              ),
                            ),
                      ),
                      childCount: items.length,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    16 + MediaQuery.paddingOf(context).bottom,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: more
                        ? FushiPressScale(
                            enabled: !feed.loadingMore,
                            child: FushiOutlinedButton(
                              key: const ValueKey<String>(
                                'companion-library-load-more',
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                              onPressed: feed.loadingMore
                                  ? null
                                  : () => unawaited(feed.loadMore()),
                              child: Text(
                                feed.moreFailed
                                    ? t.retry
                                    : t.second_screen_library_browse_load_more,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
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

/// A container's items (a collection, an artist, a server, a server
/// library, a folder): `library.list {section, parent}`, filterable.
class CompanionLibraryListPage extends ConsumerStatefulWidget {
  const CompanionLibraryListPage({
    required this.section,
    required this.parent,
    required this.title,
    super.key,
  });

  final CompanionLibrarySection section;

  /// The container's [CompanionLibraryItem.ref].
  final String parent;

  /// Shown until the page's own title arrives.
  final String title;

  @override
  ConsumerState<CompanionLibraryListPage> createState() =>
      _CompanionLibraryListPageState();
}

class _CompanionLibraryListPageState
    extends ConsumerState<CompanionLibraryListPage>
    with CompanionLibraryLive<CompanionLibraryListPage> {
  late final CompanionLibraryListFeed _feed;
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'companion-library-list');

  @override
  void initState() {
    super.initState();
    final CompanionPanelSession session = ref.read(
      companionPanelSessionProvider,
    );
    _feed = CompanionLibraryListFeed.section(
      session,
      section: widget.section,
      parent: widget.parent,
    );
    startLive(session);
  }

  @override
  void dispose() {
    _feed.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  @override
  List<CompanionLibraryFeedBase> get liveFeeds => <CompanionLibraryFeedBase>[
    _feed,
  ];

  @override
  CompanionLibraryFeedBase get shownFeed => _feed;

  void _onQueryChanged(String _) {
    final String text = _query.text.trim();
    setState(() {});
    if (text != _feed.query) {
      takeStale(_feed);
      unawaited(_feed.setQuery(text));
    }
  }

  void _clearQuery() {
    _query.clear();
    _onQueryChanged('');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListenableBuilder(
          listenable: _feed,
          builder: (BuildContext context, Widget? _) =>
              CompanionLibraryPageHeader(title: _feed.title ?? widget.title),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: FushiSearchField(
            fieldKey: const ValueKey<String>('companion-library-list-search'),
            controller: _query,
            focusNode: _queryFocus,
            hintText: t.second_screen_library_browse_search_list,
            onChanged: _onQueryChanged,
            onSubmitted: _onQueryChanged,
            onClear: _clearQuery,
          ),
        ),
        Expanded(
          child: CompanionLibraryGrid(
            feed: _feed,
            section: widget.section,
            filtered: _query.text.trim().isNotEmpty,
          ),
        ),
      ],
    ),
  );
}

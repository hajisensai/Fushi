import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/second_screen/companion/companion_snapshot.dart';
import 'package:fushi/src/second_screen/companion/modules/reader_companion_schema.dart';
import 'package:fushi/src/second_screen/panel/companion/companion_panel_session.dart';
import 'package:fushi/src/second_screen/panel/companion/modules/companion_module_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show adaptiveAppBar;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Formats a count with thousands separators (9420 -> 9,420).
String _grouped(int n) {
  final String digits = n.abs().toString();
  final StringBuffer out = StringBuffer(n < 0 ? '-' : '');
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// "Series name · #3" (the index only when the book declares one).
String _seriesLabel(String name, num? index) {
  if (index == null) return name;
  final String n = index == index.roundToDouble()
      ? '${index.round()}'
      : '$index';
  return '$name · #$n';
}

/// Facts of the book info card: series and all-time reading of this book,
/// only what is known (stats once loaded).
List<CompanionInfoFact> _bookFacts(Map<String, Object?> snap) {
  final String? series = snap.strOrNull(ReaderCompanionKeys.series);
  final Map<String, Object?>? stats = snap.mapOrNull(ReaderCompanionKeys.stats);
  final int? allMs = stats?.intOrNull(ReaderCompanionKeys.allMs);
  final int? allChars = stats?.intOrNull(ReaderCompanionKeys.allChars);
  return <CompanionInfoFact>[
    if (series != null)
      CompanionInfoFact(
        label: t.second_screen_info_series,
        value: _seriesLabel(
          series,
          snap.doubleOrNull(ReaderCompanionKeys.seriesIndex),
        ),
      ),
    if (allMs != null)
      CompanionInfoFact(
        label: t.second_screen_info_total_time,
        value: formatStatTime(allMs),
      ),
    if (allChars != null)
      CompanionInfoFact(
        label: t.second_screen_info_total_chars,
        value: _grouped(allChars),
      ),
  ];
}

/// Now tab panel while an EPUB is open on top: book info, progress, page
/// controls, bookmark + contents, today's reading of this book and the
/// book's bookmarks (tap = jump). Schema: [ReaderCompanionKeys].
class ReaderCompanionPanel extends StatelessWidget {
  const ReaderCompanionPanel({required this.session, super.key});

  final CompanionPanelSession session;

  void _send(
    String action, [
    Map<String, Object?> args = const <String, Object?>{},
  ]) => session.command(action, args);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (BuildContext context, Widget? _) {
      final Map<String, Object?>? snap = session.snapshot;
      if (snap == null) {
        return const Center(child: FushiCircularProgressIndicator());
      }
      return _body(context, snap);
    },
  );

  Widget _body(BuildContext context, Map<String, Object?> snap) {
    final int chapter = snap.integer(ReaderCompanionKeys.chapterIndex);
    final int chapterCount = snap.integer(ReaderCompanionKeys.chapterCount);
    final double? percent = snap.doubleOrNull(ReaderCompanionKeys.percent);
    final String? author = snap.strOrNull(ReaderCompanionKeys.author);
    final String chapterTitle = snap.str(ReaderCompanionKeys.chapterTitle);
    final bool hasAudio = snap.flag(ReaderCompanionKeys.hasAudio);
    final bool playing = snap.flag(ReaderCompanionKeys.playing);
    final bool bookmarksEnabled = snap.flag(
      ReaderCompanionKeys.bookmarksEnabled,
    );
    final List<Map<String, Object?>> bookmarks = snap.maps(
      ReaderCompanionKeys.bookmarks,
    );
    final Map<String, Object?>? stats = snap.mapOrNull(
      ReaderCompanionKeys.stats,
    );
    final CompanionInfoCard bookCard = CompanionInfoCard(
      key: const ValueKey<String>('reader-info'),
      title: t.second_screen_info_book,
      facts: _bookFacts(snap),
    );
    final List<Widget> sections = <Widget>[
      CompanionTitleBlock(
        title: snap.str(ReaderCompanionKeys.title),
        subtitle: <String>[
          ?author,
          if (chapterTitle.isNotEmpty) chapterTitle,
        ].join(' · '),
        coverPath: snap.strOrNull(ReaderCompanionKeys.cover),
        fallbackIcon: FushiIcons.books,
      ),
      CompanionProgressRow(
        label: t.second_screen_reader_progress,
        fraction: percent == null ? null : percent / 100,
      ),
      CompanionActionRow(
        children: <Widget>[
          CompanionActionButton(
            key: const ValueKey<String>('reader-prev'),
            icon: FushiIcons.chevronLeft,
            tooltip: t.second_screen_reader_prev_page,
            onPressed: () => _send(
              ReaderCompanionActions.turnPage,
              const <String, Object?>{ReaderCompanionActions.forward: false},
            ),
          ),
          CompanionActionButton(
            key: const ValueKey<String>('reader-next'),
            icon: FushiIcons.chevronRight,
            tooltip: t.second_screen_reader_next_page,
            primary: true,
            onPressed: () => _send(
              ReaderCompanionActions.turnPage,
              const <String, Object?>{ReaderCompanionActions.forward: true},
            ),
          ),
          if (hasAudio)
            CompanionActionButton(
              key: const ValueKey<String>('reader-play'),
              icon: playing ? FushiIcons.pause : FushiIcons.play,
              tooltip: playing ? t.pause : t.play,
              onPressed: () => _send(ReaderCompanionActions.playPause),
            ),
          if (bookmarksEnabled)
            CompanionActionButton(
              key: const ValueKey<String>('reader-bookmark'),
              icon: FushiIcons.bookmarkAdd,
              tooltip: t.second_screen_reader_add_bookmark,
              onPressed: () => _send(ReaderCompanionActions.addBookmark),
            ),
          CompanionActionButton(
            key: const ValueKey<String>('reader-contents'),
            icon: FushiIcons.toc,
            tooltip: t.second_screen_reader_contents,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) =>
                    ReaderCompanionContentsPage(session: session),
              ),
            ),
          ),
        ],
      ),
      if (stats != null) _StatsRow(stats: stats),
      if (!bookCard.isEmpty) bookCard,
      if (bookmarksEnabled)
        _Bookmarks(
          bookmarks: bookmarks,
          count:
              snap.intOrNull(ReaderCompanionKeys.bookmarkCount) ??
              bookmarks.length,
          onJump: (int id) => _send(
            ReaderCompanionActions.jumpToBookmark,
            <String, Object?>{ReaderCompanionActions.id: id},
          ),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionPanelHeader(
          label: t.second_screen_reader_header,
          trailing: chapterCount > 0
              ? t.second_screen_reader_chapter(
                  current: chapter + 1,
                  total: chapterCount,
                )
              : null,
        ),
        Expanded(
          child: FushiEntranceScope(
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                16 + MediaQuery.paddingOf(context).bottom,
              ),
              itemCount: sections.length,
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int i) => Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
                  child: sections[i],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});

  final Map<String, Object?> stats;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: CompanionStatTile(
          value: formatStatTime(stats.integer(ReaderCompanionKeys.todayMs)),
          label: t.second_screen_reader_read_today,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: CompanionStatTile(
          value: _grouped(stats.integer(ReaderCompanionKeys.todayChars)),
          label: t.second_screen_reader_characters,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: CompanionStatTile(
          value: _grouped(stats.integer(ReaderCompanionKeys.todayLookups)),
          label: t.second_screen_reader_lookups,
        ),
      ),
    ],
  );
}

class _Bookmarks extends StatelessWidget {
  const _Bookmarks({
    required this.bookmarks,
    required this.count,
    required this.onJump,
  });

  final List<Map<String, Object?>> bookmarks;
  final int count;
  final void Function(int id) onJump;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CompanionSectionLabel(
          t.second_screen_reader_bookmarks,
          trailing: count <= 0
              ? null
              : Text(
                  _grouped(count),
                  key: const ValueKey<String>('reader-bookmark-count'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
        const SizedBox(height: 6),
        if (bookmarks.isEmpty)
          Text(
            t.second_screen_reader_no_bookmarks,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          for (final Map<String, Object?> b in bookmarks)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: CompanionLineTile(
                key: ValueKey<String>(
                  'reader-bookmark-${b.integer(ReaderCompanionKeys.bookmarkId)}',
                ),
                text: b.str(ReaderCompanionKeys.bookmarkLabel),
                maxLines: 1,
                trailing:
                    b.intOrNull(ReaderCompanionKeys.bookmarkChapter) == null
                    ? null
                    : t.second_screen_reader_bookmark_chapter(
                        n: b.integer(ReaderCompanionKeys.bookmarkChapter),
                      ),
                onTap: () => onJump(b.integer(ReaderCompanionKeys.bookmarkId)),
              ),
            ),
      ],
    );
  }
}

/// The book's table of contents, pushed on the Now tab's navigator; the
/// current entry is highlighted, tap jumps there on top and goes back.
class ReaderCompanionContentsPage extends StatelessWidget {
  const ReaderCompanionContentsPage({required this.session, super.key});

  final CompanionPanelSession session;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: adaptiveAppBar(
      context: context,
      title: Text(t.second_screen_reader_contents),
    ),
    body: ListenableBuilder(
      listenable: session,
      builder: (BuildContext context, Widget? _) {
        final Map<String, Object?> snap =
            session.snapshot ?? const <String, Object?>{};
        final List<Map<String, Object?>> toc = snap.maps(
          ReaderCompanionKeys.toc,
        );
        final int current = snap.integer(ReaderCompanionKeys.tocCurrent, -1);
        return FushiEntranceScope(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            itemCount: toc.length,
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int i,
            ) {
              final int depth = toc[i]
                  .integer(ReaderCompanionKeys.tocDepth)
                  .clamp(0, 4);
              return Padding(
                padding: EdgeInsetsDirectional.only(
                  start: depth * 14.0,
                  bottom: 6,
                ),
                child: CompanionLineTile(
                  key: ValueKey<String>('reader-toc-$i'),
                  text: toc[i].str(ReaderCompanionKeys.tocLabel),
                  selected: i == current,
                  onTap: () {
                    session.command(
                      ReaderCompanionActions.goToToc,
                      <String, Object?>{ReaderCompanionActions.index: i},
                    );
                    Navigator.of(context).maybePop();
                  },
                ),
              );
            }),
          ),
        );
      },
    ),
  );
}

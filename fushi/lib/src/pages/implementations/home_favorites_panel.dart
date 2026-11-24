/// 首页「收藏句子」小组件（[HomeWidgetKind.favorites]，可选组件，默认不放）。
///
/// 数据：收藏句表（`favorite_sentences`）+ 制卡历史（`mined_sentences`），两张表任何
/// 写入（收藏 / 取消收藏 / 同步合并 / 制卡）都让 [homeFavoritesSnapshotProvider] 重读；
/// 上锁作品的句子与收藏夹同一口径滤掉（[favoriteHiddenByLock]），首页是开机第一屏，
/// 宁可少列也不让私密内容出现。不改 DB schema。
///
/// 排版按格子的实际宽高走（与别的首页组件同一约定，不按尺寸档 switch）：
/// - 一行高、窄（1×1）：心形 + 总数大字 + 「今日 +N」；
/// - 一行高、宽（2×1 及更宽）：最新一句 + 查词词头 chip + 来源行；
/// - 两行及以上：最近几句的列表，行数跟高度走；
/// - 够宽（约 4 列）且有没制卡的收藏、制卡模块开着：底部挂「制卡（N）」，复用收藏夹的
///   批量制卡（`showFavoriteBatchMining`）。
///
/// 点块本身（标题区）进收藏夹「句子」页签；点一句跳回原处，分派与收藏夹列表同一份
/// （[FavoriteOriginNavigator]）。目的地模块关掉的句子点了改进收藏夹。
library;

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show
        FavoriteSentence,
        FavoriteSentenceRepository,
        kFavoriteSentenceSourceVideo,
        kFavoriteSentenceSourceWeb;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/media/privacy/media_visibility_providers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart'
    show favoriteHiddenByLock;
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart'
    show statTodayKey;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiSkeleton, FushiSkeletonShimmer;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart'
    show FushiButtonSize;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 列表最多取几句（6×4 的格子也放不下更多）。
const int kHomeFavoritesRecentLimit = 12;

/// 低于这个高度按「一行高」的格子排（窄网格一行 76–96、宽网格一行 104–140；两行
/// 起码 164），只放数字 / 最新一句，不排列表。
const double kHomeFavoritesListMinHeight = 160;

/// 够宽挂「制卡（N）」：约 4 列宽（宽网格列宽 117–173 + 间距）。
const double kHomeFavoritesCreateCardsMinWidth = 480;

/// 制卡历史与收藏句对上的键：同一句原文（去首尾空白）+ 同一作品。批量制卡写制卡历史时
/// 原句与 bookKey 都照收藏透传（`favorite_batch_mining_runner.dart`），词头可能被词典
/// 改写成辞书形，所以不按词头比。
String homeFavoriteMinedKey(String sentence, String? bookKey) =>
    '${bookKey ?? ''}\u0000${sentence.trim()}';

/// [selectHomeFavorites] 的结果（纯数据）。
@immutable
class HomeFavoritesSelection {
  const HomeFavoritesSelection({
    required this.total,
    required this.today,
    required this.recent,
    required this.unmined,
  });

  /// 没被上锁过滤掉的收藏句总数（与收藏夹「句子」页签同口径）。
  final int total;

  /// 其中今天收藏的条数（[FavoriteSentence.dateKey] == 今天的统计日期键）。
  final int today;

  /// 最近收藏的几句，新的在前，至多 [kHomeFavoritesRecentLimit] 句。
  final List<FavoriteSentence> recent;

  /// 可制卡（记着查词词头）且还没有对应制卡历史的收藏，新的在前。
  final List<FavoriteSentence> unmined;
}

/// 纯函数：从全部收藏句里挑首页要显示的内容。
///
/// [hidden] 是上锁过滤（收藏夹同一判据，见 [favoriteHiddenByLock]）；[todayKey] 是今天
/// 的统计日期键（`statTodayKey()`）；[minedKeys] 是制卡历史的 [homeFavoriteMinedKey]。
HomeFavoritesSelection selectHomeFavorites({
  required List<FavoriteSentence> favorites,
  required bool Function(FavoriteSentence favorite) hidden,
  required String todayKey,
  required Set<String> minedKeys,
  int recentLimit = kHomeFavoritesRecentLimit,
}) {
  final List<FavoriteSentence> shown =
      <FavoriteSentence>[
        for (final FavoriteSentence f in favorites)
          if (!hidden(f)) f,
      ]..sort(
        (FavoriteSentence a, FavoriteSentence b) =>
            b.createdAt.compareTo(a.createdAt),
      );
  return HomeFavoritesSelection(
    total: shown.length,
    today: shown.where((FavoriteSentence f) => f.dateKey == todayKey).length,
    recent: List<FavoriteSentence>.unmodifiable(shown.take(recentLimit)),
    unmined: List<FavoriteSentence>.unmodifiable(<FavoriteSentence>[
      for (final FavoriteSentence f in shown)
        if ((f.expression?.isNotEmpty ?? false) &&
            !minedKeys.contains(homeFavoriteMinedKey(f.text, f.bookKey)))
          f,
    ]),
  );
}

/// 列表里的一句：收藏本身 + 来源作品的显示名（过 display-title 门面，与收藏夹同口径）。
@immutable
class HomeFavoriteEntry {
  const HomeFavoriteEntry({required this.favorite, required this.title});

  final FavoriteSentence favorite;

  /// 来源作品显示名；可能为空串（老数据没有快照）。
  final String title;
}

/// 小组件的一份快照。
@immutable
class HomeFavoritesSnapshot {
  const HomeFavoritesSnapshot({
    required this.total,
    required this.today,
    required this.recent,
    required this.unmined,
  });

  static const HomeFavoritesSnapshot empty = HomeFavoritesSnapshot(
    total: 0,
    today: 0,
    recent: <HomeFavoriteEntry>[],
    unmined: <FavoriteSentence>[],
  );

  final int total;
  final int today;
  final List<HomeFavoriteEntry> recent;
  final List<FavoriteSentence> unmined;
}

/// 收藏句来源作品的显示名：视频按库行现查（改名直写行），网页收藏标题快照即网页名，
/// 其余按 bookKey 过 override 门面（与收藏夹 `_displayBookTitleFor` 同口径）。
Future<String> _favoriteDisplayTitle(
  VideoBookRepository videos,
  FavoriteSentence f,
) async {
  final String raw = f.bookTitle;
  final String? key = f.bookKey;
  if (key == null || key.isEmpty) return raw;
  if (f.source == kFavoriteSentenceSourceWeb) return raw.isEmpty ? key : raw;
  if (f.source == kFavoriteSentenceSourceVideo) {
    final VideoBookRow? row = await videos.getByBookUid(key);
    return row != null ? displayTitleForVideo(row) : raw;
  }
  final String display = displayTitleForBook(bookKey: key, rawTitle: raw);
  return display.isEmpty ? raw : display;
}

/// 读一份快照（[visibility] = 当前上锁显示口径）。
Future<HomeFavoritesSnapshot> loadHomeFavorites(
  FushiDatabase db,
  MediaVisibility visibility,
) async {
  final List<FavoriteSentence> all = await FavoriteSentenceRepository(
    db,
  ).getAll();
  if (all.isEmpty) return HomeFavoritesSnapshot.empty;
  final Set<String> minedKeys = <String>{
    for (final MinedSentenceRow m in await db.getAllMinedSentences())
      if (m.sentence.isNotEmpty) homeFavoriteMinedKey(m.sentence, m.bookKey),
  };
  final HomeFavoritesSelection selection = selectHomeFavorites(
    favorites: all,
    hidden: (FavoriteSentence f) => favoriteHiddenByLock(
      visibility,
      bookKey: f.bookKey,
      title: f.bookTitle,
      source: f.source,
    ),
    todayKey: statTodayKey(),
    minedKeys: minedKeys,
  );
  final VideoBookRepository videos = VideoBookRepository(db);
  return HomeFavoritesSnapshot(
    total: selection.total,
    today: selection.today,
    recent: <HomeFavoriteEntry>[
      for (final FavoriteSentence f in selection.recent)
        HomeFavoriteEntry(
          favorite: f,
          title: await _favoriteDisplayTitle(videos, f),
        ),
    ],
    unmined: selection.unmined,
  );
}

/// 先读一份，之后收藏句表 / 制卡历史有写入就重读一份。
Stream<HomeFavoritesSnapshot> watchHomeFavorites(
  FushiDatabase db,
  MediaVisibility visibility,
) => _homeFavoritesTriggers(
  db,
).asyncMap((_) => loadHomeFavorites(db, visibility));

Stream<void> _homeFavoritesTriggers(FushiDatabase db) async* {
  yield null;
  yield* db.tableUpdates(
    TableUpdateQuery.onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
      db.favoriteSentences,
      db.minedSentences,
    ]),
  );
}

/// 首页「收藏句子」的数据（组件不在首页上时自动释放、不再监听表变更）。上锁口径变了
/// （解锁 / 重新上锁 / 上锁标记变化）整条流重建。
final AutoDisposeStreamProvider<HomeFavoritesSnapshot>
homeFavoritesSnapshotProvider =
    StreamProvider.autoDispose<HomeFavoritesSnapshot>((Ref ref) {
      final FushiDatabase db = ref.watch(
        appProvider.select((AppModel m) => m.database),
      );
      final MediaVisibility visibility = ref.watch(mediaVisibilityProvider);
      return watchHomeFavorites(db, visibility);
    });

/// 首页「收藏句子」小组件。可用性恒为可用（[homeWidgetAvailable]）；导航与制卡由首页
/// 经回调接线，本 widget 只管画（测试据此不必起一个 AppModel）。
class HomeFavoritesPanel extends ConsumerWidget {
  const HomeFavoritesPanel({
    super.key,
    required this.onOpenCollections,
    required this.onOpenFavorite,
    required this.canOpenFavorite,
    this.onCreateCards,
    this.poster = false,
  });

  /// 点块本身：进收藏夹「句子」页签。
  final VoidCallback onOpenCollections;

  /// 点一句：跳回原处（[canOpenFavorite] 为 false 的句子不调它，改进收藏夹）。
  final void Function(HomeFavoriteEntry entry) onOpenFavorite;

  /// 这句的目的地模块开着、有定位（与收藏夹列表同一判据）。
  final bool Function(FavoriteSentence favorite) canOpenFavorite;

  /// 「制卡（N）」；null = 制卡模块关着，整颗按钮不出现。
  final void Function(List<FavoriteSentence> favorites)? onCreateCards;

  /// true = 海报色块外观。
  final bool poster;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HomeFavoritesSnapshot? data = ref
        .watch(homeFavoritesSnapshotProvider)
        .valueOrNull;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool dense = homeWidgetIsDense(c.maxHeight);
        final bool tall = c.maxHeight >= kHomeFavoritesListMinHeight;
        final bool wide = homeWidgetIsWide(c.maxWidth);
        final _HomeFavoritesMode mode = !tall && !wide
            ? _HomeFavoritesMode.count
            : !tall
            ? _HomeFavoritesMode.newest
            : _HomeFavoritesMode.list;
        final HomeFavoritesSnapshot? d = data;
        return HomeWidgetFrame(
          key: const ValueKey<String>('home-favorites-panel'),
          tapKey: const ValueKey<String>('home-favorites-panel-open'),
          title: t.home_widget_favorites,
          icon: FushiIcons.favorite,
          hueKey: HomeWidgetKind.favorites.id,
          poster: poster,
          dense: dense,
          // 1×1 只放心形 + 数字：内容自己标明是什么，省出标题行的高度。
          showHeader: mode != _HomeFavoritesMode.count,
          semanticLabel: d == null
              ? t.home_widget_favorites
              : '${t.home_widget_favorites} · ${t.home_favorites_count(n: d.total)}',
          onTap: onOpenCollections,
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: d == null
                ? const FushiSkeletonShimmer(
                    key: ValueKey<String>('home-favorites-skeleton'),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FushiSkeleton(width: 120, height: 20),
                    ),
                  )
                : d.total == 0
                ? _HomeFavoritesEmpty(
                    key: const ValueKey<String>('home-favorites-empty'),
                    compact: mode == _HomeFavoritesMode.count,
                  )
                : KeyedSubtree(
                    key: ValueKey<_HomeFavoritesMode>(mode),
                    child: _body(mode, d, c.maxWidth),
                  ),
          ),
        );
      },
    );
  }

  Widget _body(_HomeFavoritesMode mode, HomeFavoritesSnapshot d, double width) {
    final void Function(List<FavoriteSentence>)? create = onCreateCards;
    final bool showCreate =
        create != null &&
        d.unmined.isNotEmpty &&
        width >= kHomeFavoritesCreateCardsMinWidth;
    final VoidCallback? onCreate = showCreate ? () => create(d.unmined) : null;
    void open(HomeFavoriteEntry e) =>
        canOpenFavorite(e.favorite) ? onOpenFavorite(e) : onOpenCollections();
    return switch (mode) {
      _HomeFavoritesMode.count => _HomeFavoritesCount(
        total: d.total,
        today: d.today,
      ),
      _HomeFavoritesMode.newest => _HomeFavoritesNewest(
        entry: d.recent.first,
        total: d.total,
        onOpen: open,
        onCreateCards: onCreate,
        unminedCount: d.unmined.length,
      ),
      _HomeFavoritesMode.list => _HomeFavoritesList(
        entries: d.recent,
        total: d.total,
        today: d.today,
        onOpen: open,
        onCreateCards: onCreate,
        unminedCount: d.unmined.length,
      ),
    };
  }
}

enum _HomeFavoritesMode { count, newest, list }

/// 空态：一行提示怎么收藏（1×1 只放心形 + 0）。
class _HomeFavoritesEmpty extends StatelessWidget {
  const _HomeFavoritesEmpty({super.key, required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    if (compact) return const _HomeFavoritesCount(total: 0, today: 0);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        t.home_favorites_empty,
        key: const ValueKey<String>('home-favorites-empty-hint'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: context.fushiType.bodySmall.copyWith(color: style.muted),
      ),
    );
  }
}

/// 1×1：心形 + 总数大字 + 「今日 +N」（今天没收藏就不写）。
class _HomeFavoritesCount extends StatelessWidget {
  const _HomeFavoritesCount({required this.total, required this.today});

  final int total;
  final int today;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    return Semantics(
      key: const ValueKey<String>('home-favorites-count'),
      label: <String>[
        t.home_favorites_count(n: total),
        if (today > 0) t.home_favorites_today(n: today),
      ].join(' · '),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Flexible(
            child: Row(
              spacing: 6,
              children: <Widget>[
                FushiIcon(FushiIcons.favorite, size: 18, color: style.accent),
                Flexible(child: HomeWidgetFigure(value: '$total')),
              ],
            ),
          ),
          if (today > 0)
            Text(
              t.home_favorites_today(n: today),
              key: const ValueKey<String>('home-favorites-today'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.fushiType.labelMedium.copyWith(
                color: style.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// 来源行：作品名（+ 章节 / 集标签）。
String _sourceLine(HomeFavoriteEntry e) => <String>[
  if (e.title.isNotEmpty) e.title,
  if (e.favorite.chapterLabel?.isNotEmpty ?? false) e.favorite.chapterLabel!,
].join(' · ');

/// 句子正文；网页视频收藏没有句子，显示网页标题。
String _sentenceText(HomeFavoriteEntry e) =>
    e.favorite.text.isNotEmpty ? e.favorite.text : e.title;

/// 查词词头 chip（顶栏 ★ 收藏时记的词）。
class _HeadwordChip extends StatelessWidget {
  const _HeadwordChip({required this.headword});

  final String headword;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          headword,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.labelSmall.copyWith(
            color: style.foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 一句的点按目标：按压缩放 + 涟漪 + 读屏按钮语义。
class _FavoriteTapTarget extends StatelessWidget {
  const _FavoriteTapTarget({
    required this.entry,
    required this.onOpen,
    required this.child,
    required this.index,
  });

  final HomeFavoriteEntry entry;
  final void Function(HomeFavoriteEntry entry) onOpen;
  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    void open() => onOpen(entry);
    return FushiPressScale(
      child: Semantics(
        container: true,
        button: true,
        label: <String>[
          _sentenceText(entry),
          if (_sourceLine(entry).isNotEmpty) _sourceLine(entry),
        ].join(' · '),
        onTap: open,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey<String>('home-favorites-row/$index'),
          onTap: open,
          borderRadius: FushiBorderRadius.card,
          child: child,
        ),
      ),
    );
  }
}

/// 底部一行：总数（+ 今日）与「制卡（N）」。
class _HomeFavoritesFooter extends StatelessWidget {
  const _HomeFavoritesFooter({
    required this.total,
    required this.today,
    required this.onCreateCards,
    required this.unminedCount,
  });

  final int total;
  final int today;
  final VoidCallback? onCreateCards;
  final int unminedCount;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final VoidCallback? create = onCreateCards;
    return Row(
      spacing: 8,
      children: <Widget>[
        Expanded(
          child: Text(
            <String>[
              t.home_favorites_count(n: total),
              if (today > 0) t.home_favorites_today(n: today),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.labelMedium.copyWith(color: style.muted),
          ),
        ),
        if (create != null)
          FushiPressScale(
            child: FushiFilledButton.tonal(
              key: const ValueKey<String>('home-favorites-create-cards'),
              size: FushiButtonSize.xs,
              onPressed: create,
              child: Text(
                t.home_favorites_create_cards(n: unminedCount),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }
}

/// 一行高、宽（2×1 起）：最新一句 + 词头 chip + 来源行（够宽再挂制卡按钮）。
class _HomeFavoritesNewest extends StatelessWidget {
  const _HomeFavoritesNewest({
    required this.entry,
    required this.total,
    required this.onOpen,
    required this.onCreateCards,
    required this.unminedCount,
  });

  final HomeFavoriteEntry entry;
  final int total;
  final void Function(HomeFavoriteEntry entry) onOpen;
  final VoidCallback? onCreateCards;
  final int unminedCount;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final String? headword = entry.favorite.expression;
    final String source = _sourceLine(entry);
    final VoidCallback? create = onCreateCards;
    final Widget sentence = _FavoriteTapTarget(
      entry: entry,
      onOpen: onOpen,
      index: 0,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final TextStyle sentenceStyle = context.fushiType.bodyMedium.copyWith(
            color: style.foreground,
            fontWeight: FontWeight.w600,
          );
          final TextStyle metaStyle = context.fushiType.labelSmall.copyWith(
            color: style.muted,
          );
          // 窄网格一行高的格子只放得下一行字：先保句子，整行放得下才挂来源行。
          final bool showMeta =
              box.maxHeight >=
              homeWidgetLineHeight(context, sentenceStyle) +
                  homeWidgetLineHeight(context, metaStyle) +
                  6;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                _sentenceText(entry),
                key: const ValueKey<String>('home-favorites-newest'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: sentenceStyle,
              ),
              if (showMeta)
                Row(
                  spacing: 6,
                  children: <Widget>[
                    if (headword != null && headword.isNotEmpty)
                      Flexible(child: _HeadwordChip(headword: headword)),
                    if (source.isNotEmpty)
                      Flexible(
                        flex: 2,
                        child: Text(
                          source,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
    return FushiStaggeredEntrance(
      index: 0,
      child: Row(
        spacing: 10,
        children: <Widget>[
          Expanded(child: sentence),
          if (create != null)
            FushiPressScale(
              child: FushiFilledButton.tonal(
                key: const ValueKey<String>('home-favorites-create-cards'),
                size: FushiButtonSize.xs,
                onPressed: create,
                child: Text(
                  t.home_favorites_create_cards(n: unminedCount),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 两行及以上：最近几句的列表，放得下几句放几句（整句放得下才放，不出半行）。
class _HomeFavoritesList extends StatelessWidget {
  const _HomeFavoritesList({
    required this.entries,
    required this.total,
    required this.today,
    required this.onOpen,
    required this.onCreateCards,
    required this.unminedCount,
  });

  final List<HomeFavoriteEntry> entries;
  final int total;
  final int today;
  final void Function(HomeFavoriteEntry entry) onOpen;
  final VoidCallback? onCreateCards;
  final int unminedCount;

  static const double _rowGap = 4;
  static const double _rowPad = 4;

  @override
  Widget build(BuildContext context) {
    final HomeWidgetStyle style = HomeWidgetStyle.of(context);
    final TextStyle sentenceStyle = context.fushiType.bodyMedium.copyWith(
      color: style.foreground,
      height: 1.3,
    );
    final TextStyle metaStyle = context.fushiType.labelSmall.copyWith(
      color: style.muted,
    );
    final TextStyle footerStyle = context.fushiType.labelMedium;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double sentenceLine = homeWidgetLineHeight(
          context,
          sentenceStyle,
        );
        final double metaLine = homeWidgetLineHeight(context, metaStyle);
        // 宽格一句一行放得下大半句，窄格给两行。
        final int sentenceLines = homeWidgetIsWide(box.maxWidth) ? 1 : 2;
        // 向上取整再留 2px 余量：CJK 字形的实际行盒会比字号 × 行高略高。
        final double rowHeight =
            (sentenceLine * sentenceLines + metaLine + _rowPad * 2)
                .ceilToDouble() +
            2;
        final double footerHeight = homeWidgetLineHeight(
          context,
          footerStyle,
        ).clamp(28, 40).toDouble();
        final double listHeight = box.maxHeight - footerHeight - _rowGap;
        final int rows = ((listHeight + _rowGap) / (rowHeight + _rowGap))
            .floor()
            .clamp(1, entries.length);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: ClipRect(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: _rowGap,
                  children: <Widget>[
                    for (int i = 0; i < rows; i++)
                      FushiStaggeredEntrance(
                        index: i,
                        child: SizedBox(
                          height: rowHeight,
                          child: _FavoriteTapTarget(
                            entry: entries[i],
                            onOpen: onOpen,
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: _rowPad,
                              ),
                              // 字号放大 / 字体回退让一行比算的高时裁掉，不抛溢出。
                              child: HomeWidgetOverflowClip(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(
                                      _sentenceText(entries[i]),
                                      maxLines: sentenceLines,
                                      overflow: TextOverflow.ellipsis,
                                      style: sentenceStyle,
                                    ),
                                    Text(
                                      <String>[
                                        if (entries[i]
                                                .favorite
                                                .expression
                                                ?.isNotEmpty ??
                                            false)
                                          entries[i].favorite.expression!,
                                        if (_sourceLine(entries[i]).isNotEmpty)
                                          _sourceLine(entries[i]),
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: metaStyle,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: _rowGap),
            SizedBox(
              height: footerHeight,
              child: _HomeFavoritesFooter(
                total: total,
                today: today,
                onCreateCards: onCreateCards,
                unminedCount: unminedCount,
              ),
            ),
          ],
        );
      },
    );
  }
}

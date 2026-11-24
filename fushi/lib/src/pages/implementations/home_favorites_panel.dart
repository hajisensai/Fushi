/// 首页「收藏句子」小组件（[HomeWidgetKind.favorites]，可选组件，默认不放）。
///
/// 数据：收藏句表（`favorite_sentences`）+ 制卡历史（`mined_sentences`），两张表任何
/// 写入（收藏 / 取消收藏 / 同步合并 / 制卡）都让首页持有的流（[watchHomeFavorites]）
/// 重读；只读要显示的量（计数走 SQL、句子只取最近几条，见 [loadHomeFavorites]）。
/// 上锁作品的句子与收藏夹同一口径滤掉（[favoriteHiddenByLock]），首页是开机第一屏，
/// 宁可少列也不让私密内容出现。
///
/// 排版按格子的实际宽高走（与别的首页组件同一约定，不按尺寸档 switch）：
/// - 一行高、窄（1×1）：心形 + 总数大字 + 「今日 +N」；
/// - 一行高、宽（2×1 及更宽）：最新一句 + 查词词头 chip + 来源行；
/// - 两行及以上：最近几句的列表，行数跟高度走；
/// - 够宽（约 4 列）且列出的句子里有没制卡的、制卡模块开着：底部挂「制卡（N）」，复用
///   收藏夹的批量制卡（`showFavoriteBatchMining`）。
///
/// 点块本身（标题区）进收藏夹「句子」页签；点一句跳回原处，分派与收藏夹列表同一份
/// （收藏夹页的 `FavoriteOriginNavigator`，由首页接线）。目的地模块关掉的句子点了改进
/// 收藏夹。
library;

import 'dart:async';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdateQuery;
import 'package:fushi_audio/fushi_audio.dart'
    show
        FavoriteSentence,
        FavoriteSentenceRepository,
        kFavoriteSentenceSourceVideo;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/favorites/favorite_visibility.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/pages/implementations/home_widget_frame.dart';
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
import 'package:fushi/src/utils/misc/error_log_service.dart';

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
  const HomeFavoritesSelection({required this.recent, required this.unmined});

  /// 最近收藏的几句，新的在前，至多 [kHomeFavoritesRecentLimit] 句。
  final List<FavoriteSentence> recent;

  /// [recent] 里可制卡（记着查词词头）且还没有对应制卡历史的收藏，新的在前。只看
  /// 列出来的这几句：首页不为一颗按钮读整张收藏表与制卡历史，更早的收藏去收藏夹制卡。
  final List<FavoriteSentence> unmined;
}

/// 纯函数：从最近的收藏句里挑首页要列的几句与其中没制卡的。
///
/// [favorites] 新的在前；[hidden] 是上锁过滤（收藏夹同一判据，见
/// [favoriteHiddenByLock]）；[minedKeys] 是这几句对应制卡历史的 [homeFavoriteMinedKey]。
HomeFavoritesSelection selectHomeFavorites({
  required List<FavoriteSentence> favorites,
  required bool Function(FavoriteSentence favorite) hidden,
  required Set<String> minedKeys,
  int recentLimit = kHomeFavoritesRecentLimit,
}) {
  final List<FavoriteSentence> recent = <FavoriteSentence>[
    for (final FavoriteSentence f in favorites)
      if (!hidden(f)) f,
  ].take(recentLimit).toList(growable: false);
  return HomeFavoritesSelection(
    recent: List<FavoriteSentence>.unmodifiable(recent),
    unmined: List<FavoriteSentence>.unmodifiable(<FavoriteSentence>[
      for (final FavoriteSentence f in recent)
        if ((f.expression?.isNotEmpty ?? false) &&
            !minedKeys.contains(homeFavoriteMinedKey(f.text, f.bookKey)))
          f,
    ]),
  );
}

/// 纯函数：有作品上锁时数总数 / 今日（[rows] 是全部收藏句的四列，不含正文；没有
/// 上锁时走 SQL 计数，见 [loadHomeFavorites]）。
({int total, int today}) countHomeFavorites({
  required Iterable<FavoriteSentenceLockRow> rows,
  required bool Function(FavoriteSentenceLockRow row) hidden,
  required String todayKey,
}) {
  int total = 0;
  int today = 0;
  for (final FavoriteSentenceLockRow r in rows) {
    if (hidden(r)) continue;
    total++;
    if (r.dateKey == todayKey) today++;
  }
  return (total: total, today: today);
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

  /// 没被上锁过滤掉的收藏句总数（与收藏夹「句子」页签同口径）。
  final int total;

  /// 其中今天收藏的条数（[FavoriteSentence.dateKey] == 今天的统计日期键）。
  final int today;
  final List<HomeFavoriteEntry> recent;
  final List<FavoriteSentence> unmined;
}

/// 一句收藏的来源作品显示名（过 display-title 门面，与收藏夹同口径）。[videoRow] 是
/// 视频收藏的本机库行（[loadHomeFavorites] 按 bookUid 一次批量查好；不是视频 / 没入库
/// 为 null）。由首页传入：display-title 门面依赖阅读器来源，本文件 import 它会被拖进
/// import 大环。
typedef HomeFavoriteTitleOf =
    String Function(FavoriteSentence favorite, VideoBookRow? videoRow);

/// 读一份快照（[visibility] = 当前上锁显示口径，[todayKey] = 今天的统计日期键）。
///
/// 只读要显示的量：总数 / 今日没有上锁作品时一条 SQL 数完（有上锁时读四列小行判
/// 上锁）；句子只取最近 [recentLimit] 条（上锁滤掉的再往后补页）；制卡判定只查这
/// 几句的制卡历史；视频标题按 bookUid 一次批量查。
Future<HomeFavoritesSnapshot> loadHomeFavorites(
  FushiDatabase db,
  MediaVisibility visibility, {
  required String todayKey,
  required HomeFavoriteTitleOf titleOf,
  int recentLimit = kHomeFavoritesRecentLimit,
}) async {
  bool hidden(String? bookKey, String title, String source) =>
      favoriteHiddenByLock(
        visibility,
        bookKey: bookKey,
        title: title,
        source: source,
      );
  final ({int total, int today}) counts = visibility.hidesAnything
      ? countHomeFavorites(
          rows: await db.getFavoriteSentenceLockRows(),
          hidden: (FavoriteSentenceLockRow r) =>
              hidden(r.bookKey, r.bookTitle, r.source),
          todayKey: todayKey,
        )
      : await db.countFavoriteSentences(todayKey: todayKey);
  if (counts.total == 0) return HomeFavoritesSnapshot.empty;

  final List<FavoriteSentence> visible = <FavoriteSentence>[];
  for (int offset = 0; visible.length < recentLimit;) {
    final List<FavoriteSentenceRow> page = await db
        .getRecentFavoriteSentenceRows(limit: recentLimit, offset: offset);
    for (final FavoriteSentenceRow row in page) {
      final FavoriteSentence f = FavoriteSentenceRepository.fromRow(row);
      if (!hidden(f.bookKey, f.bookTitle, f.source)) visible.add(f);
    }
    if (page.length < recentLimit) break;
    offset += page.length;
  }
  final List<FavoriteSentence> candidates = visible
      .take(recentLimit)
      .toList(growable: false);
  final Set<String> minedKeys = <String>{
    for (final ({String sentence, String? bookKey}) m
        in await db.getMinedSentenceOrigins(<String>[
          for (final FavoriteSentence f in candidates)
            if (f.expression?.isNotEmpty ?? false) f.text,
        ]))
      homeFavoriteMinedKey(m.sentence, m.bookKey),
  };
  final HomeFavoritesSelection selection = selectHomeFavorites(
    favorites: candidates,
    hidden: (_) => false,
    minedKeys: minedKeys,
    recentLimit: recentLimit,
  );
  final Map<String, VideoBookRow> videoRows = <String, VideoBookRow>{
    for (final VideoBookRow row
        in await VideoBookRepository(db).getByBookUids(<String>{
          for (final FavoriteSentence f in selection.recent)
            if (f.source == kFavoriteSentenceSourceVideo &&
                (f.bookKey?.isNotEmpty ?? false))
              f.bookKey!,
        }))
      row.bookUid: row,
  };
  return HomeFavoritesSnapshot(
    total: counts.total,
    today: counts.today,
    recent: <HomeFavoriteEntry>[
      for (final FavoriteSentence f in selection.recent)
        HomeFavoriteEntry(
          favorite: f,
          title: titleOf(
            f,
            f.source == kFavoriteSentenceSourceVideo
                ? videoRows[f.bookKey ?? '']
                : null,
          ),
        ),
    ],
    unmined: selection.unmined,
  );
}

/// 先读一份，之后收藏句表 / 制卡历史有写入就重读一份（[todayKey] 每次重读现取，
/// 跨过统计日界后的下一次重读按新的一天数「今日」）。
Stream<HomeFavoritesSnapshot> watchHomeFavorites(
  FushiDatabase db,
  MediaVisibility visibility, {
  required String Function() todayKey,
  required HomeFavoriteTitleOf titleOf,
}) => _homeFavoritesTriggers(db).asyncMap(
  (_) =>
      loadHomeFavorites(db, visibility, todayKey: todayKey(), titleOf: titleOf),
);

Stream<void> _homeFavoritesTriggers(FushiDatabase db) async* {
  yield null;
  yield* db.tableUpdates(
    TableUpdateQuery.onAllTables(<ResultSetImplementation<dynamic, dynamic>>[
      db.favoriteSentences,
      db.minedSentences,
    ]),
  );
}

/// 首页「收藏句子」小组件。可用性恒为可用（[homeWidgetAvailable]）；数据、导航与制卡
/// 都由首页接线（首页持有 [watchHomeFavorites] 的 provider），本 widget 只管画——不读
/// AppModel，也就不进 import 大环，测试也不必起一个 AppModel。
class HomeFavoritesPanel extends StatelessWidget {
  const HomeFavoritesPanel({
    super.key,
    required this.data,
    required this.onOpenCollections,
    required this.onOpenFavorite,
    required this.canOpenFavorite,
    this.onCreateCards,
    this.poster = false,
  });

  /// 当前快照；null = 还在读（画骨架）。
  final HomeFavoritesSnapshot? data;

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
  Widget build(BuildContext context) {
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

/// 首页网格里的「收藏句子」格子：订阅 [watchHomeFavorites] 并把快照交给
/// [HomeFavoritesPanel]。
///
/// 订阅由本 State 持有（不放全局 provider）：格子从首页移走即取消、不再监听表变更；
/// 上锁口径（[MediaVisibility.of]）或数据库换了就重订阅，并先清回骨架——重新上锁后
/// 不让旧快照里的私密句子多显示一帧。读库失败记 [ErrorLogService]，格子保持上一份
/// 快照（第一份就失败则停在骨架）。
class HomeFavoritesCard extends StatefulWidget {
  const HomeFavoritesCard({
    super.key,
    required this.database,
    required this.todayKey,
    required this.titleOf,
    required this.onOpenCollections,
    required this.onOpenFavorite,
    required this.canOpenFavorite,
    this.onCreateCards,
    this.poster = false,
  });

  final FushiDatabase database;

  /// 今天的统计日期键（`statTodayKey`），每次重读现取。
  final String Function() todayKey;

  /// 来源作品显示名（见 [HomeFavoriteTitleOf]）。
  final HomeFavoriteTitleOf titleOf;

  final VoidCallback onOpenCollections;
  final void Function(HomeFavoriteEntry entry) onOpenFavorite;
  final bool Function(FavoriteSentence favorite) canOpenFavorite;
  final void Function(List<FavoriteSentence> favorites)? onCreateCards;
  final bool poster;

  @override
  State<HomeFavoritesCard> createState() => _HomeFavoritesCardState();
}

class _HomeFavoritesCardState extends State<HomeFavoritesCard> {
  StreamSubscription<HomeFavoritesSnapshot>? _subscription;
  MediaVisibility? _visibility;
  HomeFavoritesSnapshot? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MediaVisibility next = MediaVisibility.of(context);
    if (!identical(next, _visibility)) _subscribe(next);
  }

  @override
  void didUpdateWidget(HomeFavoritesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.database, widget.database)) {
      _subscribe(_visibility ?? MediaVisibility.of(context));
    }
  }

  void _subscribe(MediaVisibility visibility) {
    unawaited(_subscription?.cancel());
    _visibility = visibility;
    _data = null;
    _subscription =
        watchHomeFavorites(
          widget.database,
          visibility,
          todayKey: widget.todayKey,
          titleOf: widget.titleOf,
        ).listen(
          (HomeFavoritesSnapshot snapshot) {
            if (mounted) setState(() => _data = snapshot);
          },
          onError: (Object error, StackTrace stack) {
            ErrorLogService.instance.log(
              'HomeFavoritesCard.load',
              error,
              stack,
            );
          },
        );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HomeFavoritesPanel(
    data: _data,
    poster: widget.poster,
    onOpenCollections: widget.onOpenCollections,
    onOpenFavorite: widget.onOpenFavorite,
    canOpenFavorite: widget.canOpenFavorite,
    onCreateCards: widget.onCreateCards,
  );
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
        borderRadius: FushiBorderRadius.chip,
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

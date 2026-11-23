/// 书 / 漫画合集「获取各卷封面与横幅」「清除已获取的封面」两个动作与结果面板。
///
/// 合集详情页只拿到 [CollectionArtScrape]（书架传进来的一个数据参数），按钮、运行、
/// 结果展示都在这里：合集详情页也被游戏库复用，不让它直接依赖书的刮削服务。
/// 受「在线服务」模块门约束（[CollectionArtScrape.enabled]）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/metadata/book_art_scrape_service.dart';
import 'package:fushi/src/media/metadata/book_art_store.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';

/// 书架传给合集详情页的「刮每卷封面」能力。
class CollectionArtScrape {
  /// 只收窄依赖（库、缩略图目录、两道门），不收整个 `AppModel`：本类挂在合集
  /// 详情页上，拿 `AppModel` 会把书图刮削整条链拉进 app 的大导入环。
  const CollectionArtScrape({
    required this.database,
    required this.thumbnailsDirectory,
    required this.servicesEnabled,
    required this.migrationReadonly,
    this.serviceFactory,
  });

  final FushiDatabase database;
  final Directory thumbnailsDirectory;

  /// 「在线服务」模块当前是否开着（每次读，跟随设置变化）。
  final bool Function() servicesEnabled;

  /// 数据是否已迁移到新版、旧版只读。
  final bool Function() migrationReadonly;

  /// 测试接缝：造服务（注入离线 http client）。
  final BookArtScrapeService Function()? serviceFactory;

  /// 「在线服务」模块开着才出入口、才发请求。
  bool get enabled => servicesEnabled();

  BookArtStore get store => BookArtStore.of(thumbnailsDirectory);

  /// 刮削层变更通知（写入 / 清除 / 撤销后合集详情页重算横幅）。
  Listenable get changes => store;

  /// [rows] 里书成员的合集横幅（[BookArtStore.backdropForCollection]，成员多数票
  /// 那张）；没下到为 null。只读刮削层，不受「在线服务」门约束：图已在本地。
  File? bannerFor(Iterable<MediaCollectionItemRow> rows) =>
      store.backdropForCollection(<String>[
        for (final MediaCollectionItemRow r in rows)
          if (r.mediaType == 'epub') r.entryKey,
      ]);

  BookArtScrapeService _service() =>
      serviceFactory?.call() ??
      BookArtScrapeService(database: database, store: store);

  /// 合集里有没有本地书（只有书 / 漫画合集出这两个动作）。
  static bool appliesTo(Iterable<MediaCollectionItemRow> rows) =>
      rows.any((MediaCollectionItemRow r) => r.mediaType == 'epub');

  /// 运行并弹结果面板；写入后调 [onChanged] 刷新书架。
  Future<void> scrape(
    BuildContext context, {
    required int collectionId,
    required VoidCallback onChanged,
  }) async {
    if (!enabled) return;
    if (_readonly()) return;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext ctx) => CollectionArtScrapeDialog(
        run: (Map<String, BookArtSeriesPin> pins) async {
          final BookArtScrapeService service = _service();
          try {
            final BookArtRunResult result = await service.run(
              await service.collectionBookKeys(collectionId),
              pins: pins,
              onlyPinnedGroups: pins.isNotEmpty,
              // 界面路径不提供撤销（清除有确认框），不留撤销备份文件。
              recordUndo: false,
            );
            if (result.count(BookArtBookOutcome.written) > 0 ||
                result.series.any((BookArtSeriesPlan s) => s.banner != null)) {
              onChanged();
            }
            return result;
          } finally {
            service.close();
          }
        },
      ),
    );
  }

  /// 数据已迁移到新版、旧版只读时不写刮削层（与 ops 路由同一道门）。
  bool _readonly() {
    if (!migrationReadonly()) return false;
    FushiToast.show(
      msg: t.migration_readonly_note,
      severity: ToastSeverity.warning,
    );
    return true;
  }

  /// 清除合集各成员的刮削层（用户 override 不动）。先确认：界面路径没有撤销，
  /// 重新获取要再联网、受限流约束，待确认时手选的系列也会一起丢。
  Future<void> clear(
    BuildContext context, {
    required int collectionId,
    required VoidCallback onChanged,
  }) async {
    if (_readonly()) return;
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.collection_art_scrape_clear,
      message: t.collection_art_scrape_clear_confirm,
      destructive: true,
    );
    if (!confirmed) return;
    final List<String> keys = <String>[
      for (final MediaCollectionItemRow r in await database.getCollectionItems(
        collectionId,
      ))
        if (r.mediaType == 'epub') r.entryKey,
    ];
    int removed = 0;
    for (final String key in keys) {
      if (!store.hasCover(key) && store.recordFor(key) == null) continue;
      await store.remove(key);
      removed++;
    }
    onChanged();
    FushiToast.show(
      msg: t.collection_art_scrape_cleared(count: removed),
      severity: ToastSeverity.success,
    );
  }
}

/// 运行 + 结果面板：运行中转圈；结果按系列列出写入 / 保留本地 / 失败；待确认的系列
/// 列候选，点「使用」钉死该系列重跑。有任何一项来自 MangaBaka 时显示署名。
class CollectionArtScrapeDialog extends StatefulWidget {
  const CollectionArtScrapeDialog({required this.run, super.key});

  final Future<BookArtRunResult> Function(Map<String, BookArtSeriesPin> pins)
  run;

  @override
  State<CollectionArtScrapeDialog> createState() =>
      _CollectionArtScrapeDialogState();
}

class _CollectionArtScrapeDialogState extends State<CollectionArtScrapeDialog> {
  BookArtRunResult? _result;
  Object? _failure;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _start(const <String, BookArtSeriesPin>{});
  }

  Future<void> _start(Map<String, BookArtSeriesPin> pins) async {
    setState(() {
      _running = true;
      _failure = null;
    });
    BookArtRunResult? result;
    Object? failure;
    try {
      result = await widget.run(pins);
    } catch (e, stack) {
      ErrorLogService.instance.log('CollectionArtScrape.run', e, stack);
      failure = e;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _failure = failure;
      if (result != null) {
        // 钉死重跑只回来那一组：合并进上一轮结果。
        final BookArtRunResult? previous = _result;
        _result = previous == null || pins.isEmpty
            ? result
            : BookArtRunResult(
                dryRun: false,
                snapshots: <BookArtSnapshot>[
                  ...previous.snapshots,
                  ...result.snapshots,
                ],
                mangaBakaRateLimited:
                    previous.mangaBakaRateLimited ||
                    result.mangaBakaRateLimited,
                series: <BookArtSeriesPlan>[
                  for (final BookArtSeriesPlan s in previous.series)
                    result.series.firstWhere(
                      (BookArtSeriesPlan n) =>
                          n.seriesKey == s.seriesKey &&
                          pins.containsKey(s.seriesKey),
                      orElse: () => s,
                    ),
                ],
              );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BookArtRunResult? result = _result;
    Widget body;
    if (_running) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 96, child: FushiLoadingView()),
          Text(t.collection_art_scrape_running),
        ],
      );
    } else if (_failure != null || result == null) {
      body = Text('${t.collection_art_scrape_source_failed}\n$_failure');
    } else {
      body = _buildResult(theme, result);
    }
    return FushiAlertDialog(
      title: Text(t.collection_art_scrape_action),
      content: SizedBox(width: 520, child: body),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }

  Widget _buildResult(ThemeData theme, BookArtRunResult result) {
    final List<Widget> rows = <Widget>[
      Text(
        t.collection_art_scrape_result(
          written: result.count(BookArtBookOutcome.written),
          sharper: result.count(BookArtBookOutcome.localSharper),
          failed: result.count(BookArtBookOutcome.failed),
        ),
        key: const ValueKey<String>('collection_art_scrape_summary'),
      ),
      if (result.count(BookArtBookOutcome.unchanged) > 0)
        Text(
          t.collection_art_scrape_unchanged(
            count: result.count(BookArtBookOutcome.unchanged),
          ),
          style: theme.textTheme.bodySmall,
        ),
      if (result.mangaBakaRateLimited)
        Text(
          t.collection_art_scrape_rate_limited,
          style: theme.textTheme.bodySmall,
        ),
      for (final BookArtSeriesPlan s in result.series) _seriesTile(theme, s),
    ];
    final bool attribution =
        result.usesMangaBaka ||
        result.series.any(
          (BookArtSeriesPlan s) => s.options.any(
            (BookArtSeriesOption o) => o.source.wire == 'mangabaka',
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(
          child: FushiEntranceScope(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: rows.length,
              itemBuilder: fushiStaggeredItemBuilder(
                (BuildContext context, int index) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: rows[index],
                ),
              ),
            ),
          ),
        ),
        if (attribution)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t.book_scrape_mangabaka_attribution,
              key: const ValueKey<String>('collection_art_attribution'),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _seriesTile(ThemeData theme, BookArtSeriesPlan s) {
    final TextStyle? small = theme.textTheme.bodySmall;
    final List<Widget> lines = <Widget>[
      Text(
        s.matchedTitle == null
            ? s.seriesTitle
            : '${s.seriesTitle} → ${s.matchedTitle}',
        style: theme.textTheme.titleSmall,
      ),
      if (s.decision == BookArtDecision.rejected)
        Text(t.collection_art_scrape_no_match, style: small),
      for (final String e in s.errors)
        Text('${t.collection_art_scrape_source_failed}: $e', style: small),
      if (s.decision == BookArtDecision.needsConfirm) ...<Widget>[
        Text(t.collection_art_scrape_needs_confirm, style: small),
        for (final BookArtSeriesOption o in s.options.take(5))
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${o.title} · ${o.source.wire} · '
                  '${(o.coverage * 100).round()}%',
                  style: small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              FushiTextButton(
                onPressed: _running
                    ? null
                    : () => _start(<String, BookArtSeriesPin>{
                        s.seriesKey: BookArtSeriesPin(
                          source: o.source,
                          id: o.id,
                        ),
                      }),
                child: Text(t.book_scrape_use),
              ),
            ],
          ),
      ],
      if (s.decision == BookArtDecision.accepted)
        Text(
          t.collection_art_scrape_result(
            written: s.books
                .where(
                  (BookArtBookPlan b) =>
                      b.outcome == BookArtBookOutcome.written,
                )
                .length,
            sharper: s.books
                .where(
                  (BookArtBookPlan b) =>
                      b.outcome == BookArtBookOutcome.localSharper,
                )
                .length,
            failed: s.books
                .where(
                  (BookArtBookPlan b) => b.outcome == BookArtBookOutcome.failed,
                )
                .length,
          ),
          style: small,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines,
    );
  }
}

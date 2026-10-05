// 分享卡片：「本周 / 本月 / 累计读完 N 部 + 最多 9 张封面拼图 + 周期字数 + 昵称#」。
//
// 周期与榜单同一套周 / 月 / 总，对话框里可切换，默认跟随排行页当前选中的周期。
// 卡片先在对话框里完整渲染出来给用户看（封面图此时已真实加载），用户点「分享」时对
// 同一个 [RepaintBoundary] 直接 `toImage` → PNG → [FushiShare.shareFiles]，附带
// `LeaderboardClient.shareUserUrl` 的主页链接。不走离屏 Overlay：预览即成品。
// 「复制链接」只复制主页链接，不需要图片也能分享。

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';
import 'package:share_plus/share_plus.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

/// 拼图最多几张封面（3×3）。
const int kLeaderboardShareMaxCovers = 9;

/// 统计周期内读完数时最多翻几页书架（每页 50；超出按已数到的算，卡片上是「≥」语义
/// 的近似——一个月读完 200 部以上的人不需要精确数字）。「总」不数书架，直接取服务端累计。
const int kLeaderboardShareMaxPages = 4;

/// 卡片逻辑宽度（输出 PNG = 宽 × [kLeaderboardSharePixelRatio]）。
const double kLeaderboardShareCardWidth = 360;
const double kLeaderboardSharePixelRatio = 3;

/// 计入「读完 N 部」的作品指标（字数不是作品数）。
const List<LeaderboardMetric> kLeaderboardShareWorkMetrics =
    <LeaderboardMetric>[
      LeaderboardMetric.book,
      LeaderboardMetric.manga,
      LeaderboardMetric.video,
      LeaderboardMetric.game,
    ];

/// 卡片数据（纯数据，渲染与取数分离，便于测试）。
@immutable
class LeaderboardShareCardData {
  const LeaderboardShareCardData({
    required this.accountTag,
    required this.window,
    required this.periodLabel,
    required this.finishedCount,
    required this.chars,
    required this.covers,
  });

  final String accountTag;

  /// 统计周期（与榜单同一套周 / 月 / 总）。
  final LeaderboardWindow window;

  /// 周 = 本周一 `YYYY-MM-DD`；月 = `YYYY-MM`；总 = 截至今天 `YYYY-MM-DD`。
  final String periodLabel;
  final int finishedCount;

  /// 周期内阅读字数。
  final int chars;

  /// 拼图用的作品（已排除 nsfw，≤ [kLeaderboardShareMaxCovers]）。
  final List<LeaderboardWork> covers;
}

String _shareDateKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 周期起始日 `YYYY-MM-DD`，口径与服务端榜单一致（`services/leaderboard/src/snapshots.js`
/// 的 `windowStartKey`）：按 UTC 日期，周 = 本周一，月 = 本月 1 日，总 = null。
String? leaderboardShareWindowStart(LeaderboardWindow window, DateTime now) {
  final DateTime utc = now.toUtc();
  final DateTime today = DateTime.utc(utc.year, utc.month, utc.day);
  return switch (window) {
    LeaderboardWindow.week => _shareDateKey(
      today.subtract(Duration(days: today.weekday - DateTime.monday)),
    ),
    LeaderboardWindow.month => _shareDateKey(
      DateTime.utc(today.year, today.month),
    ),
    LeaderboardWindow.all => null,
  };
}

/// 卡片上的周期标签：周 = 本周一 `YYYY-MM-DD`，月 = `YYYY-MM`（两者按 UTC，与服务端
/// 周期锚点同口径，见 [leaderboardShareWindowStart]）；总 = 截至 [now] 的**本地**日期
/// `YYYY-MM-DD`——「总」没有服务端周期锚点，「截至哪天」是给用户看的日期，按 UTC 算
/// 会让东八区早上 8 点前分享的卡片写成前一天。
///
/// 本地日期 = [now] 的 UTC 时刻 + [localOffset]（用户时区在该时刻的偏移，生产取
/// `now.toLocal().timeZoneOffset`）。偏移显式传入而不是读进程时区：跑在 UTC 机器上
/// 的测试里 `toLocal()` 与 `toUtc()` 同值，分不出「本地」与「UTC」两种实现。
String leaderboardSharePeriodLabel(
  LeaderboardWindow window,
  DateTime now, {
  required Duration localOffset,
}) => switch (window) {
  LeaderboardWindow.week => leaderboardShareWindowStart(window, now)!,
  LeaderboardWindow.month => leaderboardShareWindowStart(
    window,
    now,
  )!.substring(0, 7),
  LeaderboardWindow.all => _shareDateKey(now.toUtc().add(localOffset)),
};

/// 从服务端取 [window] 周期内的读完数与字数，组装卡片数据。
///
/// 周 / 月：数书架里读完日期落在周期内的作品，字数取同周期字数榜的 `me`。
/// 总：读完数与字数取用户卡片的累计值（不受翻页上限影响），书架只取一页做封面。
/// [localOffset] 只影响「总」的截至日期（见 [leaderboardSharePeriodLabel]），缺省取
/// 用户时区在 [now] 时刻的偏移。
Future<LeaderboardShareCardData> loadLeaderboardShareCardData(
  LeaderboardClient client,
  LeaderboardAccount self, {
  LeaderboardWindow window = LeaderboardWindow.month,
  DateTime? now,
  Duration? localOffset,
}) async {
  final DateTime at = now ?? DateTime.now();
  final String? start = leaderboardShareWindowStart(window, at);
  int finished = 0;
  final List<LeaderboardWork> covers = <LeaderboardWork>[];
  String? cursor;
  bool reachedOlder = false;
  final int maxPages = start == null ? 1 : kLeaderboardShareMaxPages;
  for (int i = 0; i < maxPages && !reachedOlder; i++) {
    final ShelfPage page = await client.userShelf(self.id, cursor: cursor);
    for (final ShelfItem item in page.rows) {
      if (start != null) {
        final String? date =
            item.finishedDate ??
            (item.finishedAt == null
                ? null
                : leaderboardDate(item.finishedAt!));
        // 书架按读完时刻倒序：第一次看到早于周期起点的就可以停了；日期未知的排在最后。
        if (date == null || date.compareTo(start) < 0) {
          reachedOlder = true;
          break;
        }
        finished++;
      }
      if (covers.length < kLeaderboardShareMaxCovers &&
          item.work.cover != null &&
          !item.work.nsfw) {
        covers.add(item.work);
      }
    }
    cursor = page.next;
    if (cursor == null) break;
  }
  final int chars;
  if (start == null) {
    final UserCard card = await client.user(self.id);
    int standing(LeaderboardMetric m) => card.stats[m.wire]?.value ?? 0;
    finished = kLeaderboardShareWorkMetrics.fold<int>(
      0,
      (int sum, LeaderboardMetric m) => sum + standing(m),
    );
    chars = standing(LeaderboardMetric.chars);
  } else {
    final RankPage rank = await client.rank(
      metric: LeaderboardMetric.chars,
      window: window,
      limit: 1,
    );
    chars = rank.me?.value ?? 0;
  }
  return LeaderboardShareCardData(
    accountTag: self.tag,
    window: window,
    periodLabel: leaderboardSharePeriodLabel(
      window,
      at,
      localOffset: localOffset ?? at.toLocal().timeZoneOffset,
    ),
    finishedCount: finished,
    chars: chars,
    covers: List<LeaderboardWork>.unmodifiable(covers),
  );
}

/// 卡片本体（固定宽度，高度随内容）。
class LeaderboardShareCard extends StatelessWidget {
  const LeaderboardShareCard({required this.data, super.key});

  final LeaderboardShareCardData data;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 分享卡底用中性卡片面（MD3 surfaceContainerHigh / Apple 二级分组底），
    // 不再整卡 primaryContainer：封面本身已经够彩，彩底只会和封面打架。
    final bool glass = isGlassDesign(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color background = glass
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.search;
    final Color foreground = glass
        ? appleColorsOf(context).label
        : colors.onSurface;
    final TextTheme text = Theme.of(context).textTheme;
    const double gap = 6;
    const double coverWidth = (kLeaderboardShareCardWidth - 32 - gap * 2) / 3;
    return Container(
      width: kLeaderboardShareCardWidth,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            switch (data.window) {
              LeaderboardWindow.week => t.leaderboard_share_card_week(
                date: data.periodLabel,
              ),
              LeaderboardWindow.month => t.leaderboard_share_card_month(
                month: data.periodLabel,
              ),
              LeaderboardWindow.all => t.leaderboard_share_card_all(
                date: data.periodLabel,
              ),
            },
            style: text.labelLarge?.copyWith(color: foreground),
          ),
          const SizedBox(height: 4),
          Text(
            switch (data.window) {
              LeaderboardWindow.week => t.leaderboard_share_card_finished_week(
                n: data.finishedCount,
              ),
              LeaderboardWindow.month => t.leaderboard_share_card_finished(
                n: data.finishedCount,
              ),
              LeaderboardWindow.all => t.leaderboard_share_card_finished_all(
                n: data.finishedCount,
              ),
            },
            style: text.headlineSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (data.covers.isNotEmpty)
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                for (final LeaderboardWork w in data.covers)
                  LeaderboardCover(work: w, width: coverWidth),
              ],
            ),
          const SizedBox(height: 12),
          Text(
            t.leaderboard_share_card_chars(n: data.chars),
            style: text.titleMedium?.copyWith(color: foreground),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  data.accountTag,
                  style: text.titleSmall?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
              Text(
                'Fushi',
                style: text.labelMedium?.copyWith(
                  color: foreground,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 把 [boundaryKey] 指向的 [RepaintBoundary] 栅格化成 PNG（真实渲染管线，调用前卡片
/// 必须已布局并绘制过一帧）。
Future<Uint8List> captureLeaderboardShareCardPng(
  GlobalKey boundaryKey, {
  double pixelRatio = kLeaderboardSharePixelRatio,
}) async {
  final RenderObject? object = boundaryKey.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) {
    throw StateError('share card is not laid out');
  }
  final ui.Image image = await object.toImage(pixelRatio: pixelRatio);
  try {
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (bytes == null) throw StateError('share card encoding failed');
    return bytes.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 打开分享卡片对话框（选周期 → 取数 → 预览 → 分享图片 / 复制链接）。
/// [initialWindow] 一般传排行页当前选中的周期。
Future<void> showLeaderboardShareSheet(
  BuildContext context, {
  LeaderboardWindow initialWindow = LeaderboardWindow.month,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext _) =>
      LeaderboardShareDialog(initialWindow: initialWindow),
);

/// 分享对话框本体（公开只为测试直接挂载）。
class LeaderboardShareDialog extends ConsumerStatefulWidget {
  const LeaderboardShareDialog({
    this.initialWindow = LeaderboardWindow.month,
    super.key,
  });

  final LeaderboardWindow initialWindow;

  @override
  ConsumerState<LeaderboardShareDialog> createState() =>
      _LeaderboardShareDialogState();
}

class _LeaderboardShareDialogState
    extends ConsumerState<LeaderboardShareDialog> {
  final GlobalKey _boundary = GlobalKey();
  late LeaderboardWindow _window = widget.initialWindow;

  /// 各周期的取数状态，全部按周期分开存：一个周期的结果 / 失败永远不会被当成另一个
  /// 周期的。显示只看当前周期 [_window] 这一格。
  ///
  /// 已取到的数据：来回切换不重复请求。
  final Map<LeaderboardWindow, LeaderboardShareCardData> _cache =
      <LeaderboardWindow, LeaderboardShareCardData>{};

  /// 最近一次取数失败（重试或取到数据时清掉）。
  final Map<LeaderboardWindow, Object> _errors = <LeaderboardWindow, Object>{};

  /// 进行中的请求：同一周期同时只有一个，切走再切回来复用它而不是再发一次。
  final Map<LeaderboardWindow, Future<void>> _inflight =
      <LeaderboardWindow, Future<void>>{};
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load(_window);
  }

  /// [window] 没有数据、也没有进行中的请求时发一次请求。
  void _load(LeaderboardWindow window) {
    if (_cache.containsKey(window) || _inflight.containsKey(window)) return;
    final LeaderboardService service = ref.read(leaderboardServiceProvider);
    final LeaderboardClient? client = service.client;
    final LeaderboardSelf? self = service.self;
    if (client == null || self == null) return;
    _inflight[window] = _fetch(
      window,
      client,
      self.account,
      DateTime.fromMillisecondsSinceEpoch(service.nowMs()),
    );
  }

  Future<void> _fetch(
    LeaderboardWindow window,
    LeaderboardClient client,
    LeaderboardAccount account,
    DateTime now,
  ) async {
    try {
      final LeaderboardShareCardData data = await loadLeaderboardShareCardData(
        client,
        account,
        window: window,
        now: now,
      );
      if (!mounted) return;
      setState(() {
        _cache[window] = data;
        _errors.remove(window);
      });
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.shareCard', e, st);
      if (mounted) setState(() => _errors[window] = e);
    } finally {
      // 取数必然跨过至少一次 await，这里总在 [_load] 登记之后执行。
      _inflight.remove(window);
    }
  }

  /// 切到 [window]（重试 = 切到当前周期）：上次失败的这一格清掉重取，已有数据或
  /// 请求在途的直接显示 / 等它。
  void _show(LeaderboardWindow window) {
    setState(() {
      _window = window;
      _errors.remove(window);
    });
    _load(window);
  }

  /// 可分享的主页链接（服务端只读网页 `/u/<id>`）；未开启时 null。
  Uri? _shareUrl() {
    final LeaderboardSelf? self = ref.read(leaderboardServiceProvider).self;
    final Uri? base = leaderboardShareBase(ref);
    if (self == null || base == null) return null;
    return LeaderboardClient.shareUserUrl(base, self.account.id);
  }

  Future<void> _share(Uri url) async {
    setState(() => _sharing = true);
    try {
      final Uint8List png = await captureLeaderboardShareCardPng(_boundary);
      await FushiShare.shareFiles(<XFile>[
        XFile.fromData(
          png,
          mimeType: 'image/png',
          name:
              'fushi_leaderboard_${DateTime.now().millisecondsSinceEpoch}.png',
        ),
      ], text: url.toString());
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.shareCardCapture', e, st);
      FushiToast.show(msg: leaderboardErrorText(e));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    ref.watch(leaderboardServiceProvider);
    final Uri? url = _shareUrl();
    final LeaderboardShareCardData? data = _cache[_window];
    final Object? error = _errors[_window];
    // 当前周期有数据 ⇔ 卡片（即 [_boundary]）在树上：分享按钮只认这一条。
    final Widget content;
    if (data != null) {
      content = FittedBox(
        fit: BoxFit.scaleDown,
        child: RepaintBoundary(
          key: _boundary,
          child: LeaderboardShareCard(data: data),
        ),
      );
    } else if (error != null) {
      content = LeaderboardErrorView(
        error: error,
        onRetry: () => _show(_window),
      );
    } else {
      content = const FushiLoadingView();
    }
    return FushiDialogFrame(
      child: FushiModalSheetFrame(
        title: t.leaderboard_header_share,
        leadingIcon: Icons.ios_share,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            LeaderboardChoiceRow<LeaderboardWindow>(
              keyPrefix: 'leaderboard-share-window',
              values: LeaderboardWindow.values,
              selected: _window,
              labelOf: leaderboardWindowLabel,
              onSelected: _show,
            ),
            SizedBox(height: tokens.spacing.gap),
            content,
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
            // 链接不依赖卡片预览：取数失败 / 还在加载时也能先复制。
            KeyedSubtree(
              key: const ValueKey<String>('leaderboard-share-copy-link'),
              child: adaptiveDialogAction(
                context: context,
                onPressed: url == null
                    ? null
                    : () => unawaited(leaderboardCopy(url.toString())),
                child: Text(t.leaderboard_share_copy_link),
              ),
            ),
            KeyedSubtree(
              key: const ValueKey<String>('leaderboard-share-image'),
              child: adaptiveDialogAction(
                context: context,
                isDefaultAction: true,
                onPressed: data == null || url == null || _sharing
                    ? null
                    : () => unawaited(_share(url)),
                child: Text(t.leaderboard_share),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

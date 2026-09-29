// 分享卡片：「本月读完 N 部 + 最多 9 张封面拼图 + 本月字数 + 昵称#」。
//
// 卡片先在对话框里完整渲染出来给用户看（封面图此时已真实加载），用户点「分享」时对
// 同一个 [RepaintBoundary] 直接 `toImage` → PNG → [FushiShare.shareFiles]，附带
// `LeaderboardClient.shareUserUrl` 的主页链接。不走离屏 Overlay：预览即成品。

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
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

/// 统计本月读完数时最多翻几页书架（每页 50；超出按已数到的算，卡片上是「≥」语义
/// 的近似——一个月读完 200 部以上的人不需要精确数字）。
const int kLeaderboardShareMaxPages = 4;

/// 卡片逻辑宽度（输出 PNG = 宽 × [kLeaderboardSharePixelRatio]）。
const double kLeaderboardShareCardWidth = 360;
const double kLeaderboardSharePixelRatio = 3;

/// 卡片数据（纯数据，渲染与取数分离，便于测试）。
@immutable
class LeaderboardShareCardData {
  const LeaderboardShareCardData({
    required this.accountTag,
    required this.monthLabel,
    required this.finishedCount,
    required this.monthChars,
    required this.covers,
  });

  final String accountTag;

  /// `YYYY-MM`。
  final String monthLabel;
  final int finishedCount;
  final int monthChars;

  /// 拼图用的作品（已排除 nsfw，≤ [kLeaderboardShareMaxCovers]）。
  final List<LeaderboardWork> covers;
}

/// 从服务端取本月书架与本月字数，组装卡片数据。
Future<LeaderboardShareCardData> loadLeaderboardShareCardData(
  LeaderboardClient client,
  LeaderboardAccount self, {
  DateTime? now,
}) async {
  final DateTime at = now ?? DateTime.now();
  final String month = '${at.year}-${at.month.toString().padLeft(2, '0')}';
  final String monthStart = '$month-01';
  int finished = 0;
  final List<LeaderboardWork> covers = <LeaderboardWork>[];
  String? cursor;
  bool reachedOlder = false;
  for (int i = 0; i < kLeaderboardShareMaxPages && !reachedOlder; i++) {
    final ShelfPage page = await client.userShelf(self.id, cursor: cursor);
    for (final ShelfItem item in page.rows) {
      final String? date =
          item.finishedDate ??
          (item.finishedAt == null ? null : leaderboardDate(item.finishedAt!));
      // 书架按读完时刻倒序：第一次看到早于本月的就可以停了；日期未知的排在最后。
      if (date == null || date.compareTo(monthStart) < 0) {
        reachedOlder = true;
        break;
      }
      finished++;
      if (covers.length < kLeaderboardShareMaxCovers &&
          item.work.cover != null &&
          !item.work.nsfw) {
        covers.add(item.work);
      }
    }
    cursor = page.next;
    if (cursor == null) break;
  }
  final RankPage chars = await client.rank(
    metric: LeaderboardMetric.chars,
    window: LeaderboardWindow.month,
    limit: 1,
  );
  return LeaderboardShareCardData(
    accountTag: self.tag,
    monthLabel: month,
    finishedCount: finished,
    monthChars: chars.me?.value ?? 0,
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    const double gap = 6;
    const double coverWidth = (kLeaderboardShareCardWidth - 32 - gap * 2) / 3;
    return Container(
      width: kLeaderboardShareCardWidth,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.leaderboard_share_card_month(month: data.monthLabel),
            style: text.labelLarge?.copyWith(color: colors.onPrimaryContainer),
          ),
          const SizedBox(height: 4),
          Text(
            t.leaderboard_share_card_finished(n: data.finishedCount),
            style: text.headlineSmall?.copyWith(
              color: colors.onPrimaryContainer,
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
            t.leaderboard_share_card_chars(n: data.monthChars),
            style: text.titleMedium?.copyWith(color: colors.onPrimaryContainer),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  data.accountTag,
                  style: text.titleSmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
              Text(
                'Fushi',
                style: text.labelMedium?.copyWith(
                  color: colors.onPrimaryContainer,
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

/// 打开分享卡片对话框（取数 → 预览 → 分享）。
Future<void> showLeaderboardShareSheet(BuildContext context) =>
    showAppDialog<void>(
      context: context,
      builder: (BuildContext _) => const _LeaderboardShareDialog(),
    );

class _LeaderboardShareDialog extends ConsumerStatefulWidget {
  const _LeaderboardShareDialog();

  @override
  ConsumerState<_LeaderboardShareDialog> createState() =>
      _LeaderboardShareDialogState();
}

class _LeaderboardShareDialogState
    extends ConsumerState<_LeaderboardShareDialog> {
  final GlobalKey _boundary = GlobalKey();
  LeaderboardShareCardData? _data;
  Object? _error;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final LeaderboardService service = ref.read(leaderboardServiceProvider);
    final LeaderboardClient? client = service.client;
    final LeaderboardSelf? self = service.self;
    if (client == null || self == null) return;
    try {
      final LeaderboardShareCardData data = await loadLeaderboardShareCardData(
        client,
        self.account,
      );
      if (mounted) setState(() => _data = data);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.shareCard', e, st);
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _share() async {
    final LeaderboardSelf? self = ref.read(leaderboardServiceProvider).self;
    final Uri? base = leaderboardShareBase(ref);
    if (self == null || base == null) return;
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
      ], text: LeaderboardClient.shareUserUrl(base, self.account.id).toString());
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
    final LeaderboardShareCardData? data = _data;
    final Widget body;
    if (_error != null) {
      body = LeaderboardErrorView(
        error: _error!,
        onRetry: () {
          setState(() => _error = null);
          unawaited(_load());
        },
      );
    } else if (data == null) {
      body = Padding(
        padding: EdgeInsets.all(tokens.spacing.section),
        child: const Center(child: CircularProgressIndicator()),
      );
    } else {
      body = FittedBox(
        fit: BoxFit.scaleDown,
        child: RepaintBoundary(
          key: _boundary,
          child: LeaderboardShareCard(data: data),
        ),
      );
    }
    return FushiDialogFrame(
      child: FushiModalSheetFrame(
        title: t.leaderboard_share_title,
        leadingIcon: Icons.ios_share,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        body: body,
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
            adaptiveDialogAction(
              context: context,
              isDefaultAction: true,
              onPressed: data == null || _sharing
                  ? null
                  : () => unawaited(_share()),
              child: Text(t.leaderboard_share),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:fushi_core/fushi_core.dart';

/// 网页视频制卡队列「一轮重放」的编排：行的先后、哪一行算失败、哪一行留在待办、出错后
/// 怎么收尾。纯逻辑、不碰 WebView 与数据库（页面把导航 / 重放 / 落库作为回调传进来），
/// 所以这些规则可以脱离页面单测。宿主是内置网页播放器页的 `_runMineQueue`。

/// 把页面导航到某一行所属视频的结果。
enum WebMineNavigateOutcome {
  /// 画面就绪，可以重放这一行。
  ready,

  /// 等满期限仍没到（下架 / 地区限制 / 登录过期）：这个视频本轮到不了。
  timedOut,

  /// 没等完就被叫停（用户回来让位 / 手动停止 / 页面已卸载）：对这一行没有任何结论。
  interrupted,
}

/// 一轮的计数。可变对象由调用方持有：整轮中途抛出时，已经处理完的行数仍然读得到。
class WebMineQueueTally {
  int ok = 0;
  int failed = 0;

  int get done => ok + failed;
}

/// 按视频归组：同一个视频（[WebMineQueueRow.videoKey]）的行排在一起，组内保持入队顺序；
/// 组的先后按各组第一行的入队顺序，页面当前所在的视频（[currentVideoKey]）那一组排最前。
///
/// 换视频是整页导航（站点重载 + 重新对齐字幕轨 / 音轨），按入队顺序跑的话在两集之间来回
/// 入队（A、B、A）就要导航三次；归组后每个视频最多导航一次，当前视频不用导航。
/// 副作用：落卡顺序跟着变成按视频聚合。
List<WebMineQueueRow> groupWebMineRowsByVideo(
  List<WebMineQueueRow> rows, {
  String? currentVideoKey,
}) {
  final Map<String, List<WebMineQueueRow>> groups =
      <String, List<WebMineQueueRow>>{};
  for (final WebMineQueueRow row in rows) {
    (groups[row.videoKey] ??= <WebMineQueueRow>[]).add(row);
  }
  final List<WebMineQueueRow>? current = groups.remove(currentVideoKey);
  return <WebMineQueueRow>[
    ...?current,
    for (final List<WebMineQueueRow> group in groups.values) ...group,
  ];
}

/// 逐行跑 [rows]（应已 [groupWebMineRowsByVideo]），结果记进 [tally]。
///
/// 每一行的结局只有三种：
/// - 成功：[mineRow] 返回 true（行由它自己标 done）。
/// - 失败：[mineRow] 返回 false（原因由它自己写进行里）；导航 [WebMineNavigateOutcome.timedOut]
///   （标 `navigate_timeout`）；或这一行的任何一步抛出（原因是异常文本）。一行抛出**不**中断
///   整轮：记给 [onError]、标失败、接着跑下一行——留成待办的话，一行必抛的卡每次空闲都会
///   重跑到同一处。
/// - 留在待办：还没轮到就停了；导航 [WebMineNavigateOutcome.interrupted]（让位不是这一行的
///   错，从前被误标成 `navigate_timeout`）；抛出时已经在停（页面卸载后的调用本来就会抛，
///   同样不是这一行的错）；所属视频本轮已经超时过一次（同一个到不了的视频不再每行各等
///   一个期限，这些行留给下一轮）。
///
/// [shouldStop] 每行开头与每次抛出后各问一次。[markFailed] 自己抛出时只记给 [onError]。
/// 本函数不向外抛 [navigate] / [mineRow] / [markFailed] 的异常。
Future<void> runWebMineQueueRows({
  required List<WebMineQueueRow> rows,
  required WebMineQueueTally tally,
  required String? Function() currentVideoKey,
  required bool Function() shouldStop,
  required Future<WebMineNavigateOutcome> Function(WebMineQueueRow row)
  navigate,
  required Future<bool> Function(WebMineQueueRow row) mineRow,
  required Future<void> Function(WebMineQueueRow row, String error) markFailed,
  required void Function(Object error, StackTrace stack) onError,
  void Function()? onProgress,
}) async {
  final Set<String> unreachable = <String>{};
  for (final WebMineQueueRow row in rows) {
    if (shouldStop()) return;
    if (unreachable.contains(row.videoKey)) continue;
    bool success;
    try {
      WebMineNavigateOutcome arrived = WebMineNavigateOutcome.ready;
      if (row.videoKey != currentVideoKey()) arrived = await navigate(row);
      switch (arrived) {
        case WebMineNavigateOutcome.interrupted:
          return;
        case WebMineNavigateOutcome.timedOut:
          unreachable.add(row.videoKey);
          await markFailed(row, 'navigate_timeout');
          success = false;
        case WebMineNavigateOutcome.ready:
          success = await mineRow(row);
      }
    } catch (e, st) {
      onError(e, st);
      if (shouldStop()) return;
      try {
        await markFailed(row, '$e');
      } catch (e2, st2) {
        onError(e2, st2);
      }
      success = false;
    }
    if (success) {
      tally.ok++;
    } else {
      tally.failed++;
    }
    onProgress?.call();
  }
}

/// 一轮的骨架：跑 [body]，然后**无论 [body] 是否抛出**依次跑完 [cleanup] 的每一步——某一步
/// 抛出只记给 [onError]，后面的步骤照常执行。返回 [body] 是否正常跑完。本函数不向外抛。
///
/// 调用方在它返回之后做整轮的收尾（交接页换回原档、后台制卡页关页、空闲调度器回到空闲
/// 轮询）。BUG-4792：从前 [body] 一抛，收尾就被跳过。
Future<bool> runWebMineQueueRound({
  required Future<void> Function() body,
  required List<Future<void> Function()> cleanup,
  required void Function(Object error, StackTrace stack) onError,
}) async {
  bool completed = false;
  try {
    await body();
    completed = true;
  } catch (e, st) {
    onError(e, st);
  }
  for (final Future<void> Function() step in cleanup) {
    try {
      await step();
    } catch (e, st) {
      onError(e, st);
    }
  }
  return completed;
}

import 'package:fushi/src/mining/web_mine_idle.dart';
import 'package:fushi_core/fushi_core.dart';

/// 网页视频制卡队列「一轮重放」的编排：行的先后、哪一行算失败、哪一行留在待办、出错后
/// 怎么收尾，以及空闲自动制卡跨轮记住「本次空闲已放弃」的东西。纯逻辑、不碰 WebView 与
/// 数据库（页面把导航 / 重放 / 落库作为回调传进来），所以这些规则可以脱离页面单测。宿主是内置网页播放器页的 `_runMineQueue`。

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

/// [runWebMineQueueRows] 为什么停下。
enum WebMineQueueRowsEnd {
  /// 每一行都轮到了（成功 / 失败 / 所属视频到不了而跳过）。
  drained,

  /// 被叫停（让位 / 手动停止 / 页面卸载）：没轮到的行留在待办。
  stopped,

  /// 某一行抛出：那一行已标失败，其余行留在待办。
  rowThrew,
}

/// 逐行跑 [rows]（应已 [groupWebMineRowsByVideo]），结果记进 [tally]，返回停下的原因。
///
/// 每一行的结局只有三种：
/// - 成功：[mineRow] 返回 true（行由它自己标 done）。
/// - 失败：[mineRow] 返回 false（原因由它自己写进行里）；导航 [WebMineNavigateOutcome.timedOut]
///   （标 `navigate_timeout`）；或这一行的任何一步抛出（原因是异常文本）。
/// - 留在待办：还没轮到就停了；导航 [WebMineNavigateOutcome.interrupted]（让位不是这一行的
///   错，从前被误标成 `navigate_timeout`）；抛出时已经在停（页面卸载后的调用本来就会抛，
///   同样不是这一行的错）；所属视频本轮已经超时过一次（同一个到不了的视频不再每行各等
///   一个期限，[onUnreachable] 把它报给调用方，由 [WebMineIdleGiveUps] 管到本次空闲结束）。
///
/// 一行抛出：记给 [onError]、标这一行失败，然后**结束本轮**（[WebMineQueueRowsEnd.rowThrew]）。
/// 标失败是为了必抛的行不会每次都重跑到同一处；不接着跑是因为抛出的原因分不清是这一行的
/// 还是环境的（临时目录写不进去时每一行都会抛），而失败行没有重试入口——接着跑会把整条
/// 队列逐行标成失败。结束本轮则环境故障一轮最多损失一行，其余行等环境好了还能制卡。
///
/// [shouldStop] 每行开头与每次抛出后各问一次。[markFailed] 自己抛出时只记给 [onError]。
/// 本函数不向外抛 [navigate] / [mineRow] / [markFailed] 的异常。
Future<WebMineQueueRowsEnd> runWebMineQueueRows({
  required List<WebMineQueueRow> rows,
  required WebMineQueueTally tally,
  required String? Function() currentVideoKey,
  required bool Function() shouldStop,
  required Future<WebMineNavigateOutcome> Function(WebMineQueueRow row)
  navigate,
  required Future<bool> Function(WebMineQueueRow row) mineRow,
  required Future<void> Function(WebMineQueueRow row, String error) markFailed,
  required void Function(Object error, StackTrace stack) onError,
  void Function(String videoKey)? onUnreachable,
  void Function()? onProgress,
}) async {
  final Set<String> unreachable = <String>{};
  for (final WebMineQueueRow row in rows) {
    if (shouldStop()) return WebMineQueueRowsEnd.stopped;
    if (unreachable.contains(row.videoKey)) continue;
    bool success;
    try {
      WebMineNavigateOutcome arrived = WebMineNavigateOutcome.ready;
      if (row.videoKey != currentVideoKey()) arrived = await navigate(row);
      switch (arrived) {
        case WebMineNavigateOutcome.interrupted:
          return WebMineQueueRowsEnd.stopped;
        case WebMineNavigateOutcome.timedOut:
          unreachable.add(row.videoKey);
          onUnreachable?.call(row.videoKey);
          await markFailed(row, 'navigate_timeout');
          success = false;
        case WebMineNavigateOutcome.ready:
          success = await mineRow(row);
      }
    } catch (e, st) {
      onError(e, st);
      if (shouldStop()) return WebMineQueueRowsEnd.stopped;
      try {
        await markFailed(row, '$e');
      } catch (e2, st2) {
        onError(e2, st2);
      }
      tally.failed++;
      onProgress?.call();
      return WebMineQueueRowsEnd.rowThrew;
    }
    if (success) {
      tally.ok++;
    } else {
      tally.failed++;
    }
    onProgress?.call();
  }
  return WebMineQueueRowsEnd.drained;
}

/// 「本次空闲里已经放弃的东西」：到不了的视频、整本放弃的书。空闲自动制卡一轮结束后
/// 调度器几秒就会再问一次能不能开跑，用户还没回来、待办还在，不记下来就会原样再撞
/// （BUG-4832：到不了的视频每轮再等一个期限、再标一行失败，直到那一集的行全部失败；
/// 窗口宿主档每轮还是一次整页交接）。语义同 `WebMineBackgroundRunner` 的「本次空闲已试过」。
///
/// 进程级（[instance]）、按书记：窗口宿主档的空闲交接每轮都换页面实例，按页记挡不住。
/// 「本次空闲」不靠谁来通知结束，而是查询时现算：记下的那一刻之后整台机器有过输入
/// （系统无输入时长 < 记下至今的时长）就作废。判不了空闲（非 Windows）时一律作废——那里
/// 本来也不会自动开跑。
class WebMineIdleGiveUps {
  WebMineIdleGiveUps({
    Duration? Function()? inputIdle,
    Duration Function()? clock,
  }) : _inputIdle = inputIdle ?? systemInputIdleDuration,
       _clock = clock ?? _processClock;

  static final WebMineIdleGiveUps instance = WebMineIdleGiveUps();

  static final Stopwatch _sinceStart = Stopwatch()..start();
  static Duration _processClock() => _sinceStart.elapsed;

  final Duration? Function() _inputIdle;
  final Duration Function() _clock;

  /// bookUid → 记下的时刻。
  final Map<String, Duration> _books = <String, Duration>{};

  /// bookUid → videoKey → 记下的时刻。
  final Map<String, Map<String, Duration>> _videos =
      <String, Map<String, Duration>>{};

  /// 这个视频等满期限仍没到。
  void giveUpVideo(String bookUid, String videoKey) {
    (_videos[bookUid] ??= <String, Duration>{})[videoKey] = _clock();
  }

  /// 这本书本次空闲不再自动开跑（整轮出错 / 某一行抛出 / 只剩到不了的视频）。
  void giveUpBook(String bookUid) {
    _books[bookUid] = _clock();
  }

  bool isBookGivenUp(String bookUid) {
    _dropStale();
    return _books.containsKey(bookUid);
  }

  Set<String> unreachableVideos(String bookUid) {
    _dropStale();
    return <String>{...?_videos[bookUid]?.keys};
  }

  /// 自动一轮要跑的行：[pending] 去掉本次空闲已经到不了的视频的行。
  List<WebMineQueueRow> startable(
    String bookUid,
    List<WebMineQueueRow> pending,
  ) {
    final Set<String> skip = unreachableVideos(bookUid);
    if (skip.isEmpty) return pending;
    return <WebMineQueueRow>[
      for (final WebMineQueueRow row in pending)
        if (!skip.contains(row.videoKey)) row,
    ];
  }

  /// 一轮结束后：[pending]（此刻还在待办的行）全在到不了的视频上 → 没有能跑的了，这本书
  /// 本次空闲不再开跑。
  void settleAfterRound(String bookUid, List<WebMineQueueRow> pending) {
    if (pending.isNotEmpty && startable(bookUid, pending).isEmpty) {
      giveUpBook(bookUid);
    }
  }

  void _dropStale() {
    if (_books.isEmpty && _videos.isEmpty) return;
    final Duration? idle = _inputIdle();
    final Duration now = _clock();
    bool stale(Duration at) => idle == null || idle < now - at;
    _books.removeWhere((String _, Duration at) => stale(at));
    for (final Map<String, Duration> videos in _videos.values) {
      videos.removeWhere((String _, Duration at) => stale(at));
    }
    _videos.removeWhere((String _, Map<String, Duration> v) => v.isEmpty);
  }
}

/// 一轮的骨架：跑 [body]，然后**无论 [body] 是否抛出**依次跑完 [cleanup] 的每一步——某一步
/// 抛出只记给 [onError]，后面的步骤照常执行。返回 [body] 是否正常跑完。本函数不向外抛。
///
/// 调用方在它返回之后做整轮的收尾（交接页换回原档、后台制卡页关页、空闲调度器回到空闲
/// 轮询）。BUG-4829：从前 [body] 一抛，收尾就被跳过。
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

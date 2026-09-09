import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 同一媒体相邻两段间隔不超过这个值就归成同一次会话（与首页活动流的
/// `kActivitySessionGap` 同值：一条纪律，两处消费）。
const Duration kStudySessionGap = Duration(minutes: 30);

/// 删一次会话的**唯一**入口：先让段 uid 在所有在跑的 `StudyClock` 上退役，再删库。
///
/// 顺序不能反。时钟按 uid upsert **绝对值**，删库与退役之间落下的任何一个 tick 都会
/// 把刚写零的行原样写回去——用户删掉「刚刚那次」（有声书在放 / galgame hook 在跑，
/// 段还开着）时必然撞上，表现为「删了又回来」。
/// 页面**不要**直接调 `FushiDatabase.deleteStudySession`。
Future<void> deleteStudySession(FushiDatabase db, StudySession s) async {
  retireStudySegmentUids(s.segmentUids);
  await db.deleteStudySession(
    segmentUids: s.segmentUids.toSet(),
    gameSessionId: s.gameSessionId,
  );
}

/// 一次学习会话（统计页「最近会话」一行）：**派生视图，不落库**。
///
/// 事实只有两处：`study_segments`（一段一行、整点切段、uid 键控）与 `galgame_sessions`
/// （游玩时长；hook 字数走 chars-only 段，两表之间没有外键）。会话 = 同
/// (deviceId, mediaKind, mediaKey) 的相邻段按 [kStudySessionGap] 归并；游戏会话以
/// `galgame_sessions` 行为骨架，吸收时间区间相交的同游戏字数段。
///
/// 删除一次会话 = 它的段按 uid **写零**（`FushiDatabase.deleteStudySession`，与按天删同一
/// 原语：零值是一次新的绝对值写，经 uid LWW 同步自然传到对端；**不**立按身份的墓碑——
/// 那会压死这本书的全部历史）+ 游戏骨架行硬删（游戏统计不出本机，BUG-2221）。
class StudySession {
  StudySession({
    required this.mediaKind,
    required this.mediaKey,
    required this.title,
    required this.format,
    required this.deviceId,
    required this.startAt,
    required this.endAt,
    required this.durationMs,
    required this.chars,
    required this.pages,
    required List<String> segmentUids,
    this.gameSessionId,
  }) : segmentUids = List<String>.unmodifiable(segmentUids);

  final String mediaKind;
  final String mediaKey;

  /// 展示快照（段的 title / 游戏当前显示名）；空串时展示层回退 [mediaKey]。
  final String title;
  final String format;
  final String deviceId;
  final int startAt;
  final int endAt;
  final int durationMs;
  final int chars;
  final int pages;

  /// 组成本会话的段 uid（删除时写零的行集）。
  final List<String> segmentUids;

  /// 游戏会话的骨架行 `galgame_sessions.id`（删除时硬删）；非游戏为 null。
  final int? gameSessionId;

  bool get isBook => mediaKind == kActivityMediaBook;
  bool get isVideo => mediaKind == kActivityMediaVideo;
  bool get isGame => mediaKind == kActivityMediaGame;

  /// 展示 / 删除的稳定键（同一派生结果内唯一）。
  String get key => gameSessionId != null
      ? 'game:$gameSessionId'
      : 'seg:${segmentUids.first}';
}

bool _isZero(StudySegmentRow s) =>
    s.durationMs <= 0 && s.chars <= 0 && s.pages <= 0;

/// 这一段属于「骨架窗口之外的游玩会话」吗？
///
/// 游戏会话的时长只存在于 `galgame_sessions` 骨架行上；hook 记的字数段 `durationMs`
/// 恒为 0。调用方按 `kRecentGameSessionsLimit` 截断骨架，所以更早的游玩会话**没有**
/// 骨架行——它的字数段若掉进通用归并，产出的是「0 分钟、只有字数」的孤儿会话，
/// 用户往下翻过那条线之后整片都是它们。窗口之外不做游戏会话，比做一个假的好。
bool _outsideGameSkeleton(StudySegmentRow s, int? windowStartAt) =>
    windowStartAt != null &&
    s.mediaKind == kActivityMediaGame &&
    s.startAt < windowStartAt;

/// 从事实派生会话列表，按结束时刻倒序。
///
/// [segments] 写零的行（用户已删）不进任何会话；legacy 日行没有 uid、没有起止时刻，
/// 本来就不在这里——会话流只覆盖 v92 之后的数据。
List<StudySession> deriveStudySessions({
  required List<StudySegmentRow> segments,
  List<GalgameSessionRow> gameSessions = const <GalgameSessionRow>[],
  Map<String, String> gameNamesById = const <String, String>{},
  Duration gap = kStudySessionGap,
}) {
  final List<StudySession> out = <StudySession>[];
  final Set<String> absorbed = <String>{};

  // 1) 游戏骨架：galgame_sessions 一行一会话，吸收区间相交的同游戏字数段。
  for (final GalgameSessionRow g in gameSessions) {
    final List<StudySegmentRow> hits = <StudySegmentRow>[
      for (final StudySegmentRow s in segments)
        if (s.mediaKind == kActivityMediaGame &&
            s.mediaKey == g.gameId &&
            !_isZero(s) &&
            s.startAt < g.endMs &&
            s.endAt > g.startMs)
          s,
    ];
    int chars = 0;
    for (final StudySegmentRow s in hits) {
      chars += s.chars;
      absorbed.add(s.uid);
    }
    out.add(
      StudySession(
        mediaKind: kActivityMediaGame,
        mediaKey: g.gameId,
        title: gameNamesById[g.gameId] ??
            (hits.isEmpty ? '' : hits.first.title),
        format: '',
        deviceId: hits.isEmpty ? '' : hits.first.deviceId,
        startAt: g.startMs,
        endAt: g.endMs,
        durationMs: g.durationSeconds * 1000,
        chars: chars,
        pages: 0,
        segmentUids: <String>[for (final StudySegmentRow s in hits) s.uid],
        gameSessionId: g.id,
      ),
    );
  }

  // 2) 其余段：同 (device, kind, key) 按起始时刻排序，gap 内相邻归并。
  // 骨架窗口的左界：比它更早的游戏段没有骨架行，见 [_outsideGameSkeleton]。
  int? gameWindowStartAt;
  for (final GalgameSessionRow g in gameSessions) {
    if (gameWindowStartAt == null || g.startMs < gameWindowStartAt) {
      gameWindowStartAt = g.startMs;
    }
  }
  final List<StudySegmentRow> rest = <StudySegmentRow>[
    for (final StudySegmentRow s in segments)
      if (!_isZero(s) &&
          !absorbed.contains(s.uid) &&
          !_outsideGameSkeleton(s, gameWindowStartAt))
        s,
  ]..sort((StudySegmentRow a, StudySegmentRow b) {
      final int c = _compareGroup(_groupKey(a), _groupKey(b));
      return c != 0 ? c : a.startAt.compareTo(b.startAt);
    });
  final int gapMs = gap.inMilliseconds;
  _Run? run;
  for (final StudySegmentRow s in rest) {
    if (run != null &&
        run.groupKey == _groupKey(s) &&
        s.startAt - run.endAt <= gapMs) {
      run.add(s);
      continue;
    }
    if (run != null) out.add(run.build());
    run = _Run(s);
  }
  if (run != null) out.add(run.build());

  out.sort((StudySession a, StudySession b) => b.endAt.compareTo(a.endAt));
  return out;
}

/// 归并分组键：record 相等 / 比较按三段身份逐字段，不拼字符串（拼接分隔符要么撞
/// 身份字符集，要么得写 NUL——源码含裸 NUL 会被 git 判 binary）。
typedef _GroupKey = (String deviceId, String mediaKind, String mediaKey);

_GroupKey _groupKey(StudySegmentRow s) => (s.deviceId, s.mediaKind, s.mediaKey);

int _compareGroup(_GroupKey a, _GroupKey b) {
  final int d = a.$1.compareTo(b.$1);
  if (d != 0) return d;
  final int k = a.$2.compareTo(b.$2);
  if (k != 0) return k;
  return a.$3.compareTo(b.$3);
}

class _Run {
  _Run(StudySegmentRow first)
      : groupKey = _groupKey(first),
        first = first,
        endAt = first.endAt {
    add(first);
  }

  final _GroupKey groupKey;
  final StudySegmentRow first;
  int endAt;
  int durationMs = 0;
  int chars = 0;
  int pages = 0;
  final List<String> uids = <String>[];
  String title = '';

  void add(StudySegmentRow s) {
    if (s.endAt > endAt) endAt = s.endAt;
    durationMs += s.durationMs;
    chars += s.chars;
    pages += s.pages;
    uids.add(s.uid);
    // 最新一段的 title 快照最接近当前显示名。
    if (s.title.isNotEmpty) title = s.title;
  }

  StudySession build() => StudySession(
        mediaKind: first.mediaKind,
        mediaKey: first.mediaKey,
        title: title,
        format: first.format,
        deviceId: first.deviceId,
        startAt: first.startAt,
        endAt: endAt,
        durationMs: durationMs,
        chars: chars,
        pages: pages,
        segmentUids: uids,
      );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/stats/study_sessions.dart';
import 'package:fushi_core/fushi_core.dart';

/// 会话流的派生契约（用户 2026-09-08：每个域都要会话级统计，能删误点的会话）：
///  * 同 (device, kind, key) 相邻段按 [kStudySessionGap] 归并，跨媒体 / 跨设备不并；
///  * 写零的段（已删）不进任何会话；
///  * 游戏会话以 galgame_sessions 行为骨架，吸收区间相交的同游戏字数段；未被吸收的
///    游戏段仍按通用规则成会话（hook 字数没有配到游玩记录时不丢）；
///  * 输出按结束时刻倒序；[StudySession.segmentUids] 正是删除时要写零的行集。
StudySegmentRow _seg(
  String uid, {
  String kind = kActivityMediaBook,
  String key = 'b1',
  String device = 'dev',
  String title = 'T',
  required int start,
  required int end,
  int ms = 0,
  int chars = 0,
  int pages = 0,
}) => StudySegmentRow(
  uid: uid,
  deviceId: device,
  mediaKind: kind,
  mediaKey: key,
  format: '',
  title: title,
  startAt: start,
  endAt: end,
  dateKey: '2026-09-08',
  hour: 12,
  durationMs: ms,
  chars: chars,
  pages: pages,
  updatedAt: end,
);

const int _min = 60 * 1000;

void main() {
  test('相邻段 gap 内归并成一次会话，时长 / 字数 / 页数求和，uid 全收', () {
    final List<StudySession> out = deriveStudySessions(
      segments: <StudySegmentRow>[
        _seg('a', start: 0, end: 10 * _min, ms: 10 * _min, chars: 100),
        _seg('b', start: 15 * _min, end: 20 * _min, ms: 5 * _min, chars: 50),
        _seg('c', start: 60 * _min, end: 70 * _min, ms: 10 * _min, pages: 3),
      ],
    );
    expect(out, hasLength(2));
    final StudySession later = out.first;
    expect(later.startAt, 60 * _min, reason: '按结束时刻倒序，最新在前');
    expect(later.pages, 3);
    expect(later.segmentUids, <String>['c']);
    final StudySession earlier = out.last;
    expect(earlier.startAt, 0);
    expect(earlier.endAt, 20 * _min);
    expect(earlier.durationMs, 15 * _min);
    expect(earlier.chars, 150);
    expect(earlier.segmentUids, <String>['a', 'b']);
    expect(earlier.gameSessionId, isNull);
  });

  test('恰好等于 gap 仍归并；超过 gap 一毫秒就是新会话', () {
    final int gap = kStudySessionGap.inMilliseconds;
    expect(
      deriveStudySessions(
        segments: <StudySegmentRow>[
          _seg('a', start: 0, end: _min, ms: _min),
          _seg('b', start: _min + gap, end: 2 * _min + gap, ms: _min),
        ],
      ),
      hasLength(1),
    );
    expect(
      deriveStudySessions(
        segments: <StudySegmentRow>[
          _seg('a', start: 0, end: _min, ms: _min),
          _seg('b', start: _min + gap + 1, end: 2 * _min + gap, ms: _min),
        ],
      ),
      hasLength(2),
    );
  });

  test('跨媒体 / 跨设备 / 跨种类的段不归并', () {
    final List<StudySession> out = deriveStudySessions(
      segments: <StudySegmentRow>[
        _seg('a', start: 0, end: _min, ms: _min),
        _seg('b', key: 'b2', start: _min, end: 2 * _min, ms: _min),
        _seg('c', device: 'other', start: 2 * _min, end: 3 * _min, ms: _min),
        _seg('d', kind: kActivityMediaVideo, key: 'b1', start: 3 * _min,
            end: 4 * _min, ms: _min),
      ],
    );
    expect(out, hasLength(4));
  });

  test('写零的段（用户已删）不进任何会话，也不把两侧的段粘起来', () {
    final List<StudySession> out = deriveStudySessions(
      segments: <StudySegmentRow>[
        _seg('a', start: 0, end: _min, ms: _min),
        _seg('z', start: 20 * _min, end: 21 * _min), // 全零
        _seg('b', start: 45 * _min, end: 46 * _min, ms: _min),
      ],
    );
    expect(out, hasLength(2), reason: 'a 与 b 相隔 44 分钟 > gap，零段不当桥');
    expect(out.every((StudySession s) => !s.segmentUids.contains('z')), isTrue);
  });

  test('游戏：骨架窗口之前的字数段不产出 0 分钟孤儿会话（kRecentGameSessionsLimit 截断）',
      () {
    // 调用方按 kRecentGameSessionsLimit=200 截断骨架，只传进来最近这一条。
    // 更早的那次游玩没有骨架行，它的 hook 字数段 durationMs 恒为 0：若掉进通用
    // 归并就是一条「0 分钟、只有字数」的假会话，用户翻过 200 条之后整片都是。
    const GalgameSessionRow recent = GalgameSessionRow(
      id: 9,
      gameId: 'g1',
      startMs: 100 * _min,
      endMs: 160 * _min,
      durationSeconds: 3600,
      dateKey: '2026-09-08',
    );
    final List<StudySession> out = deriveStudySessions(
      segments: <StudySegmentRow>[
        _seg('inside', kind: kActivityMediaGame, key: 'g1', start: 110 * _min,
            end: 120 * _min, chars: 500),
        // 骨架窗口之前：属于已被截断的更早那次游玩。
        _seg('older', kind: kActivityMediaGame, key: 'g1', start: 10 * _min,
            end: 20 * _min, chars: 700),
      ],
      gameSessions: const <GalgameSessionRow>[recent],
    );
    expect(out, hasLength(1), reason: '只剩骨架那一条，截断之外不造假会话');
    expect(out.single.gameSessionId, 9);
    expect(out.single.segmentUids, <String>['inside']);
    expect(
      out.any((StudySession s) => s.segmentUids.contains('older')),
      isFalse,
      reason: '骨架窗口之前的游戏段不得变成 0 分钟孤儿会话',
    );
  });

  test('游戏：galgame_sessions 行是骨架，吸收区间相交的同游戏字数段', () {
    const GalgameSessionRow play = GalgameSessionRow(
      id: 7,
      gameId: 'g1',
      startMs: 0,
      endMs: 60 * _min,
      durationSeconds: 3600,
      dateKey: '2026-09-08',
    );
    final List<StudySession> out = deriveStudySessions(
      segments: <StudySegmentRow>[
        _seg('h1', kind: kActivityMediaGame, key: 'g1', start: 5 * _min,
            end: 30 * _min, chars: 800),
        _seg('h2', kind: kActivityMediaGame, key: 'g1', start: 30 * _min,
            end: 59 * _min, chars: 200),
        // 另一游戏、另一时间：不被吸收，自成会话。
        _seg('h3', kind: kActivityMediaGame, key: 'g2', start: 0,
            end: 10 * _min, chars: 50),
        // 同游戏但在游玩记录之后 2 小时：不相交，不被吸收。
        _seg('h4', kind: kActivityMediaGame, key: 'g1', start: 180 * _min,
            end: 190 * _min, chars: 30),
      ],
      gameSessions: const <GalgameSessionRow>[play],
      gameNamesById: const <String, String>{'g1': 'Clannad'},
    );
    expect(out, hasLength(3));
    final StudySession game = out.firstWhere(
      (StudySession s) => s.gameSessionId == 7,
    );
    expect(game.isGame, isTrue);
    expect(game.title, 'Clannad');
    expect(game.durationMs, 3600 * 1000);
    expect(game.chars, 1000);
    expect(game.segmentUids, <String>['h1', 'h2']);
    expect(game.key, 'game:7');
    final StudySession orphan = out.firstWhere(
      (StudySession s) => s.segmentUids.contains('h4'),
    );
    expect(orphan.gameSessionId, isNull, reason: '未配到游玩记录的字数段不丢');
    expect(orphan.durationMs, 0);
    expect(out.any((StudySession s) => s.segmentUids.contains('h3')), isTrue);
  });

  test('没有段的游玩记录也是一条会话（只有时长）', () {
    final List<StudySession> out = deriveStudySessions(
      segments: const <StudySegmentRow>[],
      gameSessions: const <GalgameSessionRow>[
        GalgameSessionRow(
          id: 1,
          gameId: 'g1',
          startMs: 0,
          endMs: _min,
          durationSeconds: 60,
          dateKey: '2026-09-08',
        ),
      ],
    );
    expect(out, hasLength(1));
    expect(out.single.segmentUids, isEmpty);
    expect(out.single.chars, 0);
    expect(out.single.title, '', reason: '游戏已删且无段快照 → 空串，展示层回退 mediaKey');
  });

  test('title 取最新一段的快照（改名后的段覆盖旧名）', () {
    final List<StudySession> out = deriveStudySessions(
      segments: <StudySegmentRow>[
        _seg('a', title: '旧名', start: 0, end: _min, ms: _min),
        _seg('b', title: '新名', start: _min, end: 2 * _min, ms: _min),
      ],
    );
    expect(out.single.title, '新名');
  });
}

import 'package:test/test.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_goal_period.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

/// 反馈 CjIr9RGSCe：字数目标日 / 周二选一。周目标分子 = 本自然周（周一起）学习域
/// 字数，与 [StatWindow.inWeek] / 小组件 [StatWindow.mondayOf] 同一个「本周」。
StatFact _fact(String kind, String dateKey, int chars) => StatFact(
  mediaKind: kind,
  mediaKey: 'k',
  title: '',
  format: '',
  dateKey: dateKey,
  hour: -1,
  ms: 0,
  chars: chars,
  pages: 0,
  lastActiveMs: 0,
);

void main() {
  group('StudyGoalPeriod wire', () {
    test('round-trips every value', () {
      for (final StudyGoalPeriod p in StudyGoalPeriod.values) {
        expect(StudyGoalPeriod.fromWire(p.wire), p);
      }
    });

    test('missing / unknown wire falls back to daily (存量用户行为不变)', () {
      expect(StudyGoalPeriod.fromWire(null), StudyGoalPeriod.daily);
      expect(StudyGoalPeriod.fromWire(''), StudyGoalPeriod.daily);
      expect(StudyGoalPeriod.fromWire('monthly'), StudyGoalPeriod.daily);
    });
  });

  group('studyGoalCharsForWeek', () {
    // 2026-08-29 是周六 → 本周一 = 2026-08-24。
    final StatWindow w = StatWindow(DateTime(2026, 8, 29, 15, 30));
    final List<StatFact> daily = <StatFact>[
      _fact('book', '2026-08-23', 9000), // 上周日：不计
      _fact('book', '2026-08-24', 1000), // 周一
      _fact('video', '2026-08-26', 500), // 字幕字也进学习域
      _fact('game', '2026-08-27', 2000), // 游戏 hook
      _fact('book', '2026-08-29', 300), // 今天
      _fact('book', '2026-08-30', 7777), // 未来日期：不计
    ];

    test('sums Monday..today across all sources', () {
      expect(studyGoalCharsForWeek(daily, w), 1000 + 500 + 2000 + 300);
    });

    test('Monday: only today counts', () {
      final StatWindow monday = StatWindow(DateTime(2026, 8, 24, 9));
      expect(studyGoalCharsForWeek(daily, monday), 1000);
    });

    test('domain is decided by the caller-supplied rows', () {
      final Iterable<StatFact> books = daily.where((StatFact f) => f.isBook);
      expect(studyGoalCharsForWeek(books, w), 1000 + 300);
    });

    test('mondayOf matches weekFromKey', () {
      expect(StatWindow.mondayOf(w.todayKey), w.weekFromKey);
      expect(StatWindow.mondayOf('2026-08-24'), '2026-08-24');
      expect(StatWindow.mondayOf('2026-08-30'), '2026-08-24');
    });
  });
}

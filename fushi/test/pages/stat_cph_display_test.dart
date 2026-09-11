import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/stat_session_list.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';

/// 用户 2026-09-12：统计中心顶部方框与每个会话都要显示阅读速度「每小时多少字」，
/// 排查读速异常。守卫：
///  * [formatStatCphOf]：有字数 + 时长 ≥ 1 分钟样本（BUG-1107 门槛）才给出
///    `N 字/时`，否则 null（调用方不显示该行，不显示 0）；
///  * [statBookCphOf]：总览时段卡的速度只按阅读域切片（视频只计时不计字、游戏
///    hook 只计字不计时，混在一起的「字/时」没有意义）；
///  * [formatStatSessionMeta]：会话行末尾带速度；
///  * 源码守卫：统计中心总览 / 阅读统计页的时段卡都挂 `stat_reading_speed` 行。
StatFact _fact(
  String kind, {
  required String dateKey,
  required int ms,
  required int chars,
}) =>
    StatFact(
      mediaKind: kind,
      mediaKey: 'k-$kind',
      title: kind,
      format: '',
      dateKey: dateKey,
      hour: -1,
      ms: ms,
      chars: chars,
      pages: 0,
      lastActiveMs: 0,
    );

StudySession _session({required int ms, required int chars}) => StudySession(
      mediaKind: kActivityMediaBook,
      mediaKey: 'k',
      title: 'T',
      format: '',
      deviceId: 'dev',
      startAt: 0,
      endAt: ms,
      durationMs: ms,
      chars: chars,
      pages: 0,
      segmentUids: const <String>['u'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  test('formatStatCphOf：字数 / 时长 → 整数字/时；样本不足或无字数 → null', () {
    expect(formatStatCphOf(6000, 30 * 60000), t.stat_speed_cph(n: '12000'));
    expect(formatStatCphOf(1234, 3600000), t.stat_speed_cph(n: '1234'));
    expect(formatStatCphOf(500, 59000), isNull, reason: '不足 1 分钟不外推');
    expect(formatStatCphOf(0, 3600000), isNull, reason: '没读字不显示 0');
    expect(formatStatCphOf(100, 0), isNull);
  });

  test('statBookCphOf：只按阅读域切片、只算时段内的 dateKey', () {
    final List<StatFact> daily = <StatFact>[
      _fact(
        kActivityMediaBook,
        dateKey: '2026-09-12',
        ms: 3600000,
        chars: 8000,
      ),
      _fact(
        kActivityMediaBook,
        dateKey: '2026-09-11',
        ms: 3600000,
        chars: 2000,
      ),
      // 视频：2 小时只计时 200 字字幕；游戏：0 时长 9 万字。混进去速度会被稀释 /
      // 拉爆，必须被切掉。
      _fact(
        kActivityMediaVideo,
        dateKey: '2026-09-12',
        ms: 7200000,
        chars: 200,
      ),
      _fact(kActivityMediaGame, dateKey: '2026-09-12', ms: 0, chars: 90000),
    ];
    expect(
      statBookCphOf(daily, (String k) => k == '2026-09-12'),
      t.stat_speed_cph(n: '8000'),
    );
    expect(
      statBookCphOf(daily, (String _) => true),
      t.stat_speed_cph(n: '5000'),
      reason: '(8000+2000) 字 / 2 小时',
    );
    expect(statBookCphOf(daily, (String k) => k == '2026-09-10'), isNull);
  });

  test('会话行量纲末尾带速度；样本不足时不带', () {
    final String withSpeed = formatStatSessionMeta(
      _session(ms: 20 * 60000, chars: 3000),
    );
    expect(withSpeed, endsWith(t.stat_speed_cph(n: '9000')));
    expect(withSpeed, contains(formatStatChars(3000)));
    final String noSpeed = formatStatSessionMeta(
      _session(ms: 30000, chars: 50),
    );
    expect(noSpeed, isNot(contains('/')), reason: '30 秒样本不外推速度');
  });

  test('源码守卫：总览时段卡按阅读域切片、阅读页时段卡带速度行', () {
    final String center = File(
      'lib/src/pages/implementations/statistics_center_page.dart',
    ).readAsStringSync();
    expect(center, contains('statBookCphOf(_daily, contains)'));
    expect(center, contains('label: t.stat_reading_speed'));

    final String reading = File(
      'lib/src/pages/implementations/reading_statistics_page.dart',
    ).readAsStringSync();
    expect(reading, contains('formatStatCphOf(chars, ms)'));
    expect(reading, contains('label: t.stat_reading_speed'));
    expect(
      reading,
      isNot(contains('t.stat_speed_cph(n: cph.round()')),
      reason: '速度外显只在 stat_shared.formatStatCph 一处',
    );

    final String sessions = File(
      'lib/src/pages/implementations/stat_session_list.dart',
    ).readAsStringSync();
    expect(sessions, contains('formatStatCphOf(s.chars, s.durationMs)'));
  });
}

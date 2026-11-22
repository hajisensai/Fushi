// BUG-4960：统计事实面的派生迁到 Rust（`ffc_stats_derive`）后，与迁移前的 Dart 实现
// 逐条对拍；并钉住读库 + 派生不在调用方 isolate 执行。
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_derive.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:test/test.dart';

import 'stat_facts_parity_seed.dart';

Map<String, Object?> _snapshot(StatFacts f) => <String, Object?>{
  'daily': f.daily.map(statFactJson).toList(),
  'hourly': f.hourly.map(statFactJson).toList(),
  'sessions': f.sessions.map(studySessionJson).toList(),
  'dayTotals': <List<Object?>>[
    for (final StatDayTotal t in f.dayTotals)
      <Object?>[t.dateKey, t.chars, t.ms],
  ],
  'bookDayTotals': <List<Object?>>[
    for (final StatDayTotal t in f.bookDayTotals)
      <Object?>[t.dateKey, t.chars, t.ms],
  ],
  'activity': f.activityRows.map(activityRowJson).toList(),
};

/// JSON 往返一次，让 int / String / null / 嵌套列表与 fixture 同形比较。
Object? _normalize(Object? v) => jsonDecode(jsonEncode(v));

void main() {
  late FushiDatabase db;
  late Map<String, Object?> fixture;

  setUpAll(() {
    fixture =
        jsonDecode(File(kStatParityFixture).readAsStringSync())
            as Map<String, Object?>;
  });

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await seedStatParityDb(db);
  });

  tearDown(() async {
    debugStatFactsInline = false;
    await db.close();
  });

  test('fixture 覆盖了要对拍的形态', () {
    final Map<String, Object?> overview =
        fixture['overview']! as Map<String, Object?>;
    expect((overview['daily']! as List<Object?>).length, greaterThan(400));
    expect((overview['sessions']! as List<Object?>).length, greaterThan(150));
    final List<Object?> sessions = overview['sessions']! as List<Object?>;
    // 游戏骨架会话（带 galgame_sessions.id）与普通归并会话都在。
    expect(
      sessions.any((Object? s) => (s! as List<Object?>)[10] != null),
      isTrue,
    );
    expect(
      sessions.any((Object? s) => (s! as List<Object?>)[10] == null),
      isTrue,
    );
  });

  for (final (String name, Future<StatFacts> Function(FushiDatabase) load)
      in kStatParityScopes) {
    test('$name：与迁移前 Dart 实现逐条相同（后台 isolate 派生）', () async {
      final StatFacts facts = await load(db);
      expect(facts.derivedOnIsolate, kStatFactsIsolateDebugName);
      expect(facts.derivedOnIsolate, isNot(Isolate.current.debugName));
      final Map<String, Object?> got =
          _normalize(_snapshot(facts))! as Map<String, Object?>;
      final Map<String, Object?> want = fixture[name]! as Map<String, Object?>;
      for (final String part in want.keys) {
        expect(got[part], want[part], reason: '$name.$part');
      }
      // 按日合计与日面自洽（总览不再自己遍历日面求和）。
      expect(
        _normalize(<String, Object?>{
          'a': statDayTotalsJson(facts.daily),
          'b': statDayTotalsJson(facts.daily, bookOnly: true),
        }),
        <String, Object?>{'a': got['dayTotals'], 'b': got['bookDayTotals']},
      );
      // 段 / 复习两面共用同一条事实对象（与迁移前同形）。
      final Set<StatFact> daily = facts.daily.toSet();
      expect(
        facts.hourly.where((StatFact f) => f.hour >= 0 && f.mediaKey != ''),
        everyElement(isIn(daily)),
      );
    });
  }

  test('inline 模式（只给 FakeAsync 界面测试用）结果与后台 isolate 相同', () async {
    final StatFacts background = await kStatParityScopes.first.$2(db);
    debugStatFactsInline = true;
    final StatFacts inline = await kStatParityScopes.first.$2(db);
    expect(inline.derivedOnIsolate, Isolate.current.debugName);
    expect(_normalize(_snapshot(inline)), _normalize(_snapshot(background)));
  });
}

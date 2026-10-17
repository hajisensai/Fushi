/// `stats show` 端到端：临时数据目录 + 真实 `FushiDatabase` 插几条 study_segments，
/// 经命令模块跑 `stats show --json`，断言窗口 / 种类过滤与 JSON 形状；另钉用法错误 64
/// 与缺配置 66。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/stats_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 固定「现在」= 2026-10-04 15:30 本地时间（日界 0 点）。
final DateTime _now = DateTime(2026, 10, 4, 15, 30);

StudySegmentsCompanion _segment({
  required String uid,
  required String kind,
  required String key,
  required String title,
  required DateTime start,
  required int minutes,
  int chars = 0,
  int pages = 0,
  String format = '',
}) {
  final DateTime end = start.add(Duration(minutes: minutes));
  return StudySegmentsCompanion.insert(
    uid: uid,
    deviceId: 'dev-test',
    mediaKind: kind,
    mediaKey: key,
    title: title,
    format: Value<String>(format),
    startAt: start.millisecondsSinceEpoch,
    endAt: end.millisecondsSinceEpoch,
    dateKey: FushiDatabase.statDateKeyOf(start),
    hour: start.hour,
    durationMs: Value<int>(minutes * 60000),
    chars: Value<int>(chars),
    pages: Value<int>(pages),
    updatedAt: end.millisecondsSinceEpoch,
  );
}

void main() {
  late Directory tmp;
  late File configFile;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    FushiDatabase.statDayResetHour = 0;
    tmp = await Directory.systemTemp.createTemp('fushi_stats_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final String dataDir = p.join(tmp.path, 'data');
    await ServerConfig.defaults(dataDir: dataDir).save(configFile);
    final ServerPaths paths = ServerPaths(dataDir);
    await paths.ensureLayout();
    final FushiDatabase db = FushiDatabase(paths.support.path);
    for (final StudySegmentsCompanion s in <StudySegmentsCompanion>[
      // 今天：读书 30 分钟 1200 字 + 看视频 20 分钟。
      _segment(
        uid: 'a1',
        kind: kActivityMediaBook,
        key: 'book-1',
        title: '吾輩は猫である',
        start: DateTime(2026, 10, 4, 9),
        minutes: 30,
        chars: 1200,
        format: 'epub',
      ),
      _segment(
        uid: 'v1',
        kind: kActivityMediaVideo,
        key: 'video-1',
        title: 'アニメ 第1話',
        start: DateTime(2026, 10, 4, 10),
        minutes: 20,
        chars: 300,
      ),
      // 3 天前：同一本书 10 分钟 400 字（在 7d 内）。
      _segment(
        uid: 'a2',
        kind: kActivityMediaBook,
        key: 'book-1',
        title: '吾輩は猫である',
        start: DateTime(2026, 10, 1, 21),
        minutes: 10,
        chars: 400,
        format: 'epub',
      ),
      // 20 天前：漫画 15 分钟 12 页（7d 外、30d 内）。
      _segment(
        uid: 'm1',
        kind: kActivityMediaBook,
        key: 'manga-1',
        title: 'よつばと！',
        start: DateTime(2026, 9, 14, 8),
        minutes: 15,
        pages: 12,
        format: 'manga',
      ),
      // 写零的段（被删的会话）不得出现在任何窗口。
      _segment(
        uid: 'z1',
        kind: kActivityMediaBook,
        key: 'book-zero',
        title: 'deleted',
        start: DateTime(2026, 10, 4, 11),
        minutes: 0,
      ),
    ]) {
      await db.upsertStudySegment(s);
    }
    await db.close();
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<int> stats(List<String> args, {File? config}) {
    final StatsModule module = StatsModule(out: out, err: err, clock: () => _now);
    final ArgParser parser = ArgParser();
    module.register(parser);
    final ArgResults results = parser.parse(<String>['stats', ...args]);
    return module.run('stats', results.command!, CliContext(configFile: config ?? configFile, verbose: false));
  }

  Map<String, Object?> json() => jsonDecode(out.toString()) as Map<String, Object?>;

  test('默认 7d：今日 + 3 天前入窗，20 天前与写零段不入', () async {
    expect(await stats(<String>['show', '--json']), 0, reason: err.toString());
    final Map<String, Object?> r = json();
    expect(r['window'], '7d');
    expect(r['from'], '2026-09-28');
    expect(r['to'], '2026-10-04');
    expect(r['kind'], 'all');
    expect(r['totals'], <String, Object?>{'ms': 60 * 60000, 'chars': 1900, 'pages': 0, 'activeDays': 2, 'sessions': 3});
    expect(r['byKind'], <String, Object?>{
      'book': <String, Object?>{'ms': 40 * 60000, 'chars': 1600, 'pages': 0},
      'video': <String, Object?>{'ms': 20 * 60000, 'chars': 300, 'pages': 0},
    });
    expect((r['byDay']! as List<Object?>).map((Object? d) => (d! as Map<String, Object?>)['date']), <String>[
      '2026-10-01',
      '2026-10-04',
    ]);
    final List<Object?> media = r['media']! as List<Object?>;
    expect((media.first! as Map<String, Object?>)['key'], 'book-1');
    expect((media.first! as Map<String, Object?>)['chars'], 1600);
    expect(media.map((Object? m) => (m! as Map<String, Object?>)['key']), isNot(contains('book-zero')));
    final List<Object?> sessions = r['sessions']! as List<Object?>;
    expect(sessions, hasLength(3));
    expect(
      (sessions.first! as Map<String, Object?>).keys,
      containsAll(<String>['kind', 'key', 'title', 'startAt', 'endAt', 'ms', 'chars', 'pages']),
    );
  });

  test('--window 30d --kind read：只算书域，含 20 天前的漫画页数', () async {
    expect(await stats(<String>['show', '--window', '30d', '--kind', 'read', '--json']), 0, reason: err.toString());
    final Map<String, Object?> r = json();
    expect(r['kind'], 'read');
    expect(r['from'], '2026-09-05');
    expect(r['totals'], containsPair('ms', 55 * 60000));
    expect(r['totals'], containsPair('pages', 12));
    expect((r['byKind']! as Map<String, Object?>).keys, <String>['book']);
  });

  test('--window today --kind watch', () async {
    expect(await stats(<String>['show', '-w', 'today', '-k', 'watch', '--json']), 0, reason: err.toString());
    expect(json()['totals'], containsPair('ms', 20 * 60000));
  });

  test('统计日界跟偏好 stats_day_reset_hour：重置时刻前仍属「昨日」', () async {
    // 日界 = 16 点、现在 15:30 → 统计上的今日是 10-03；10-04 写下的段落在今日之后不入窗。
    final ServerPaths paths = ServerPaths(p.join(tmp.path, 'data'));
    final FushiDatabase db = FushiDatabase(paths.support.path);
    await db.setPref(kStatDayResetHourPrefKey, PrefCodec.encode(16));
    await db.close();
    expect(await stats(<String>['show', '-w', 'today', '--json']), 0, reason: err.toString());
    final Map<String, Object?> r = json();
    expect(r['dayResetHour'], 16);
    expect(r['to'], '2026-10-03');
    expect(r['totals'], containsPair('ms', 0));
  });

  test('人读输出', () async {
    expect(await stats(<String>['show']), 0, reason: err.toString());
    expect(out.toString(), contains('吾輩は猫である'));
    expect(out.toString(), contains('合计: 1h00m'));
  });

  test('用法错误 = 64', () async {
    expect(await stats(<String>[]), 64);
    expect(await stats(<String>['show', '--window', '14d']), 64);
    expect(await stats(<String>['show', '--kind', 'listen']), 64);
    expect(err.toString(), contains('--kind read'));
    expect(await stats(<String>['show', '--kind', 'cook']), 64);
    expect(await stats(<String>['show', '--sessions', '-1']), 64);
  });

  test('缺配置 = 66', () async {
    expect(await stats(<String>['show'], config: File(p.join(tmp.path, 'missing.yaml'))), 66);
  });
}

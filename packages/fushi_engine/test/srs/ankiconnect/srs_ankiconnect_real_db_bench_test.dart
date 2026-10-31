// 大库基准：AnkiConnect 的 findNotes（冷 / 热）、notesInfo(200)、canAddNotes(50)，以及写一条之后的增量请求，
// 量整次请求耗时与进程 RSS 峰值（相对开始时的增量，与绝对峰值）。
//
// 手动跑（库复制一份再开，原件不动）：
//   FUSHI_SRS_AC_BENCH_DB=<srs.db> FUSHI_SRS_AC_BENCH_TMP=<放副本的目录> [FUSHI_SRS_AC_BENCH_PROFILE=<uid>] \
//     dart tool/heavy.dart -- flutter test test/srs/ankiconnect/srs_ankiconnect_real_db_bench_test.dart
// 不设环境变量时跳过。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';

import '../apkg/apkg_test_support.dart';
import '../support/srs_test_storage.dart';

/// 跑 [f]，交回 (毫秒, 期间 RSS 峰值相对开始时的增量 MB, 结果)。
Future<(int, int, T)> _measure<T>(Future<T> Function() f) async {
  final int base = ProcessInfo.currentRss;
  int peak = base;
  final Timer timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final int r = ProcessInfo.currentRss;
    if (r > peak) peak = r;
  });
  final Stopwatch sw = Stopwatch()..start();
  final T v = await f();
  sw.stop();
  timer.cancel();
  final int r = ProcessInfo.currentRss;
  if (r > peak) peak = r;
  return (sw.elapsedMilliseconds, (peak - base) >> 20, v);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? src = Platform.environment['FUSHI_SRS_AC_BENCH_DB'];
  final String? tmpRoot = Platform.environment['FUSHI_SRS_AC_BENCH_TMP'];
  final String uid =
      Platform.environment['FUSHI_SRS_AC_BENCH_PROFILE'] ??
      '01928c3e-0000-7000-8000-0000000a5e01';
  test(
    '基准：AnkiConnect 大库读动作',
    () async {
      final Directory tmp = Directory(
        tmpRoot ?? Directory.systemTemp.path,
      ).createTempSync('srs_ac_');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } on FileSystemException {
          // 句柄晚释放。
        }
      });
      File(src!).copySync('${tmp.path}/srs.db');
      final TestSrs srs = await openTestSrsAt(
        '${tmp.path}/srs.db',
        inline: false,
      );
      final Stopwatch opening = Stopwatch()..start();
      final SrsDbStore store = await SrsDbStore.open(
        db: srs.db,
        core: srs.core,
        profileUid: uid,
        deviceId: 'dev',
        engine: const FakeFsrsEngine(),
        fallbackRolloverHour: () => 4,
      );
      final SrsAnkiConnectHandler h = SrsAnkiConnectHandler(
        store: () async => store,
        instanceId: 'bench',
      );
      Future<Object?> ok(String action, Map<String, Object?> params) async {
        final Map<String, Object?> r =
            (await h.handle(<String, Object?>{
                  'action': action,
                  'version': 6,
                  'params': params,
                }))
                as Map<String, Object?>;
        if (r['error'] != null) throw StateError('$action: ${r['error']}');
        return r['result'];
      }

      void report(String label, int ms, int mb) => stdout.writeln(
        'BENCH $label ${ms}ms +${mb}MB maxRss=${ProcessInfo.maxRss >> 20}MB',
      );

      final int rss0 = ProcessInfo.currentRss >> 20;
      // 含本机缓存修订号升级（老库第一次打开时的补算，如 v15 的 dupe_norm）。
      stdout.writeln(
        'BENCH open ${opening.elapsedMilliseconds}ms rss after open ${rss0}MB',
      );
      List<Object?> notes = const <Object?>[];
      for (int i = 0; i < 2; i++) {
        final (int ms, int mb, Object? ids) = await _measure(
          () => ok('findNotes', <String, Object?>{'query': 'deck:*'}),
        );
        notes = ids! as List<Object?>;
        report('findNotes(deck:*)#$i n=${notes.length}', ms, mb);
      }
      List<Object?> info = const <Object?>[];
      for (int i = 0; i < 2; i++) {
        final (int ms, int mb, Object? r) = await _measure(
          () => ok('notesInfo', <String, Object?>{
            'notes': notes.take(200).toList(),
          }),
        );
        info = r! as List<Object?>;
        report('notesInfo(200)#$i', ms, mb);
      }
      final Map<String, Object?> first = (info.first! as Map)
          .cast<String, Object?>();
      final String model = first['modelName']! as String;
      final Map<String, Object?> fields = (first['fields']! as Map)
          .cast<String, Object?>();
      final String field = fields.entries
          .firstWhere(
            (MapEntry<String, Object?> e) => (e.value! as Map)['order'] == 0,
          )
          .key;
      final String deck =
          ((await ok('deckNames', <String, Object?>{}))! as List<Object?>)
              .cast<String>()
              .first;
      Map<String, Object?> note(String word) => <String, Object?>{
        'deckName': deck,
        'modelName': model,
        'fields': <String, Object?>{field: word},
        'options': <String, Object?>{
          'allowDuplicate': false,
          'duplicateScope': 'collection',
        },
      };
      final List<Object?> candidates = <Object?>[
        for (int i = 0; i < 25; i++)
          note(
            ((((info[i]! as Map)['fields']! as Map)[field]! as Map)['value'])!
                as String,
          ),
        for (int i = 0; i < 25; i++) note('新語$i'),
      ];
      for (int i = 0; i < 2; i++) {
        final (int ms, int mb, Object? r) = await _measure(
          () => ok('canAddNotes', <String, Object?>{'notes': candidates}),
        );
        final List<Object?> can = r! as List<Object?>;
        report(
          'canAddNotes(50)#$i dup=${can.where((Object? b) => b == false).length}',
          ms,
          mb,
        );
      }
      // 浏览会话释放之后（端点停了又起）：查重不该再为它整份建会话。
      await h.close();
      final (int msCold, int mbCold, Object? _) = await _measure(
        () => ok('canAddNotes', <String, Object?>{'notes': candidates}),
      );
      report('canAddNotes(50) after close', msCold, mbCold);
      final (int msAdd, int mbAdd, Object? _) = await _measure(
        () => ok('addNote', <String, Object?>{'note': note('追加の語')}),
      );
      report('addNote', msAdd, mbAdd);
      final (int ms5, int mb5, Object? _) = await _measure(
        () => ok('findNotes', <String, Object?>{'query': 'deck:*'}),
      );
      report('findNotes(deck:*) after addNote', ms5, mb5);
      final (int ms6, int mb6, Object? _) = await _measure(
        () => ok('canAddNotes', <String, Object?>{'notes': candidates}),
      );
      report('canAddNotes(50) after addNote', ms6, mb6);
    },
    skip: src == null ? 'FUSHI_SRS_AC_BENCH_DB 未设' : null,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}

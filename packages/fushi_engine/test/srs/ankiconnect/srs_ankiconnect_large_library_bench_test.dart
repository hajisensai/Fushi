// AnkiConnect 兼容层在大库上的端到端耗时（手动跑；默认跳过）。
//
// FUSHI_SRS_AC_BENCH=<笔记数> dart test test/srs/ankiconnect/srs_ankiconnect_large_library_bench_test.dart
//
// 库开在临时文件上、走 createInBackground（与 app 同一种连接）。量的是 handler.handle 的整次
// 请求耗时（含 FFI、拷贝、数据库往返），按 Yomitan 的实际调用顺序：查重 → 查笔记 → 加卡 → 再查。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:test/test.dart';

import '../support/srs_bulk_fixture.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final String? n = Platform.environment['FUSHI_SRS_AC_BENCH'];

  test(
    'AnkiConnect 大库端到端耗时',
    () async {
      final int notes = int.parse(n!);
      final BulkFixture f = await BulkFixture.open(
        notes: notes,
        background: true,
      );
      final SrsAnkiConnectHandler h = SrsAnkiConnectHandler(
        store: () async => f.store,
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

      final String model =
          ((await ok('modelNames', <String, Object?>{}))! as List<Object?>)
              .cast<String>()
              .firstWhere((String m) => m.startsWith('Basic'));
      final List<String> fields =
          ((await ok('modelFieldNames', <String, Object?>{'modelName': model}))!
                  as List<Object?>)
              .cast<String>();
      Map<String, Object?> note(String word) => <String, Object?>{
        'deckName': 'Lang',
        'modelName': model,
        'fields': <String, Object?>{fields[0]: word, fields[1]: '例文'},
        'tags': <String>['yomitan'],
        'options': <String, Object?>{
          'allowDuplicate': false,
          'duplicateScope': 'collection',
        },
      };
      List<Map<String, Object?>> batch(String prefix, int k) =>
          <Map<String, Object?>>[for (int i = 0; i < k; i++) note('$prefix$i')];

      final List<String> lines = <String>[];
      Future<T> timed<T>(String label, Future<T> Function() body) async {
        final Stopwatch sw = Stopwatch()..start();
        final T r = await body();
        lines.add('${label.padRight(44)} ${sw.elapsedMilliseconds} ms');
        return r;
      }

      await timed(
        'canAddNotes x10 (cold)',
        () => ok('canAddNotes', <String, Object?>{
          'notes': <Object?>[...batch('語', 5), ...batch('新語', 5)],
        }),
      );
      for (int i = 0; i < 3; i++) {
        await timed(
          'canAddNotes x10 (warm #$i)',
          () => ok('canAddNotes', <String, Object?>{
            'notes': batch('warm$i-', 10),
          }),
        );
      }
      await timed(
        'findNotes "${fields[0]}:語12" (first search)',
        () => ok('findNotes', <String, Object?>{'query': '"${fields[0]}:語12"'}),
      );
      await timed(
        'findNotes "${fields[0]}:語13" (repeat)',
        () => ok('findNotes', <String, Object?>{'query': '"${fields[0]}:語13"'}),
      );
      await timed(
        'findNotes deck:Lang is:due',
        () => ok('findNotes', <String, Object?>{'query': 'deck:Lang is:due'}),
      );
      await timed(
        'addNote x1',
        () => ok('addNote', <String, Object?>{'note': note('単発')}),
      );
      await timed(
        'canAddNotes x10 (after addNote)',
        () => ok('canAddNotes', <String, Object?>{'notes': batch('後', 10)}),
      );
      await timed(
        'findNotes "${fields[0]}:単発" (after addNote)',
        () => ok('findNotes', <String, Object?>{'query': '"${fields[0]}:単発"'}),
      );
      final List<Object?> added =
          (await timed(
                'addNotes x20',
                () =>
                    ok('addNotes', <String, Object?>{'notes': batch('一括', 20)}),
              ))!
              as List<Object?>;
      expect(added.whereType<int>(), hasLength(20));
      final List<int> cards =
          ((await timed(
                    'findCards tag:bench (all)',
                    () => ok('findCards', <String, Object?>{
                      'query': 'tag:bench',
                    }),
                  ))!
                  as List<Object?>)
              .cast<int>();
      final List<int> some = cards.take(100).toList();
      await timed(
        'cardsInfo x100',
        () => ok('cardsInfo', <String, Object?>{'cards': some}),
      );
      final List<int> noteIds =
          ((await ok('cardsToNotes', <String, Object?>{'cards': some}))!
                  as List<Object?>)
              .cast<int>();
      await timed(
        'notesInfo x50',
        () => ok('notesInfo', <String, Object?>{'notes': noteIds}),
      );
      await timed(
        'notesInfo x3 unknown ids',
        () => ok('notesInfo', <String, Object?>{
          'notes': <int>[1, 2, 3],
        }),
      );
      await timed(
        'areSuspended x100',
        () => ok('areSuspended', <String, Object?>{'cards': some}),
      );
      // ignore: avoid_print
      print('BENCH notes=$notes cards=${notes * 2}\n${lines.join('\n')}');
    },
    skip: n == null ? 'set FUSHI_SRS_AC_BENCH' : false,
    timeout: const Timeout(Duration(hours: 1)),
  );
}

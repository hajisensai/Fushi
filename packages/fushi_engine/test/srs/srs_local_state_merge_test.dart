// 收掉 Dart 写路径的第 1.5 步：本机状态行（srs_local_state.json）的合并协议
// （native/fushi_fsrs/src/store/local_state.rs）。Dart `_saveLocal` 与内核写同一条合并 upsert，内核持有的键（白名单，
// 首版为空）不会被 Dart 的整行重写抹掉。这里钉住：两边 SQL 逐字相同；Dart 整行重写仍以交来的为准（白名单为空时行为
// 不变）；写本机状态不多发内核命令（答题路径的命令数守卫靠这一点）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;
import 'support/srs_test_storage.dart';

const String kUid = '01928c3e-0000-7000-8000-00000000d7a5';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('Dart 与内核写本机状态行用同一条合并 upsert', () {
    final String src = File(
      '../../native/fushi_fsrs/src/store/local_state.rs',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    const String head = 'pub(crate) const UPSERT_SQL: &str = "';
    final int from = src.indexOf(head);
    expect(from, greaterThanOrEqualTo(0));
    final String literal = src.substring(
      from + head.length,
      src.indexOf('";', from),
    );
    // Rust 字符串里行尾 `\` 吃掉换行与下一行的前导空白。
    final String rust = literal.replaceAll(RegExp(r'\\\n\s*'), '');
    expect(SrsDbStore.kSrsLocalStateUpsertSql, rust);
  });

  test('白名单为空：整行以 Dart 交来的为准，写本机状态不多发内核命令', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      fallbackRolloverHour: () => 4,
    );
    Future<Map<String, Object?>> row() async {
      final List<String> rows = <String>[
        for (final r
            in await storage.db
                .customSelect('SELECT json FROM srs_local_state')
                .get())
          r.read<String>('json'),
      ];
      expect(rows, hasLength(1));
      return jsonDecode(rows.single) as Map<String, Object?>;
    }

    await s.queueMediaGc(<String>['a.png']);
    expect((await row())['mediaGc'], <Object?>['a.png']);
    // 库里多出一个谁都不持有的键：下一次整行重写把它去掉（与改动前的整行覆盖一致）。
    await storage.db.customStatement(
      r"UPDATE srs_local_state SET json = json_set(json, '$.stray', 1)",
    );
    expect((await row())['stray'], 1);

    final int before = s.debugCoreCommands;
    await s.queueMediaGc(<String>['b.png']);
    expect(s.debugCoreCommands, before);
    final Map<String, Object?> after = await row();
    expect(after.containsKey('stray'), isFalse);
    expect(after['mediaGc'], unorderedEquals(<Object?>['a.png', 'b.png']));
    expect(s.pendingMediaGc, <String>{'a.png', 'b.png'});
  });

  test('本机写命令回包缺 localRevision 是契约错误：抛错、不动内存里的修订号', () async {
    final SrsStorage storage = await openTestSrsStorage();
    final SrsDbStore s = await SrsDbStore.open(
      db: storage.db,
      core: storage.core,
      profileUid: kUid,
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      fallbackRolloverHour: () => 4,
    );
    final int before = s.revision;
    final Map<String, Object?> projected = <String, Object?>{
      'marks': <String, Object?>{'landed': 3},
      'changed': <Object?>[],
    };
    expect(() => s.debugAbsorbLocalWrite(projected), throwsStateError);
    expect(s.revision, before, reason: 'memory untouched on a contract error');
    expect(
      s.debugAbsorbLocalWrite(<String, Object?>{
        ...projected,
        'localRevision': before + 3,
      }),
      3,
    );
    expect(s.revision, before + 3);
    // 真命令（带 localState）的回包都带它：还原点照常落下，修订号与库里的本机状态行一致。
    await s.sync2Checkpoint('m', 'manual');
    final Map<String, Object?> row =
        jsonDecode(
              (await storage.db
                      .customSelect('SELECT json FROM srs_local_state')
                      .getSingle())
                  .read<String>('json'),
            )
            as Map<String, Object?>;
    expect(row['revision'], s.revision);
  });
}

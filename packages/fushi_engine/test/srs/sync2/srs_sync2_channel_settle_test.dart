// 新设备收段通道（native/fushi_fsrs/src/store/sync2/channel.rs）没做完时的本机写入：SrsDbStore 在开 Drift 事务
// 之前先发 `channel_settle`，内核按片做完（每片一个事务），不让写命令在那笔 Drift 事务里把整段做完（内核的兜底
// 路径）。上次 App 在收尾途中退出的通道由打开时的 `identity` 回报。
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsDatabase;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_database_executor.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000ee';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<SrsDbStore> store(SrsDatabase db, SrsCore core) => SrsDbStore.open(
    db: db,
    core: core,
    profileUid: kProfile,
    deviceId: 'B',
    engine: FfiFsrsEngine.tryCreate(),
  );

  Future<String> addNote(SrsDbStore s, String expression) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(kProfile, 'Expression'): expression,
    },
  );

  Future<bool> channelInCore(SrsDbStore s) async =>
      (await s.sync2Command(<String, Object?>{
        'op': 'identity',
        'now': DateTime.now().millisecondsSinceEpoch,
      })).map['channel'] ==
      true;

  test('上次收尾做到一半的通道：打开时回报，第一次本机写入在开事务前先按片做完', () async {
    final Directory dir = Directory.systemTemp.createTempSync('srs_channel_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final String path = p.join(dir.path, 'srs.db');
    // 第一次打开：留下一个折叠到一半的通道（收尾途中 App 被杀），再关库。
    {
      final SrsCore core = SrsCore.open(path);
      final SrsDatabase db = SrsDatabase(srsInlineExecutor(core));
      await store(db, core);
      await db.customStatement(
        'INSERT INTO sync2_boot (profile_uid, phase, next_rank, cursor) '
        "VALUES (srs_id('$kProfile'), 1, 0, 0)",
      );
      await db.close();
      core.close();
    }

    final TestSrs t = await openTestSrsAt(path);
    final SrsDbStore b = await store(t.db, t.core);
    expect(b.debugChannelLive, isTrue);
    expect(await channelInCore(b), isTrue);

    int before = b.debugCoreCommands;
    await addNote(b, '一');
    final int first = b.debugCoreCommands - before;
    expect(b.debugChannelLive, isFalse);
    expect(await channelInCore(b), isFalse);

    before = b.debugCoreCommands;
    await addNote(b, '二');
    final int second = b.debugCoreCommands - before;
    // 多出来的那一条就是开事务前的 `channel_settle`；之后不再发。
    expect(first, second + 1);
  });
}

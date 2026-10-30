import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:path/path.dart' as p;

import '../srs/srs_test_support.dart' show openSrsTestStorage;
import 'temp_dir_cleanup.dart';

/// 备份的两种形态（docs/specs/2026-10-23-srs-rust-store.md §4）。
enum _Shape {
  /// 2026-10-23 之前：srs_* 表在备份主库里（ATTACH 后从 mergesrc 读）。
  legacy,

  /// 新形态：SRS 事件在备份里单独的 srs.db（Rust 打开的副本）。
  split,
}

/// 一份磁盘上的备份：主库路径（ATTACH 用）+ 新形态时 srs.db 副本路径。
typedef _Backup = ({
  String mainPath,
  String? srsPath,
  String uid,
  String noteId,
});

/// 备份合并导入的 SRS 专用步骤（计划铁律 E），走真实的 ATTACH + [BackupMergeEngine.merge]。
///
/// SRS 按 `profiles.uid` 归位：同 uid 直接合并；同名且无用户笔记、未发布则采用备份 uid；
/// 否则新建「<原名>（备份）」。不做 ID 重映射，合并两次幂等。本机 SRS 在 srs.db（Rust），
/// 主库只有 profile 行；老形态与新形态备份走同一套规则。
void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late FushiDatabase target;
  late SrsStorage targetSrs;

  setUp(() async {
    target = FushiDatabase.forTesting(NativeDatabase.memory());
    targetSrs = await openSrsTestStorage();
  });
  tearDown(() => target.close());

  Future<int> insertProfile(FushiDatabase db, String name) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.customStatement(
      'INSERT INTO profiles (name, created_at, updated_at) VALUES (?, ?, ?)',
      <Object>[name, now, now],
    );
    return (await db
            .customSelect(
              'SELECT id FROM profiles WHERE name = ?',
              variables: <Variable<Object>>[Variable<String>(name)],
            )
            .getSingle())
        .read<int>('id');
  }

  Future<String?> uidOfName(FushiDatabase db, String name) async =>
      (await db
              .customSelect(
                'SELECT uid FROM profiles WHERE name = ?',
                variables: <Variable<Object>>[Variable<String>(name)],
              )
              .getSingleOrNull())
          ?.read<String?>('uid');

  Future<String?> ownerOf(String entityId) async =>
      (await targetSrs.db
              .customSelect(
                'SELECT profile_uid FROM srs_entities WHERE id = ?',
                variables: <Variable<Object>>[
                  Variable<String>(entityId, srsIdType),
                ],
              )
              .getSingleOrNull())
          ?.read<String>('profile_uid');

  Future<int> srsCount(String sql) async =>
      (await targetSrs.db.customSelect(sql).getSingle()).read<int>('c');

  Future<int> profileCount() async =>
      (await target
              .customSelect('SELECT COUNT(*) AS c FROM profiles')
              .getSingle())
          .read<int>('c');

  Future<SrsDbStore> store(String uid) => SrsDbStore.open(
    db: targetSrs.db,
    core: targetSrs.core,
    profileUid: uid,
    deviceId: 'dev-target',
  );

  Future<String> addNote(SrsDbStore s, String text) => s.createNote(
    noteTypeId: s.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(s.profileUid, 'Expression'): text,
    },
  );

  /// 磁盘上建备份（ATTACH 需要真文件）：一个名为 [name]、带一条笔记的 profile。
  Future<_Backup> buildBackup(_Shape shape, String name) async {
    final Directory dir = await Directory.systemTemp.createTemp('srs_merge_');
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase src = FushiDatabase(dir.path);
    final int id = await insertProfile(src, name);
    final String uid = await src.profileUidOf(id);
    final SrsStorage srcSrs = await SrsStorage.open(
      path: SrsStorage.pathIn(dir.path),
      inline: true,
    );
    final SrsDbStore s = await SrsDbStore.open(
      db: srcSrs.db,
      core: srcSrs.core,
      profileUid: uid,
      deviceId: 'dev-src',
    );
    final String noteId = await addNote(s, '雪');
    if (shape == _Shape.legacy) {
      // 老形态：同样的行写进备份主库里的旧表。
      for (final MapEntry<String, String> t in kLegacySrsTableDdl.entries) {
        await src.customStatement(t.value);
        // 只抄老表有的列：srs.db 之后加的列（schema v4 的 media_refs 等）老形态里本来就没有。
        final Set<String> legacyCols = <String>{
          for (final QueryRow c
              in await src.customSelect('PRAGMA table_info(${t.key})').get())
            c.read<String>('name'),
        };
        for (final QueryRow r
            in await srcSrs.db.customSelect('SELECT * FROM ${t.key}').get()) {
          final List<String> cols = <String>[
            for (final String c in r.data.keys)
              if (legacyCols.contains(c)) c,
          ];
          await src.customStatement(
            'INSERT INTO ${t.key} (${cols.join(', ')}) '
            'VALUES (${List<String>.filled(cols.length, '?').join(', ')})',
            <Object?>[for (final String c in cols) r.data[c]],
          );
        }
      }
    }
    await srcSrs.close();
    await src.close();
    return (
      mainPath: p.join(dir.path, 'fushi.db'),
      srsPath: shape == _Shape.split ? SrsStorage.pathIn(dir.path) : null,
      uid: uid,
      noteId: noteId,
    );
  }

  Future<void> attachAndMerge(_Backup b) async {
    final String safe = b.mainPath.replaceAll(r'\', '/').replaceAll("'", "''");
    // 新形态：备份 srs.db 的副本由 Rust 打开（与 mergeRestoreBackup 一样，Dart 不碰它）。
    final SrsStorage? source = b.srsPath == null
        ? null
        : await SrsStorage.open(path: b.srsPath!, inline: true);
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    try {
      await BackupMergeEngine(
        target,
        localSrs: targetSrs,
        sourceSrs: source?.db,
      ).merge();
    } finally {
      await target.customStatement('DETACH DATABASE mergesrc');
      await source?.close();
    }
  }

  for (final _Shape shape in _Shape.values) {
    group('${shape.name} 备份', () {
      test('同 uid：并进本机已有 profile，卡片缓存随之生成', () async {
        final _Backup b = await buildBackup(shape, '日语');
        final int localId = await insertProfile(target, '日语');
        await target.adoptProfileUid(localId, b.uid);

        await attachAndMerge(b);

        expect(await ownerOf(b.noteId), b.uid);
        final SrsDbStore s = await store(b.uid);
        expect(
          (await s.note(b.noteId))!.field(srsLapisFieldId(b.uid, 'Expression')),
          '雪',
        );
        expect(await s.cardsOfNote(b.noteId), hasLength(1));
        expect(await uidOfName(target, '日语（备份）'), isNull);
      });

      test('同名、本机无用户笔记且未发布 → 采用备份 uid（含合并时刚按名建出的 profile）', () async {
        final _Backup b = await buildBackup(shape, '日语');
        // 本机没有「日语」：通用路径先按名建出，SRS 步骤再采用备份 uid。
        await attachAndMerge(b);
        expect(await uidOfName(target, '日语'), b.uid);
        expect(await ownerOf(b.noteId), b.uid);
        expect(await uidOfName(target, '日语（备份）'), isNull);
      });

      test('同名、本机打开过 SRS 但无笔记未发布 → 采用备份 uid，旧 uid 行清空', () async {
        final _Backup b = await buildBackup(shape, '日语');
        final int localId = await insertProfile(target, '日语');
        final String oldUid = await target.profileUidOf(localId);
        await store(oldUid); // 只有内置行 + 本机状态

        await attachAndMerge(b);

        expect(await uidOfName(target, '日语'), b.uid);
        expect(await ownerOf(b.noteId), b.uid);
        expect(
          await srsCount(
            'SELECT COUNT(*) AS c FROM srs_entities '
            "WHERE profile_uid = '$oldUid'",
          ),
          0,
        );
        expect(
          await srsCount(
            'SELECT COUNT(*) AS c FROM srs_local_state '
            "WHERE profile_uid = '$oldUid'",
          ),
          0,
        );
      });

      test('同名但本机有用户笔记 → 新建「日语（备份）」，本机数据不动', () async {
        final _Backup b = await buildBackup(shape, '日语');
        final int localId = await insertProfile(target, '日语');
        final String oldUid = await target.profileUidOf(localId);
        final String localNote = await addNote(await store(oldUid), '花');

        await attachAndMerge(b);

        expect(await uidOfName(target, '日语'), oldUid);
        expect(await uidOfName(target, '日语（备份）'), b.uid);
        expect(await ownerOf(localNote), oldUid);
        expect(await ownerOf(b.noteId), b.uid);
        expect(await (await store(b.uid)).cardsOfNote(b.noteId), hasLength(1));
      });

      test('同名但本机发布过批次 → 不改 uid，新建「日语（备份）」', () async {
        final _Backup b = await buildBackup(shape, '日语');
        final int localId = await insertProfile(target, '日语');
        final String oldUid = await target.profileUidOf(localId);
        final SrsDbStore s = await store(oldUid);
        // 同步 v2：传到过任何位置就算发布过（别的设备可能已拿到这个身份下的操作）。
        await srsSync2Round(
          host: s,
          location: SrsMemoryLocationStore(),
          locationId: 'test',
          nowMs: () => s.now().$1,
        );
        final Object? locations = (await s.sync2Status())['locations'];
        expect(
          locations is List &&
              locations.any(
                (Object? l) => l is Map && ((l['uploaded'] as int?) ?? 0) > 0,
              ),
          isTrue,
          reason: '前提：本机确实传出过段',
        );

        await attachAndMerge(b);

        expect(await uidOfName(target, '日语'), oldUid);
        expect(await uidOfName(target, '日语（备份）'), b.uid);
      });

      test('合并两次幂等：profile / 事件 / 卡片数都不变', () async {
        final _Backup b = await buildBackup(shape, '日语');
        final int localId = await insertProfile(target, '日语');
        final String oldUid = await target.profileUidOf(localId);
        await addNote(await store(oldUid), '花');

        await attachAndMerge(b);
        const String events =
            'SELECT (SELECT COUNT(*) FROM srs_entities) * 1000 + '
            '(SELECT COUNT(*) FROM srs_field_edits) AS c';
        final int profiles = await profileCount();
        final int first = await srsCount(events);
        final int cards = await srsCount(
          'SELECT COUNT(*) AS c FROM srs_cards_cache',
        );

        await attachAndMerge(b);

        expect(await profileCount(), profiles);
        expect(await srsCount(events), first);
        expect(
          await srsCount('SELECT COUNT(*) AS c FROM srs_cards_cache'),
          cards,
        );
        expect(await uidOfName(target, '日语（备份）'), b.uid);
        expect(await uidOfName(target, '日语（备份 2）'), isNull);
        expect(await ownerOf(b.noteId), b.uid);
      });
    });
  }

  test('没传本机 SRS 存储（预览等）：SRS 一行不合并', () async {
    final _Backup b = await buildBackup(_Shape.legacy, '日语');
    final String safe = b.mainPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    try {
      await BackupMergeEngine(target).merge();
    } finally {
      await target.customStatement('DETACH DATABASE mergesrc');
    }
    expect(await ownerOf(b.noteId), isNull);
    expect(
      await srsCount('SELECT COUNT(*) AS c FROM srs_entities'),
      0,
      reason: '本机 srs.db 一行都没写',
    );
  });
}

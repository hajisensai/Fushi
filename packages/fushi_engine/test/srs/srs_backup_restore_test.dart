import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_point_in_time_restore.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000b1';

/// 复习自动备份与按时间点恢复（docs/specs/2026-10-17-srs-auto-backup-restore.md）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  int t = DateTime.utc(2026, 10, 17, 9).millisecondsSinceEpoch;
  late SrsMemoryDir dir;
  late Directory tmp;
  final List<FushiDatabase> dbs = <FushiDatabase>[];

  setUp(() async {
    t = DateTime.utc(2026, 10, 17, 9).millisecondsSinceEpoch;
    dir = SrsMemoryDir(() => t);
    tmp = await Directory.systemTemp.createTemp('srs_backup_test_');
  });
  tearDown(() async {
    for (final FushiDatabase db in dbs) {
      await db.close();
    }
    dbs.clear();
    await tmp.delete(recursive: true);
  });

  Future<SrsDbStore> device(String id, {String profile = kProfile}) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    dbs.add(db);
    return SrsDbStore.open(
      db: db,
      profileUid: profile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  SrsBackupStore backups(String device, {String profile = kProfile}) =>
      SrsBackupStore(
        root: Directory(p.join(tmp.path, device, 'srs_backups')),
        profileUid: profile,
        mediaDir: Directory(p.join(tmp.path, device, 'srs_media', profile)),
      );

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        t += 1000;
        await SrsSyncEngine(directory: dir, replica: s).syncOnce();
      }
    }
  }

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');
  String sentence(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Sentence');

  Future<String> addNote(SrsDbStore s, String text) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{expr(s): text, sentence(s): '$text の例文'},
    );
  }

  Future<String> cardOf(SrsDbStore s, String noteId) async =>
      (await s.cardsOfNote(noteId)).single.id;

  Future<void> review(SrsDbStore s, String cardId, int rating) async {
    t += 60 * 1000;
    await s.answer(cardId, rating);
  }

  /// 卡片的可见排程状态（比较恢复前后用）。
  Future<String> stateOf(SrsDbStore s, String cardId) async {
    final SrsCardCacheRow c = (await s.cardRow(cardId))!;
    return '${c.queue}|${c.dueDay}|${c.dueAt}|${c.reps}|${c.lapses}|'
        '${c.suspended}|${c.deckId}';
  }

  Future<bool> alive(SrsDbStore s, String noteId) async =>
      (await s.note(noteId))!.deletedAt == null;

  Future<SrsRestoreReport> restore(
    SrsDbStore s,
    SrsBackupStore bs,
    SrsBackupInfo info,
  ) async {
    final SrsBackupArchive a = await SrsBackupStore.read(info.file);
    try {
      return await bs.restore(s, a);
    } finally {
      a.close();
    }
  }

  test('备份 → 改数据 → 恢复：笔记、字段、标志、卡片状态、复习计数回到备份那一刻', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    final String n2 = await addNote(a, '雨');
    final String n3 = await addNote(a, '風');
    final String c1 = await cardOf(a, n1);
    final String c2 = await cardOf(a, n2);
    final String c3 = await cardOf(a, n3);
    await review(a, c1, 3);
    await a.setSuspended(c2, true);
    final String deck = await a.createDeck('旧牌组');

    t += 60 * 1000;
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.manual,
      profileName: '日语',
      nowMs: t,
    );
    expect(info.manifest.noteCount, 3);
    expect(info.manifest.reviewCount, 1);
    final String c1AtBackup = await stateOf(a, c1);
    final String c2AtBackup = await stateOf(a, c2);
    final String c3AtBackup = await stateOf(a, c3);
    final ({int notes, int cards, int reviews}) countsAtBackup = await a
        .backupCounts();

    // 备份之后的改动。
    await review(a, c1, 1);
    await review(a, c3, 4);
    await a.deleteNote(n1);
    t += 1000;
    await a.updateNote(n2, fieldsById: <String, String>{expr(a): '雨（改）'});
    await a.setSuspended(c2, false);
    final String n4 = await addNote(a, '雷');
    final String newDeck = await a.createDeck('新牌组');
    await a.deleteDeck(deck);
    expect(await stateOf(a, c1), isNot(c1AtBackup));

    t += 60 * 1000;
    final SrsRestoreReport r = await restore(a, bs, info);
    expect(r.logsRevoked, 2, reason: 'c1 的 Again 与 c3 的 Easy');
    expect(r.entitiesDeleted, 2, reason: 'n4 与新牌组');
    expect(r.entitiesRestored, 2, reason: 'n1 与旧牌组');

    expect(await alive(a, n1), isTrue);
    expect((await a.note(n2))!.field(expr(a)), '雨');
    expect(await alive(a, n4), isFalse);
    expect(await stateOf(a, c1), c1AtBackup);
    expect(await stateOf(a, c2), c2AtBackup);
    expect(await stateOf(a, c3), c3AtBackup);
    expect(await a.backupCounts(), countsAtBackup);
    final List<String> decks = <String>[
      for (final SrsDeckSummary d in await a.deckSummaries()) d.deck.id,
    ];
    expect(decks, contains(deck));
    expect(decks, isNot(contains(newDeck)));
    // 恢复写的全是新事件，进发件箱等着发出去。
    expect(await a.unpublishedEvents(), isNotEmpty);

    // 同一份备份再恢复一次：字段已一致，不再写修改记录。
    final SrsRestoreReport again = await restore(a, bs, info);
    expect(again.fieldEdits, 0);
    expect(again.logsRevoked, 0);
    expect(await stateOf(a, c1), c1AtBackup);
  });

  test('两台设备：恢复作为新改动同步出去，对端旧数据不会把它覆盖回来', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    final String n2 = await addNote(a, '雨');
    final String c1 = await cardOf(a, n1);
    final String c2 = await cardOf(a, n2);
    await review(a, c1, 3);
    await syncAll(<SrsDbStore>[a, b]);
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    final String c1AtBackup = await stateOf(a, c1);
    final String c2AtBackup = await stateOf(a, c2);

    // 另一台设备在备份之后：删笔记、改字段、新建笔记、复习。
    await b.deleteNote(n1);
    t += 1000;
    await b.updateNote(n2, fieldsById: <String, String>{expr(b): '雨（B 改）'});
    final String n3 = await addNote(b, '風');
    await review(b, c2, 3);
    await review(b, c1, 1);
    await syncAll(<SrsDbStore>[a, b]);
    expect(await alive(a, n1), isFalse);
    // 对端此刻的全部事件：之后当作「旧副本重新发来的旧数据」再灌一次。
    final List<SrsEvent> staleFromB = await b.exportAll();

    t += 60 * 1000;
    await restore(a, bs, info);
    await syncAll(<SrsDbStore>[a, b]);

    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      expect(await alive(s, n1), isTrue, reason: '${s.deviceId}：被删的笔记恢复');
      expect((await s.note(n2))!.field(expr(s)), '雨');
      expect(await alive(s, n3), isFalse, reason: '备份之后新建的笔记被删除');
      expect(await stateOf(s, c1), c1AtBackup);
      expect(await stateOf(s, c2), c2AtBackup);
      expect(await s.notesPendingDecision(), isEmpty);
      expect(await s.syncConflicts(), isEmpty);
    }

    // 旧数据再来一遍（退役设备回归 / 旧快照）：全部被恢复写下的记录支配，状态不变。
    await a.applyRemote(staleFromB);
    await b.applyRemote(staleFromB);
    await syncAll(<SrsDbStore>[a, b]);
    for (final SrsDbStore s in <SrsDbStore>[a, b]) {
      expect(await alive(s, n1), isTrue);
      expect((await s.note(n2))!.field(expr(s)), '雨');
      expect(await alive(s, n3), isFalse);
      expect(await stateOf(s, c1), c1AtBackup);
      expect(await stateOf(s, c2), c2AtBackup);
    }

    // 恢复之后对端的新改动照常生效（恢复不是「冻结」）。
    t += 60 * 1000;
    await b.updateNote(n2, fieldsById: <String, String>{expr(b): '雨（恢复后）'});
    await review(b, c2, 3);
    await syncAll(<SrsDbStore>[a, b]);
    expect((await a.note(n2))!.field(expr(a)), '雨（恢复后）');
    expect(await stateOf(a, c2), await stateOf(b, c2));
    expect(await stateOf(a, c2), isNot(c2AtBackup));
  });

  test('恢复那一刻还没同步过来的对端改动与恢复并发：复习保留，内容进待裁决', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    final String c1 = await cardOf(a, n1);
    await syncAll(<SrsDbStore>[a, b]);
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    await a.updateNote(n1, fieldsById: <String, String>{expr(a): '雪（A）'});
    // b 离线复习、改同一字段；a 在此期间恢复。
    await review(b, c1, 3);
    await b.updateNote(n1, fieldsById: <String, String>{expr(b): '雪（B）'});
    t += 60 * 1000;
    await restore(a, bs, info);
    expect((await a.note(n1))!.field(expr(a)), '雪');
    await syncAll(<SrsDbStore>[a, b]);
    // b 的复习是恢复看不见的新事件：照常有效，两端一致。
    expect((await a.cardRow(c1))!.reps, 1);
    expect(await stateOf(a, c1), await stateOf(b, c1));
    // b 的字段修改与恢复写的值并发且不同：内容类待裁决，谁也不丢。
    expect((await a.notesPendingDecision()).single.id, n1);
    expect((await b.notesPendingDecision()).single.id, n1);
  });

  test('恢复前自动快照：恢复那份快照就撤回了恢复', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    final String c1 = await cardOf(a, n1);
    final SrsBackupInfo old = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    t += 60 * 1000;
    await review(a, c1, 3);
    final String n2 = await addNote(a, '雨');
    await a.updateNote(n1, fieldsById: <String, String>{expr(a): '雪（新）'});
    final String c1Now = await stateOf(a, c1);
    final Map<String, Object?>? memNow = (await a.preview(
      c1,
    )).memoryBefore?.toJson();
    expect(memNow, isNotNull);

    t += 60 * 1000;
    final SrsBackupInfo pre = await bs.create(
      a,
      kind: SrsBackupKind.preRestore,
      profileName: '日语',
      nowMs: t,
    );
    t += 1000;
    await restore(a, bs, old);
    expect(await alive(a, n2), isFalse);
    expect((await a.cardRow(c1))!.queue, SrsQueue.newCard.wire);

    t += 60 * 1000;
    final SrsRestoreReport r = await restore(a, bs, pre);
    expect(await alive(a, n2), isTrue);
    expect((await a.note(n1))!.field(expr(a)), '雪（新）');
    expect(await stateOf(a, c1), c1Now);
    // 被第一次恢复撤销的复习不能「撤销撤销」，卡片状态靠一条照抄状态的 manual 日志回来。
    expect(r.statesRestored, 1);
    final List<String> kinds = <String>[
      for (final SrsEvent e in await a.exportAll())
        if (e is SrsLogEvent) e.log.kind,
    ];
    expect(kinds, contains(SrsLogKind.manual));
    expect(
      (await bs.list()).map((SrsBackupInfo b) => b.manifest.kind),
      containsAll(<SrsBackupKind>[SrsBackupKind.preRestore]),
    );
    // 撤回后再评分：记忆状态的起点与备份时那张卡相同（照抄的 manual 日志是 S/D 起点，
    // 不因被撤销的评分退回「从零算」）。
    expect((await a.preview(c1)).memoryBefore?.toJson(), memNow);
    t += 24 * 60 * 60 * 1000;
    final SrsReviewLog next = await a.answer(c1, 3);
    expect(next.result!.memory, isNotNull);
    expect(next.result!.reps, 2);
  });

  test('恢复到旧时间点后再评分：记忆状态与备份时那张卡直接评分一致', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    final String c1 = await cardOf(a, n1);
    await review(a, c1, 3);
    await review(a, c1, 3);
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    final Map<String, Object?>? atBackup = (await a.preview(
      c1,
    )).memoryBefore?.toJson();
    await review(a, c1, 1);
    await review(a, c1, 4);
    expect((await a.preview(c1)).memoryBefore?.toJson(), isNot(atBackup));
    t += 60 * 1000;
    await restore(a, bs, info);
    expect((await a.preview(c1)).memoryBefore?.toJson(), atBackup);
  });

  test('恢复用删除优先判定备份时的删除状态（不看排序赢家）', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    await syncAll(<SrsDbStore>[a, b]);
    // b 删除；a 并发地（没看见）写一条「未删除」，排序上 a 的更晚、是赢家，但删除优先 → 已删。
    t += 1000;
    await b.deleteNote(n1);
    t += 5000;
    await a.editField(SrsEntityKind.note, n1, SrsFieldKeys.deleted, null);
    await syncAll(<SrsDbStore>[a, b]);
    expect(await alive(a, n1), isFalse);
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    await a.restoreNote(n1);
    expect(await alive(a, n1), isTrue);
    t += 60 * 1000;
    await restore(a, bs, info);
    expect(await alive(a, n1), isFalse, reason: '备份时是已删');
  });

  test('变化指纹：同一字段连改两次也会变；只读不变', () async {
    final SrsDbStore a = await device('a');
    final String n1 = await addNote(a, '雪');
    final String f0 = await a.changeFingerprint();
    await a.updateNote(n1, fieldsById: <String, String>{expr(a): '雪 1'});
    final String f1 = await a.changeFingerprint();
    await a.updateNote(n1, fieldsById: <String, String>{expr(a): '雪 2'});
    final String f2 = await a.changeFingerprint();
    expect(<String>{f0, f1, f2}, hasLength(3));
    await a.note(n1);
    await a.exportAll();
    expect(await a.changeFingerprint(), f2);
  });

  test('备份导出的规范行与 exportAll 逐字节相同', () async {
    final SrsDbStore a = await device('a');
    final String n1 = await addNote(a, '雪');
    await review(a, await cardOf(a, n1), 3);
    expect(await a.exportCanonicalLines(), <String>[
      for (final SrsEvent e in await a.exportAll()) e.canonical(),
    ]);
  });

  test('恢复中途失败：库与写入者的内存状态都回到恢复前', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    final String n1 = await addNote(a, '雪');
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    await a.updateNote(n1, fieldsById: <String, String>{expr(a): '雪（新）'});
    await addNote(a, '雨');
    final List<String> before = <String>[
      for (final SrsEvent e in await a.exportAll()) e.canonical(),
    ];
    final String applied = srsCanonicalJson(a.appliedContext.toJson());
    final String fp = await a.changeFingerprint();
    final int outbox = (await a.unpublishedEvents()).length;
    final SrsBackupArchive arch = await SrsBackupStore.read(info.file);
    addTearDown(arch.close);
    await expectLater(
      srsRestoreToBackup(
        store: a,
        backupEvents: arch.events,
        backupServerTimes: arch.serverTimes,
        backupId: arch.id,
        debugOnStage: (String stage) async {
          if (stage == 'fields') throw StateError('injected');
        },
      ),
      throwsStateError,
    );
    expect(<String>[
      for (final SrsEvent e in await a.exportAll()) e.canonical(),
    ], before);
    expect(srsCanonicalJson(a.appliedContext.toJson()), applied);
    expect(await a.changeFingerprint(), fp);
    expect((await a.unpublishedEvents()).length, outbox);
    // 之后照常能写、能恢复。
    await restore(a, bs, info);
    expect((await a.note(n1))!.field(expr(a)), '雪');
  });

  test('媒体回收：有读不懂的备份清单时整轮不回收；媒体名拒绝 Windows 保留名与冒号', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    await bs.mediaDir.create(recursive: true);
    File(p.join(bs.mediaDir.path, 'img.png')).writeAsBytesSync(<int>[1, 2, 3]);
    await addNote(a, '雪');
    final SrsBackupInfo b1 = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    // 一份读不懂的「备份」（例如来自更新版本、清单损坏）：它可能引用池里的媒体。
    File(
      p.join(bs.profileDir.path, 'broken.fushisrs'),
    ).writeAsBytesSync(utf8.encode('not a zip'));
    await bs.delete(b1);
    expect(
      bs.mediaPool.listSync().whereType<File>().where(
        (File f) => p.basename(f.path) != 'index.json',
      ),
      hasLength(1),
      reason: '有读不懂的清单时不回收',
    );
    for (final String bad in <String>[
      'CON',
      'nul.png',
      'COM1.mp3',
      'a:b.png',
      'x.png.',
      ' x.png',
    ]) {
      expect(
        SrsBackupMediaEntry.fromJson(<String, Object?>{
          'name': bad,
          'sha256': 'a' * 64,
          'size': 1,
        }),
        isNull,
        reason: bad,
      );
    }
  });

  test('坏文件、非备份文件、新版本备份一律拒绝，库不动', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    await addNote(a, '雪');
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.manual,
      profileName: '日语',
      nowMs: t,
    );

    Future<SrsBackupInvalidReason> reasonOf(File f) async {
      try {
        (await SrsBackupStore.read(f)).close();
      } on SrsBackupFormatException catch (e) {
        return e.reason;
      }
      fail('应当拒绝 ${f.path}');
    }

    final File garbage = File(p.join(tmp.path, 'garbage.fushisrs'))
      ..writeAsBytesSync(utf8.encode('not a zip'));
    expect(await reasonOf(garbage), SrsBackupInvalidReason.notBackup);

    // 原样拆开、改一处再打包。
    final Archive orig = ZipDecoder().decodeBytes(info.file.readAsBytesSync());
    File repack(String name, Map<String, List<int>> replace) {
      final Archive out = Archive();
      for (final ArchiveFile f in orig.files) {
        final List<int> bytes = replace[f.name] ?? f.content as List<int>;
        out.addFile(ArchiveFile(f.name, bytes.length, bytes));
      }
      return File(p.join(tmp.path, name))
        ..writeAsBytesSync(ZipEncoder().encode(out)!);
    }

    final List<int> events =
        orig.findFile('events.jsonl')!.content as List<int>;
    final List<int> tampered = List<int>.of(events)..[10] ^= 0x01;
    expect(
      await reasonOf(
        repack('tampered.fushisrs', <String, List<int>>{
          'events.jsonl': tampered,
        }),
      ),
      SrsBackupInvalidReason.corrupt,
    );

    final Map<String, Object?> manifest =
        (jsonDecode(
                  utf8.decode(
                    orig.findFile('manifest.json')!.content as List<int>,
                  ),
                )
                as Map)
            .cast<String, Object?>();
    manifest['formatVersion'] = 99;
    manifest['minReaderVersion'] = 99;
    expect(
      await reasonOf(
        repack('newer.fushisrs', <String, List<int>>{
          'manifest.json': utf8.encode(jsonEncode(manifest)),
        }),
      ),
      SrsBackupInvalidReason.newerVersion,
    );

    // 只是多了不认识的字段（更新版本、但声明旧版本能读）：照常读。
    manifest['formatVersion'] = 2;
    manifest['minReaderVersion'] = 1;
    manifest['somethingNew'] = <String, Object?>{'x': 1};
    final SrsBackupArchive ok = await SrsBackupStore.read(
      repack('forward.fushisrs', <String, List<int>>{
        'manifest.json': utf8.encode(jsonEncode(manifest)),
      }),
    );
    expect(ok.manifest.noteCount, 1);
    ok.close();

    // 别的 profile 的备份不能恢复进这个 profile。
    final SrsDbStore other = await device('x', profile: 'other-profile');
    final SrsBackupArchive arch = await SrsBackupStore.read(info.file);
    await expectLater(
      backups('x', profile: 'other-profile').restore(other, arch),
      throwsA(isA<SrsRestoreProfileMismatch>()),
    );
    arch.close();
  });

  test('媒体按内容哈希共享；导出的自包含文件能在新设备上完整恢复', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    await bs.mediaDir.create(recursive: true);
    File(p.join(bs.mediaDir.path, 'img.png')).writeAsBytesSync(<int>[1, 2, 3]);
    File(p.join(bs.mediaDir.path, 'snd.mp3')).writeAsBytesSync(<int>[4, 5]);
    final String n1 = await addNote(a, '雪');
    final SrsBackupInfo b1 = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    t += 60 * 60 * 1000;
    await addNote(a, '雨');
    final SrsBackupInfo b2 = await bs.create(
      a,
      kind: SrsBackupKind.auto,
      profileName: '日语',
      nowMs: t,
    );
    expect(b1.manifest.media, hasLength(2));
    final List<String> pooled = bs.mediaPool
        .listSync()
        .whereType<File>()
        .map((File f) => p.basename(f.path))
        .where((String n) => n != 'index.json')
        .toList();
    expect(pooled, hasLength(2), reason: '两份备份共用同一份媒体');
    expect(b2.totalBytes, greaterThan(b2.fileBytes));

    final File exported = await bs.exportSelfContained(
      b1,
      File(p.join(tmp.path, 'export.fushisrs')),
    );

    // 新设备：同一 profile，什么都没有。
    final SrsDbStore fresh = await device('fresh');
    final SrsBackupStore fs = backups('fresh');
    final SrsBackupArchive arch = await SrsBackupStore.read(exported);
    expect(arch.manifest.mediaEmbedded, isTrue);
    await fs.restore(fresh, arch);
    arch.close();
    expect(await alive(fresh, n1), isTrue);
    expect((await fresh.note(n1))!.field(expr(fresh)), '雪');
    expect(File(p.join(fs.mediaDir.path, 'img.png')).readAsBytesSync(), <int>[
      1,
      2,
      3,
    ]);
    expect(File(p.join(fs.mediaDir.path, 'snd.mp3')).existsSync(), isTrue);
    // 新设备恢复进来的事件进发件箱，会被发布出去。
    expect(
      (await fresh.unpublishedEvents()).map((SrsEvent e) => e.id),
      contains(n1),
    );

    // 删掉全部备份后，没人引用的媒体被回收。
    for (final SrsBackupInfo b in await bs.list()) {
      await bs.delete(b);
    }
    expect(
      bs.mediaPool.listSync().whereType<File>().where(
        (File f) => p.basename(f.path) != 'index.json',
      ),
      isEmpty,
    );
  });

  test('自动清理按保留策略删旧备份；列表从新到旧、指纹反映变动', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    await addNote(a, '雪');
    final String fp1 = await a.changeFingerprint();
    expect(await a.changeFingerprint(), fp1, reason: '只读不改变指纹');
    final DateTime base = DateTime(2026, 10, 17, 12);
    for (int d = 0; d < 6; d++) {
      await bs.create(
        a,
        kind: SrsBackupKind.auto,
        profileName: '日语',
        nowMs: base.subtract(Duration(days: d)).millisecondsSinceEpoch,
      );
    }
    final List<SrsBackupInfo> all = await bs.list();
    expect(all, hasLength(6));
    expect(all.first.manifest.createdAt, base.millisecondsSinceEpoch);
    expect(all.first.manifest.fingerprint, fp1);
    final int removed = await bs.thin(
      limits: const SrsBackupLimits(daily: 2, weekly: 0, monthly: 0),
      now: base,
    );
    // 今天、昨天全留；更早的按天留 2 份。
    expect(removed, 2);
    expect(await bs.list(), hasLength(4));
    await addNote(a, '雨');
    expect(await a.changeFingerprint(), isNot(fp1));
  });

  test('内置笔记类型被改过的项恢复回代码定义；之后才加的字段软删除', () async {
    final SrsDbStore a = await device('a');
    final SrsBackupStore bs = backups('a');
    await addNote(a, '雪');
    final SrsNoteTypeView before = (await a.noteType(a.lapisNoteTypeId))!;
    final SrsBackupInfo info = await bs.create(
      a,
      kind: SrsBackupKind.manual,
      profileName: '日语',
      nowMs: t,
    );
    final SrsFieldDef first = before.fields.first;
    t += 1000;
    await a.editField(
      SrsEntityKind.noteType,
      a.lapisNoteTypeId,
      SrsFieldKeys.fieldDef(first.id),
      first.copyWith(name: '改名').toValue(),
    );
    await a.editField(
      SrsEntityKind.noteType,
      a.lapisNoteTypeId,
      SrsFieldKeys.fieldDef('extra-field'),
      const SrsFieldDef(id: 'extra-field', name: '新字段', ord: 99).toValue(),
    );
    expect(
      (await a.noteType(
        a.lapisNoteTypeId,
      ))!.fields.map((SrsFieldDef f) => f.name),
      containsAll(<String>['改名', '新字段']),
    );
    t += 60 * 1000;
    await restore(a, bs, info);
    final SrsNoteTypeView after = (await a.noteType(a.lapisNoteTypeId))!;
    expect(
      after.fields.map((SrsFieldDef f) => f.name).toList(),
      before.fields.map((SrsFieldDef f) => f.name).toList(),
    );
    expect(srsBuiltinLapis(kProfile).fields.first.name, first.name);
  });
}

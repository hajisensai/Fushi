import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_backup_store.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e5';
const int kDay = 24 * 60 * 60 * 1000;

/// 墓碑物理清除（srs_purge.dart）：安全期、共享媒体、未同步时立即清除、清除后同步 / 备份往返。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  int t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;
  late SrsMemoryDir dir;
  late Directory tmp;

  setUp(() async {
    t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;
    dir = SrsMemoryDir(() => t);
    tmp = await Directory.systemTemp.createTemp('srs_purge_test_');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<SrsDbStore> device(String id) async {
    final SrsStorage srs = await openTestSrsStorage();
    return SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
    );
  }

  Future<void> syncAll(List<SrsDbStore> stores) async {
    for (int round = 0; round < 3; round++) {
      for (final SrsDbStore s in stores) {
        t += 1000;
        await SrsSyncEngine(
          directoryKey: 'test',
          directory: dir,
          replica: s,
        ).syncOnce();
      }
    }
  }

  String expr(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Expression');
  String sentence(SrsDbStore s) => srsLapisFieldId(s.profileUid, 'Sentence');

  Future<String> addNote(
    SrsDbStore s,
    String text, {
    String extra = '',
    String? deckId,
  }) {
    t += 1000;
    return s.createNote(
      noteTypeId: s.lapisNoteTypeId,
      fieldsById: <String, String>{expr(s): text, sentence(s): '$text$extra'},
      deckId: deckId,
    );
  }

  Future<String> cardOf(SrsDbStore s, String noteId) async =>
      (await s.cardsOfNote(noteId)).single.id;

  Future<int> logCount(SrsDbStore s, String cardId) async =>
      (await (s.db.select(
        s.db.srsReviewLogs,
      )..where((r) => r.cardId.equals(cardId))).get()).length;

  Future<int> noteEditCount(SrsDbStore s, String noteId, {String? key}) async =>
      (await (s.db.select(s.db.srsFieldEdits)..where(
                (e) =>
                    e.entityId.equals(noteId) &
                    (key == null
                        ? e.fieldKey.isNotNull()
                        : e.fieldKey.equals(key)),
              ))
              .get())
          .length;

  /// 清除后的笔记：身份记录、正文、缓存、卡都没了，只剩删除寄存器（墓碑）与复习日志。
  Future<void> expectPurged(SrsDbStore s, String noteId, String cardId) async {
    expect(await s.note(noteId), isNull, reason: '身份记录已清');
    expect(await s.cardsOfNote(noteId), isEmpty, reason: '卡片缓存行已清');
    expect(await s.cardRow(cardId), isNull);
    expect(
      await noteEditCount(s, noteId),
      await noteEditCount(s, noteId, key: SrsFieldKeys.deleted),
      reason: '只剩删除寄存器',
    );
    expect(
      await noteEditCount(s, noteId, key: SrsFieldKeys.deleted),
      greaterThan(0),
      reason: '墓碑本身保留',
    );
    expect(
      await (s.db.select(
        s.db.srsNotesCache,
      )..where((n) => n.id.equals(noteId))).get(),
      isEmpty,
      reason: '笔记缓存行已清',
    );
  }

  test('安全期与同步层退役时限一致', () {
    expect(
      kSrsTombstonePurgeAfter.inMilliseconds,
      const SrsSyncOptions().retireAfterMs,
    );
  });

  test('① 同步过的副本：删除发布后安全期内不清，过期后清；未发布的删除不清', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String gone = await addNote(a, '雪');
    final String keep = await addNote(a, '雨');
    final String goneCard = await cardOf(a, gone);
    t += 60 * 1000;
    await a.answer(goneCard, 3);
    await syncAll(<SrsDbStore>[a, b]);
    await a.deleteNote(gone);
    await syncAll(<SrsDbStore>[a, b]); // 删除记录有了服务器时间 S

    t += 89 * kDay;
    SrsPurgeReport r = await srsPurgeExpiredTombstones(a);
    expect(r.notes, 0, reason: '安全期内不清');
    expect((await a.note(gone))!.deletedAt, isNotNull);
    expect(await logCount(a, goneCard), 1);

    t += 2 * kDay;
    r = await srsPurgeExpiredTombstones(a);
    expect(r.notes, 1);
    expect(r.events, greaterThan(0));
    await expectPurged(a, gone, goneCard);
    expect(await logCount(a, goneCard), 1, reason: '复习日志保留：统计里过去的复习不能因为清除而消失');
    expect((await a.note(keep))!.deletedAt, isNull, reason: '没删的笔记不动');

    // 同步过、但删除记录还没发布出去（S 未知）：多久都不清。
    final String unpublished = await addNote(a, '風');
    await syncAll(<SrsDbStore>[a, b]);
    await a.deleteNote(unpublished);
    t += 365 * kDay;
    r = await srsPurgeExpiredTombstones(a);
    expect(r.notes, 0);
    expect((await a.note(unpublished))!.deletedAt, isNotNull);
  });

  test('② 清除后：存活笔记（含已删未清的）引用的共享媒体不删，独占媒体删掉', () async {
    final SrsDbStore a = await device('a');
    final Directory media = Directory(p.join(tmp.path, 'media'))
      ..createSync(recursive: true);
    for (final String n in <String>['shared.png', 'only.mp3', 'trash.png']) {
      File(p.join(media.path, n)).writeAsStringSync(n);
    }
    final String gone = await addNote(
      a,
      '雪',
      extra: '<img src="shared.png">[sound:only.mp3]<img src="trash.png">',
    );
    await addNote(a, '雨', extra: '<img src="Shared.PNG">');
    final String inTrash = await addNote(
      a,
      '風',
      extra: '<img src="trash.png">',
    );
    await a.deleteNote(inTrash); // 已删、不清：可能被恢复，媒体要留着
    await a.deleteNote(gone);
    final String goneCard = await cardOf(a, gone);

    final SrsPurgeReport r = await srsPurgeNotesNow(
      a,
      <String>[gone],
      mediaRoot: media,
      mediaGrace: Duration.zero,
    );
    expect(r.notes, 1);
    expect(r.mediaFiles, 1);
    await expectPurged(a, gone, goneCard);
    expect(File(p.join(media.path, 'only.mp3')).existsSync(), isFalse);
    expect(
      File(p.join(media.path, 'shared.png')).existsSync(),
      isTrue,
      reason: '存活笔记引用（大小写不同也算）',
    );
    expect(
      File(p.join(media.path, 'trash.png')).existsSync(),
      isTrue,
      reason: '回收站里的笔记还可能恢复',
    );
    expect((await a.note(inTrash))!.deletedAt, isNotNull);
  });

  test('③ 从没同步过：删牌组连卡片后可当场清除；同步过的副本拒绝当场清除', () async {
    final SrsDbStore a = await device('a');
    expect(a.neverSynced, isTrue);
    final String deck = await a.ensureDeckPath('N3');
    final String inside = await addNote(a, '海', deckId: deck);
    final String outside = await addNote(a, '空');
    final String insideCard = await cardOf(a, inside);
    t += 60 * 1000;
    await a.answer(insideCard, 3);
    final List<String> deleted = await a.deleteDeck(deck, deleteCards: true);
    expect(deleted, <String>[inside]);
    final SrsPurgeReport r = await srsPurgeNotesNow(a, deleted);
    expect(r.notes, 1);
    await expectPurged(a, inside, insideCard);
    expect((await a.note(outside))!.deletedAt, isNull);
    expect((await a.cardsOfNote(outside)).single.hidden, isFalse);

    // 未同步时维护也按删除时刻算安全期（不会当场清掉回收站）。
    final String trash = await addNote(a, '森');
    await a.deleteNote(trash);
    expect((await srsPurgeExpiredTombstones(a)).notes, 0);
    t += 91 * kDay;
    expect((await srsPurgeExpiredTombstones(a)).notes, 1);

    final SrsDbStore b = await device('b');
    await syncAll(<SrsDbStore>[b]);
    expect(b.neverSynced, isFalse);
    expect(() => srsPurgeNotesNow(b, const <String>[]), throwsStateError);
  });

  test('④ 清除后对端再送来旧事件：不复活成可见笔记，再清一次后两边收敛；同步照常', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String gone = await addNote(a, '雪');
    final String keep = await addNote(a, '雨');
    final String goneCard = await cardOf(a, gone);
    t += 60 * 1000;
    await a.answer(goneCard, 3);
    await syncAll(<SrsDbStore>[a, b]);
    await a.deleteNote(gone);
    await syncAll(<SrsDbStore>[a, b]);
    t += 91 * kDay;

    expect((await srsPurgeExpiredTombstones(a)).notes, 1);
    await expectPurged(a, gone, goneCard);

    // b 还没清（例如旧版本 / 还没跑维护）：它的全部事件被 a 重新读到（快照起步时就是这样）。
    await a.applyRemote(await b.exportAll());
    final SrsNoteView? back = await a.note(gone);
    expect(back, isNotNull, reason: '身份记录按并集回来');
    expect(back!.deletedAt, isNotNull, reason: '墓碑还在：仍是已删除，不可见');
    expect(await a.nextCard(a.defaultDeckId), isNot(goneCard));

    // 只有修改记录晚到（没有身份记录）：也是候选。
    expect(await a.purgeCandidateNoteIds(), contains(gone));
    expect((await srsPurgeExpiredTombstones(a)).notes, 1);
    await expectPurged(a, gone, goneCard);

    // 继续同步：b 照常收到 a 的新写入，合并不出错；b 自己过期后也清掉，两边事件集合一致。
    await a.updateNote(keep, fieldsById: <String, String>{expr(a): '雨（改）'});
    await syncAll(<SrsDbStore>[a, b]);
    expect((await b.note(keep))!.field(expr(b)), '雨（改）');
    expect((await b.note(gone))!.deletedAt, isNotNull);
    expect((await srsPurgeExpiredTombstones(b)).notes, 1);
    await expectPurged(b, gone, goneCard);
    await syncAll(<SrsDbStore>[a, b]);
    Set<String> ids(List<SrsEvent> es) => <String>{
      for (final SrsEvent e in es) e.id,
    };
    expect(ids(await a.exportAll()), ids(await b.exportAll()));
    expect(await a.note(gone), isNull);
    expect(await b.note(gone), isNull);
  });

  test('④ 并发的修改（没看见删除）晚到：笔记进待裁决，不清除', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String n = await addNote(a, '雪');
    await syncAll(<SrsDbStore>[a, b]);
    await a.deleteNote(n);
    await b.updateNote(n, fieldsById: <String, String>{expr(b): '雪（改）'});
    await syncAll(<SrsDbStore>[a, b]);
    t += 91 * kDay;
    expect((await srsPurgeExpiredTombstones(a)).notes, 0);
    expect(await a.note(n), isNotNull);
  });

  test('④ 备份往返：清除后备份照常；按时间点恢复到清除前的备份，笔记连同正文回来', () async {
    final SrsDbStore a = await device('a');
    final Directory media = Directory(p.join(tmp.path, 'srs_media', kProfile))
      ..createSync(recursive: true);
    File(p.join(media.path, 'cat.png')).writeAsStringSync('cat');
    final SrsBackupStore bs = SrsBackupStore(
      root: Directory(p.join(tmp.path, 'srs_backups')),
      profileUid: kProfile,
      mediaDir: media,
    );
    final String n = await addNote(a, '猫', extra: '<img src="cat.png">');
    final String c = await cardOf(a, n);
    t += 60 * 1000;
    await a.answer(c, 3);
    t += 60 * 1000;
    final SrsBackupInfo before = await bs.create(
      a,
      kind: SrsBackupKind.manual,
      profileName: 'p',
      nowMs: t,
    );

    await a.deleteNote(n);
    final SrsPurgeReport r = await srsPurgeNotesNow(
      a,
      <String>[n],
      mediaRoot: media,
      mediaGrace: Duration.zero,
    );
    expect(r.mediaFiles, 1);
    await expectPurged(a, n, c);

    t += 60 * 1000;
    final SrsBackupInfo after = await bs.create(
      a,
      kind: SrsBackupKind.manual,
      profileName: 'p',
      nowMs: t,
    );
    expect(after.manifest.noteCount, 0);
    expect(after.manifest.media, isEmpty, reason: '回收的媒体不进新备份');

    final SrsBackupArchive archive = await SrsBackupStore.read(before.file);
    try {
      await bs.restore(a, archive);
    } finally {
      archive.close();
    }
    final SrsNoteView? restored = await a.note(n);
    expect(restored, isNotNull);
    expect(restored!.deletedAt, isNull);
    expect(restored.field(expr(a)), '猫');
    expect((await a.cardRow(c))!.reps, 1);
    expect(File(p.join(media.path, 'cat.png')).existsSync(), isTrue);
    // 恢复回来的是存活笔记：维护不碰它。
    t += 365 * kDay;
    expect((await srsPurgeExpiredTombstones(a, mediaRoot: media)).notes, 0);
    expect(File(p.join(media.path, 'cat.png')).existsSync(), isTrue);
  });

  group('⑤ 媒体回收与并发写入（HBK-AUDIT-014）', () {
    final DateTime old = DateTime.now().subtract(const Duration(days: 3));

    Future<SrsDbStore> reopen(SrsDbStore s, String id) => SrsDbStore.open(
      db: s.db,
      core: s.core,
      profileUid: kProfile,
      deviceId: id,
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        monotonicMs: () => t,
        bootId: 'boot-$id',
      ),
    );

    test('刚存 / 刚复用、引用还没提交的文件不删；候选持久化，下一轮（重开后）照常回收', () async {
      final SrsDbStore a = await device('a');
      final Directory media = Directory(p.join(tmp.path, 'media'))
        ..createSync(recursive: true);
      final File reused = File(p.join(media.path, 'reused.png'))
        ..writeAsStringSync('r');
      final File stale = File(p.join(media.path, 'stale.png'))
        ..writeAsStringSync('s');
      reused.setLastModifiedSync(old);
      stale.setLastModifiedSync(old);
      final String gone = await addNote(
        a,
        '雪',
        extra: '<img src="reused.png"><img src="stale.png">',
      );
      await a.deleteNote(gone);

      // 制卡路径：SrsMediaStore.store 复用了同内容文件（刷新修改时间），返回名字，
      // 引用它的笔记还没提交——回收恰好在这时跑。
      reused.setLastModifiedSync(DateTime.now());
      final SrsPurgeReport r = await srsPurgeNotesNow(a, <String>[
        gone,
      ], mediaRoot: media);
      expect(r.notes, 1);
      expect(r.mediaFiles, 1);
      expect(stale.existsSync(), isFalse, reason: '过了宽限期且无引用');
      expect(reused.existsSync(), isTrue, reason: '刚复用、引用可能还没提交');
      expect(a.pendingMediaGc, <String>{'reused.png'});

      // 引用一直没提交（制卡被取消）：重开 store 后候选还在，过了宽限期照常回收。
      final SrsDbStore again = await reopen(a, 'a');
      expect(again.pendingMediaGc, <String>{'reused.png'});
      reused.setLastModifiedSync(old);
      expect(
        (await srsPurgeExpiredTombstones(again, mediaRoot: media)).mediaFiles,
        1,
      );
      expect(reused.existsSync(), isFalse);
      expect(again.pendingMediaGc, isEmpty);
    });

    test('候选在宽限期内被新笔记引用：不删，并移出待回收集合', () async {
      final SrsDbStore a = await device('a');
      final Directory media = Directory(p.join(tmp.path, 'media'))
        ..createSync(recursive: true);
      final File f = File(p.join(media.path, 'cat.png'))
        ..writeAsStringSync('c');
      f.setLastModifiedSync(old);
      final String gone = await addNote(a, '猫', extra: '<img src="cat.png">');
      await a.deleteNote(gone);
      f.setLastModifiedSync(DateTime.now());
      await srsPurgeNotesNow(a, <String>[gone], mediaRoot: media);
      expect(a.pendingMediaGc, <String>{'cat.png'});

      await addNote(a, '虎', extra: '<img src="CAT.png">');
      f.setLastModifiedSync(old);
      expect(
        (await srsPurgeExpiredTombstones(a, mediaRoot: media)).mediaFiles,
        0,
      );
      expect(f.existsSync(), isTrue);
      expect(a.pendingMediaGc, isEmpty);
    });

    test('扫描与删除在独占区里：排在前面的写入重新引用了候选，文件保留', () async {
      final SrsDbStore a = await device('a');
      final Directory media = Directory(p.join(tmp.path, 'media'))
        ..createSync(recursive: true);
      final File f = File(p.join(media.path, 'dog.png'))
        ..writeAsStringSync('d');
      f.setLastModifiedSync(old);
      final String gone = await addNote(a, '犬', extra: '<img src="dog.png">');
      await a.deleteNote(gone);

      // 一个写入者先拿到锁（编辑 / 恢复 / 撤销），在锁里才把引用写进库。
      final Completer<void> gate = Completer<void>();
      final Future<void> writer = a.runExclusive(() async {
        await gate.future;
        await addNote(a, '狗', extra: '<img src="dog.png">');
      });
      final Future<SrsPurgeReport> purge = srsPurgeNotesNow(
        a,
        <String>[gone],
        mediaRoot: media,
        mediaGrace: Duration.zero,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await writer;
      final SrsPurgeReport r = await purge;
      expect(r.notes, 1);
      expect(r.mediaFiles, 0);
      expect(f.existsSync(), isTrue);
    });
  });
}

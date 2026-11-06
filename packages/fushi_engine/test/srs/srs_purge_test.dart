import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow, srsIdType;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_sync.dart' show kSrsMediaRetention;
import 'package:fushi_engine/srs/srs_purge.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_sync2_peers.dart';
import 'support/srs_test_storage.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000000e5';
const int kDay = 24 * 60 * 60 * 1000;

/// 复习库的空间回收（srs_purge.dart，docs/specs/2026-10-25-srs-sync-v2-design.md §10.2、§10.5）：历史永久
/// 保留，维护只回收过了保留期的媒体；彻底清除走 v2 `Purge` 操作，传到每台设备抹掉内容。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  int t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;
  late SrsMemoryLocationStore loc;
  late Directory tmp;

  setUp(() async {
    t = DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch;
    loc = SrsMemoryLocationStore();
    tmp = await Directory.systemTemp.createTemp('srs_purge_test_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 句柄滞后（Windows）：留给系统清理。
    }
  });

  Future<SrsDbStore> open(SrsStorage srs, String id) => SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: kProfile,
    deviceId: id,
    engine: const SrsFakeEngine(),
    trustedClock: SrsTrustedClock(
      wallClockMs: () => t,
      bootClockMs: () => t,
      bootId: 'boot-$id',
    ),
  );

  Future<SrsDbStore> device(String id) async =>
      open(await openTestSrsStorage(), id);

  Future<void> syncAll(List<SrsDbStore> stores) async {
    t += 1000;
    await srsSyncPeers(stores, loc, rounds: 3);
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

  Directory mediaDir() =>
      Directory(p.join(tmp.path, 'media'))..createSync(recursive: true);

  Future<String> cardOf(SrsDbStore s, String noteId) async =>
      (await s.cardsOfNote(noteId)).single.id;

  Future<int> logCount(SrsDbStore s, String cardId) async =>
      (await (s.db.select(
        s.db.srsReviewLogs,
      )..where((r) => r.cardId.equals(cardId))).get()).length;

  Future<List<String>> noteEditKeys(SrsDbStore s, String noteId) async =>
      <String>[
        for (final QueryRow r
            in await s.db
                .customSelect(
                  'SELECT field_key FROM srs_field_edits WHERE entity_id = ? '
                  'ORDER BY field_key',
                  variables: <Variable<Object>>[
                    Variable<String>(noteId, srsIdType),
                  ],
                )
                .get())
          r.read<String>('field_key'),
      ];

  /// 本机操作日志里还带着 [text] 的操作条数（载荷原字节里按字节子串找；载荷开头是二进制头、含 NUL，不能 CAST 成 TEXT 再 LIKE）。
  Future<int> opsCarrying(SrsDbStore s, String text) async =>
      (await s.db
              .customSelect(
                'SELECT COUNT(*) AS c FROM sync2_ops WHERE profile_uid = ? '
                'AND instr(payload, CAST(? AS BLOB)) > 0',
                variables: <Variable<Object>>[
                  Variable<String>(kProfile, srsIdType),
                  Variable<String>(text),
                ],
              )
              .getSingle())
          .read<int>('c');

  /// 被彻底清除的笔记：不可见、内容（字段 / 标签的修改记录与日志载荷）没了，只剩删除寄存器；复习日志保留。
  Future<void> expectPurged(
    SrsDbStore s,
    String noteId,
    String cardId,
    String text,
  ) async {
    final SrsNoteView? n = await s.note(noteId);
    expect(n == null || n.deletedAt != null, isTrue, reason: '不可见');
    expect(n?.field(expr(s)) ?? '', '', reason: '正文已清');
    expect(await noteEditKeys(s, noteId), <String>[
      SrsFieldKeys.deleted,
    ], reason: '投影里只剩删除寄存器');
    expect(await opsCarrying(s, text), 0, reason: '本机操作日志里的内容载荷换成了哈希');
    final SrsCardCacheRow? card = await s.cardRow(cardId);
    expect(card == null || card.hidden, isTrue, reason: '卡不再出现在队列');
  }

  test('维护不删历史：删除一年后的笔记照样在（时间线可恢复），只回收过了保留期的独占媒体', () async {
    final SrsDbStore a = await device('a');
    final Directory media = mediaDir();
    for (final String n in <String>['only.png', 'shared.png']) {
      File(p.join(media.path, n))
        ..writeAsStringSync(n)
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 3)));
    }
    final String gone = await addNote(
      a,
      '雪',
      extra: '<img src="only.png"><img src="shared.png">',
    );
    await addNote(a, '雨', extra: '<img src="Shared.PNG">');
    final String goneCard = await cardOf(a, gone);
    t += 60 * 1000;
    await a.answer(goneCard, 3);
    t += 1000;
    await a.deleteNote(gone);

    t += kSrsMediaRetention.inMilliseconds - kDay;
    SrsPurgeReport r = await srsPurgeExpiredTombstones(a, mediaRoot: media);
    expect(r.notes, 0);
    expect(r.mediaFiles, 0, reason: '保留期内恢复笔记媒体还在');
    expect(File(p.join(media.path, 'only.png')).existsSync(), isTrue);

    t += 2 * kDay;
    r = await srsPurgeExpiredTombstones(a, mediaRoot: media);
    expect(r.notes, 0, reason: '维护从不删笔记');
    expect(r.mediaFiles, 1);
    expect(File(p.join(media.path, 'only.png')).existsSync(), isFalse);
    expect(
      File(p.join(media.path, 'shared.png')).existsSync(),
      isTrue,
      reason: '存活笔记引用（大小写不同也算）',
    );

    t += 365 * kDay;
    expect((await srsPurgeExpiredTombstones(a, mediaRoot: media)).notes, 0);
    final SrsNoteView? kept = await a.note(gone);
    expect(kept!.deletedAt, isNotNull);
    expect(kept.field(expr(a)), '雪', reason: '正文还在，恢复用得上');
    expect(await logCount(a, goneCard), 1);
    // 没给媒体目录：什么也不做。
    expect((await srsPurgeExpiredTombstones(a)).mediaFiles, 0);
  });

  test('彻底清除：追加 Purge 操作，内容抹掉、复习日志保留；独占媒体删、共享与回收站里的留', () async {
    final SrsDbStore a = await device('a');
    final Directory media = mediaDir();
    for (final String n in <String>['shared.png', 'only.mp3', 'trash.png']) {
      File(p.join(media.path, n)).writeAsStringSync(n);
    }
    final String gone = await addNote(
      a,
      'secret-snow',
      extra: '<img src="shared.png">[sound:only.mp3]<img src="trash.png">',
    );
    await addNote(a, '雨', extra: '<img src="Shared.PNG">');
    final String inTrash = await addNote(
      a,
      '風',
      extra: '<img src="trash.png">',
    );
    await a.deleteNote(inTrash); // 已删、不清：可能被恢复，媒体要留着
    final String goneCard = await cardOf(a, gone);
    t += 60 * 1000;
    await a.answer(goneCard, 3);
    expect(await opsCarrying(a, 'secret-snow'), greaterThan(0));
    final int opsBefore = (await a.sync2Status())['ops']! as int;

    t += 1000;
    final SrsPurgeReport r = await srsPurgeNotesNow(
      a,
      <String>[gone],
      mediaRoot: media,
      mediaGrace: Duration.zero,
    );
    expect(r.notes, 1);
    expect(r.mediaFiles, 1);
    expect(
      (await a.sync2Status())['ops'],
      opsBefore + 2,
      reason: '一条删除 + 一条 Purge（未删的笔记先删除再清除）',
    );
    await expectPurged(a, gone, goneCard, 'secret-snow');
    expect(await logCount(a, goneCard), 1, reason: '统计里过去的复习不能因为清除而消失');
    expect(File(p.join(media.path, 'only.mp3')).existsSync(), isFalse);
    expect(File(p.join(media.path, 'shared.png')).existsSync(), isTrue);
    expect(
      File(p.join(media.path, 'trash.png')).existsSync(),
      isTrue,
      reason: '回收站里的笔记还可能恢复',
    );
    expect((await a.note(inTrash))!.deletedAt, isNotNull);
  });

  test('清除传到别的设备：那边的内容也没了；之后加入的新设备从位置上收不到内容；同步照常', () async {
    final SrsDbStore a = await device('a');
    final SrsDbStore b = await device('b');
    final String gone = await addNote(a, 'secret-snow');
    final String keep = await addNote(a, '雨');
    final String goneCard = await cardOf(a, gone);
    await syncAll(<SrsDbStore>[a, b]);
    // b 也写过这条笔记的内容（b 自己的段里也带着内容）。
    t += 1000;
    await b.updateNote(
      gone,
      fieldsById: <String, String>{sentence(b): 'secret-more'},
    );
    t += 60 * 1000;
    await b.answer(goneCard, 3);
    await syncAll(<SrsDbStore>[a, b]);
    expect((await a.note(gone))!.field(sentence(a)), 'secret-more');
    expect(await opsCarrying(b, 'secret-snow'), greaterThan(0));

    t += 1000;
    expect((await srsPurgeNotesNow(a, <String>[gone])).notes, 1);
    await expectPurged(a, gone, goneCard, 'secret-');
    await syncAll(<SrsDbStore>[a, b]);
    await expectPurged(b, gone, goneCard, 'secret-');
    expect(await logCount(b, goneCard), 1, reason: 'b 的复习日志照样在');

    // 新设备从位置上完整收下（各作者已把自己的段重写成骨架）：同样没有内容。
    final SrsDbStore c = await device('c');
    await syncAll(<SrsDbStore>[c]);
    await expectPurged(c, gone, goneCard, 'secret-');
    expect((await c.note(keep))!.field(expr(c)), '雨');

    // 继续同步：别的笔记照常收发，三端摘要一致。
    t += 1000;
    await b.updateNote(keep, fieldsById: <String, String>{expr(b): '雨（改）'});
    await syncAll(<SrsDbStore>[a, b, c]);
    for (final SrsDbStore s in <SrsDbStore>[a, c]) {
      expect((await s.note(keep))!.field(expr(s)), '雨（改）');
    }
    final Object? digest = (await a.sync2Digest())['digest'];
    expect((await b.sync2Digest())['digest'], digest);
    expect((await c.sync2Digest())['digest'], digest);
  });

  group('媒体回收与并发写入（HBK-AUDIT-014）', () {
    final DateTime old = DateTime.now().subtract(const Duration(days: 3));

    test('刚存 / 刚复用、引用还没提交的文件不删；候选持久化，下一轮（重开后）照常回收', () async {
      final SrsStorage srs = await openTestSrsStorage();
      final SrsDbStore a = await open(srs, 'a');
      final Directory media = mediaDir();
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
      final SrsDbStore again = await open(srs, 'a');
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
      final Directory media = mediaDir();
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
      final Directory media = mediaDir();
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
      // 让清除先跑到等锁那一步（它若能插进来，这里就会删掉马上被引用的文件）。
      await pumpEventQueue();
      gate.complete();
      await writer;
      final SrsPurgeReport r = await purge;
      expect(r.notes, 1);
      expect(r.mediaFiles, 0);
      expect(f.existsSync(), isTrue);
    });
  });
}

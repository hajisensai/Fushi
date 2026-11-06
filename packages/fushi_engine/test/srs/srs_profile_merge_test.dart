// 有用户笔记的本机 profile 并入同步目录里已有的另一个 profile（srs_profile_merge.dart）。
//
// 两台设备各自随机生成 profileUid、各自有笔记和复习记录；B 把自己并入 A 的 uid 后按调用方的顺序重开 store、
// afterRestore(freshIncarnation: true)、同步 v2：两边都看到全部笔记，B 原来的笔记仍在新 uid 的默认牌组 / 内置
// Lapis 类型下、字段内容与复习历史都在；中途失败（注入）不丢数据，重跑收敛。
import 'dart:io';

import 'package:drift/drift.dart' show QueryRow, Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_profile_link.dart';
import 'package:fushi_engine/srs/srs_profile_merge.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_pull_first.dart';
import 'package:fushi_engine/srs/sync2/srs_sync2_round.dart';
import 'package:fushi_engine/sync/local_directory_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_fake_engine.dart';
import 'support/srs_test_storage.dart';

class _Device {
  _Device._(this.db, this.srs, this.deviceId, this.profileId);

  final FushiDatabase db;
  final SrsStorage srs;
  final String deviceId;
  final int profileId;
  late SrsDbStore store;

  static Future<_Device> open(String deviceId) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final SrsStorage srs = await openTestSrsStorage();
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Default', createdAt: now, updatedAt: now),
    );
    final _Device d = _Device._(db, srs, deviceId, profileId);
    d.store = await d.reopen();
    return d;
  }

  /// 按 profiles 表里的 uid 重开（调用方并入 / 采用之后做的事）。
  Future<SrsDbStore> reopen() async => store = await SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: await db.profileUidOf(profileId),
    deviceId: deviceId,
    engine: const SrsFakeEngine(),
  );

  Future<String> addNote(
    String expression, {
    String? deckId,
    List<String> tags = const <String>[],
  }) => store.createNote(
    noteTypeId: store.lapisNoteTypeId,
    fieldsById: <String, String>{
      srsLapisFieldId(store.profileUid, 'Expression'): expression,
      srsLapisFieldId(store.profileUid, 'MainDefinition'): '$expression 的释义',
    },
    deckId: deckId,
    tags: tags,
  );

  Future<String> cardOf(String noteId) async =>
      (await store.cardsOfNote(noteId)).single.id;

  Future<SrsSync2Report> round(LocalDirectoryAssetStore dir) => srsSync2Round(
    host: store,
    location: SrsAssetLocationStore(store: dir, profileUid: store.profileUid),
    locationId: 'interconnect:host',
    nowMs: () => store.now().$1,
  );

  Future<int> rowsOf(String uid) async {
    int n = 0;
    for (final String t in const <String>[
      'srs_entities',
      'srs_field_edits',
      'srs_review_logs',
      'srs_cards_cache',
      'srs_notes_cache',
      'sync2_ops',
      'sync2_self',
    ]) {
      final QueryRow r = await srs.db
          .customSelect(
            'SELECT COUNT(*) AS c FROM $t WHERE profile_uid = ?',
            variables: <Variable<Object>>[Variable<String>(uid, srsIdType)],
          )
          .getSingle();
      n += r.read<int>('c');
    }
    return n;
  }
}

/// 一条笔记在 [s] 里的样子（按 guid 找：并入后笔记 ID 随 uid 重算）。
Future<SrsNoteView?> _noteByGuid(SrsDbStore s, String guid) async {
  final String? id = await s.noteIdByGuid(guid);
  return id == null ? null : s.note(id);
}

/// [seededChain] 的三条原生日志的旧 ID。
const String _kChainR1 = '019a3a0b-0000-7000-8000-0000000000f1';
const String _kChainR2 = '019a3a0b-0000-7000-8000-0000000000f2';
const String _kChainUndo = '019a3a0b-0000-7000-8000-0000000000f3';

/// [seededChain] 的起始时刻（r2 在 +20、撤销它的 undo 在 +30）。
const int _kChainT0 = 1792700000000;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory root;
  late LocalDirectoryAssetStore dir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_srs_merge_');
    dir = LocalDirectoryAssetStore(root);
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后；留给系统清理。
    }
  });

  Future<void> syncBoth(_Device a, _Device b, {int rounds = 3}) async {
    for (int i = 0; i < rounds; i++) {
      expect((await a.round(dir)).error, isNull, reason: 'a round $i');
      expect((await b.round(dir)).error, isNull, reason: 'b round $i');
    }
  }

  test('B 并入 A 的 uid：双向互通，B 的笔记 / 牌组 / 标签 / 暂停 / 复习历史原样保留', () async {
    final _Device a = await _Device.open('computer');
    final _Device b = await _Device.open('iphone');
    final String aUid = a.store.profileUid;
    final String bOld = b.store.profileUid;
    expect(aUid, isNot(bOld));

    // A：一条笔记、复习两次，已同步发布。
    final String aNote = await a.addNote('雪');
    final String aGuid = (await a.store.note(aNote))!.guid;
    final String aCard = await a.cardOf(aNote);
    await a.store.answer(aCard, 3);
    await a.store.answer(aCard, 4);

    // B：默认牌组里一条（复习三次、带标签），自建牌组里一条（暂停），也各自同步过自己的 uid。
    final String rain = await b.addNote('雨', tags: <String>['天気', 'N5']);
    final String deck = await b.store.createDeck('日本語');
    final String wind = await b.addNote('風', deckId: deck);
    final String rainGuid = (await b.store.note(rain))!.guid;
    final String windGuid = (await b.store.note(wind))!.guid;
    final String rainCard = await b.cardOf(rain);
    final String windCard = await b.cardOf(wind);
    await b.store.answer(rainCard, 1);
    await b.store.answer(rainCard, 3);
    await b.store.answer(rainCard, 3);
    await b.store.setSuspended(windCard, true);
    final SrsScheduleResult rainState = (await b.store.history(rainCard)).state;
    expect(rainState.reps, 3);
    expect((await a.round(dir)).error, isNull);
    expect((await b.round(dir)).error, isNull);

    final SrsProfileMergeResult r = await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: aUid,
      deviceId: b.deviceId,
    );
    expect(r.appliedEvents, greaterThan(0));
    expect(await b.db.profileUidOf(b.profileId), aUid);
    expect(await b.rowsOf(bOld), 0, reason: '并入成功后旧 uid 的本机行全部删掉');
    expect(await srsPendingProfileMerges(b.srs.db), isEmpty);

    await b.reopen();
    await b.store.afterRestore(freshIncarnation: true);
    expect(b.store.profileUid, aUid);
    await syncBoth(a, b);

    for (final _Device d in <_Device>[a, b]) {
      final String who = d.deviceId;
      final SrsNoteView? snow = await _noteByGuid(d.store, aGuid);
      final SrsNoteView? r2 = await _noteByGuid(d.store, rainGuid);
      final SrsNoteView? w2 = await _noteByGuid(d.store, windGuid);
      expect(
        snow?.field(srsLapisFieldId(aUid, 'Expression')),
        '雪',
        reason: who,
      );
      expect(r2, isNotNull, reason: '$who 看得到 B 的「雨」');
      expect(w2, isNotNull, reason: '$who 看得到 B 的「風」');
      // 笔记挂在新 uid 的内置 Lapis 上、字段按新 uid 的字段 ID 读得出来。
      expect(r2!.noteTypeId, srsLapisNoteTypeId(aUid), reason: who);
      expect(r2.field(srsLapisFieldId(aUid, 'Expression')), '雨', reason: who);
      expect(
        r2.field(srsLapisFieldId(aUid, 'MainDefinition')),
        '雨 的释义',
        reason: who,
      );
      expect(r2.tags, unorderedEquals(<String>['天気', 'N5']), reason: who);
      expect(w2!.field(srsLapisFieldId(aUid, 'Expression')), '風', reason: who);

      // 卡片：按新 uid 的模板重新派生的那张卡就是带着历史的那张（不会多出一张空白新卡）。
      final List<SrsCardCacheRow> rainCards = await d.store.cardsOfNote(r2.id);
      expect(rainCards, hasLength(1), reason: who);
      expect(
        rainCards.single.deckId,
        SrsIds.builtinDefaultDeck(aUid),
        reason: '$who：「雨」在新 uid 的默认牌组',
      );
      final SrsScheduleResult got = (await d.store.history(
        rainCards.single.id,
      )).state;
      expect(got.reps, 3, reason: '$who：复习历史保留');
      expect(got.lapses, rainState.lapses, reason: who);
      expect(got.queue, rainState.queue, reason: who);

      final List<SrsCardCacheRow> windCards = await d.store.cardsOfNote(w2.id);
      expect(windCards, hasLength(1), reason: who);
      expect(windCards.single.suspended, isTrue, reason: '$who：暂停保留');
      final SrsDeckTree tree = await d.store.deckTree();
      expect(
        tree.fullName(windCards.single.deckId),
        '日本語',
        reason: '$who：自建牌组跟着过来',
      );

      final List<SrsCardCacheRow> snowCards = await d.store.cardsOfNote(
        snow!.id,
      );
      expect(
        (await d.store.history(snowCards.single.id)).state.reps,
        2,
        reason: '$who：A 的复习历史不受影响',
      );
    }
    expect(a.store.profileUid, aUid);
    expect(await a.db.profileUidOf(a.profileId), aUid);

    // 并入之后的新写入照常双向同步。
    final String later = await b.addNote('霧');
    final String laterGuid = (await b.store.note(later))!.guid;
    await syncBoth(a, b, rounds: 2);
    expect(
      (await _noteByGuid(
        a.store,
        laterGuid,
      ))?.field(srsLapisFieldId(aUid, 'Expression')),
      '霧',
    );
    // BUG-3959：并入带过来的合成标签行（写入者 `sync2:tags:<笔记>`）不进任何因果上下文——以前它进了 B 的
    // legacy 闭包，此后 B 的每条新修改 ctx 都带上一条笔记一项（真实库 15027 项、≈780 KB / 条）。
    for (final _Device d in <_Device>[a, b]) {
      final QueryRow bloat = await d.srs.db
          .customSelect(
            'SELECT (SELECT COUNT(*) FROM srs_field_edits '
            "WHERE instr(json_extract(json, '\$.ctx'), '\"sync2:') > 0) AS e, "
            '(SELECT COUNT(*) FROM sync2_legacy '
            "WHERE instr(ctx, '\"sync2:') > 0) AS l",
          )
          .getSingle();
      expect(bloat.read<int>('e'), 0, reason: '${d.deviceId}：修改记录 ctx');
      expect(bloat.read<int>('l'), 0, reason: '${d.deviceId}：legacy 闭包');
    }
  });

  test('ID 映射：内置实体与笔记 / 卡片按新 uid 重算，重跑幂等、不重复落操作', () async {
    final _Device b = await _Device.open('iphone');
    final String bOld = b.store.profileUid;
    final String note = await b.addNote('雨');
    final String guid = (await b.store.note(note))!.guid;
    await b.store.answer(await b.cardOf(note), 3);
    const String target = '01900000-0000-7000-8000-000000000001';

    final SrsProfileMergeResult first = await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
    );
    // 只有那条原生复习日志（UUIDv7，没有派生输入）走兜底；profile、内置牌组 / 笔记类型 / 字段 / 模板、
    // 笔记、卡片都按新 uid 用同一条规则重算。
    expect(first.fallbackIds, 1, reason: 'exact=${first.exactIds}');
    await b.reopen();
    await b.store.afterRestore(freshIncarnation: true);
    final String newNote = SrsIds.note(target, guid);
    final SrsNoteView? n = await b.store.note(newNote);
    expect(n?.noteTypeId, srsLapisNoteTypeId(target));
    final SrsCardCacheRow card = (await b.store.cardsOfNote(newNote)).single;
    final String lapisTpl = srsBuiltinLapis(target).templates.single.id;
    expect(card.id, SrsIds.card(newNote, lapisTpl, 0));
    expect((await b.store.history(card.id)).state.reps, 1);

    final QueryRow ops0 = await b.srs.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM sync2_ops WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(target, srsIdType)],
        )
        .getSingle();
    final SrsProfileMergeResult again = await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
    );
    expect(again.appliedEvents, 0);
    final QueryRow ops1 = await b.srs.db
        .customSelect(
          'SELECT COUNT(*) AS c FROM sync2_ops WHERE profile_uid = ?',
          variables: <Variable<Object>>[Variable<String>(target, srsIdType)],
        )
        .getSingle();
    expect(ops1.read<int>('c'), ops0.read<int>('c'));
  });

  test(
    '批量派生（SrsIds.notes / cards / importedRevlogsOf / importAnchorsOf）与逐个派生同值',
    () {
      const String uid = '01900000-0000-7000-8000-00000000000a';
      final List<String> guids = <String>['abc', 'X#y!', '雨'];
      expect(SrsIds.notes(uid, guids), <String>[
        for (final String g in guids) SrsIds.note(uid, g),
      ]);
      final String n = SrsIds.note(uid, 'abc');
      final String t = srsBuiltinLapis(uid).templates.single.id;
      expect(
        SrsIds.cards(<(String, String, int)>[(n, t, 0), (n, t, 3)]),
        <String>[SrsIds.card(n, t, 0), SrsIds.card(n, t, 3)],
      );
      final String c = SrsIds.card(n, t, 0);
      expect(
        SrsIds.importedRevlogsOf(<(String, int)>[(c, 17), (n, 1)]),
        <String>[SrsIds.importedRevlog(c, 17), SrsIds.importedRevlog(n, 1)],
      );
      expect(
        SrsIds.importAnchorsOf(<(String, int)>[(c, 1700000000000)]),
        <String>[SrsIds.importAnchor(c, 1700000000000)],
      );
    },
  );

  test('第一遍并入后失败：uid 不变、旧数据原样可读；重跑收敛', () async {
    final _Device b = await _Device.open('iphone');
    final String bOld = b.store.profileUid;
    final String note = await b.addNote('雨');
    await b.store.answer(await b.cardOf(note), 3);
    const String target = '01900000-0000-7000-8000-000000000002';

    await expectLater(
      srsMergeProfileUid(
        b.db,
        b.srs.db,
        core: b.srs.core,
        profileId: b.profileId,
        oldUid: bOld,
        newUid: target,
        deviceId: b.deviceId,
        debugFault: (SrsProfileMergeStage s) async {
          if (s == SrsProfileMergeStage.afterFirstMerge) {
            throw StateError('injected');
          }
        },
      ),
      throwsStateError,
    );
    expect(await b.db.profileUidOf(b.profileId), bOld);
    await b.reopen();
    expect(
      (await b.store.note(note))?.field(srsLapisFieldId(bOld, 'Expression')),
      '雨',
    );
    expect((await b.store.history(await b.cardOf(note))).state.reps, 1);
    expect(await srsPendingProfileMerges(b.srs.db), hasLength(1));

    final SrsPendingProfileMerge p = (await srsPendingProfileMerges(
      b.srs.db,
    )).single;
    await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: p.profileId,
      oldUid: p.oldUid,
      newUid: p.newUid,
      deviceId: b.deviceId,
    );
    expect(await b.db.profileUidOf(b.profileId), target);
    expect(await b.rowsOf(bOld), 0);
    await b.reopen();
    await b.store.afterRestore(freshIncarnation: true);
    final String guid = (await b.store.note(
      SrsIds.note(target, (await _guidOfOnly(b))),
    ))!.guid;
    expect(guid, isNotEmpty);
  });

  test('删旧行的事务里失败：旧行一行不少（回滚），新 uid 下数据齐全；重跑删掉旧行', () async {
    final _Device b = await _Device.open('iphone');
    final String bOld = b.store.profileUid;
    final String note = await b.addNote('雨');
    final String guid = (await b.store.note(note))!.guid;
    await b.store.answer(await b.cardOf(note), 3);
    final int before = await b.rowsOf(bOld);
    const String target = '01900000-0000-7000-8000-000000000003';

    await expectLater(
      srsMergeProfileUid(
        b.db,
        b.srs.db,
        core: b.srs.core,
        profileId: b.profileId,
        oldUid: bOld,
        newUid: target,
        deviceId: b.deviceId,
        debugFault: (SrsProfileMergeStage s) async {
          if (s == SrsProfileMergeStage.beforeDelete) {
            throw StateError('injected');
          }
        },
      ),
      throwsStateError,
    );
    expect(await b.db.profileUidOf(b.profileId), target);
    expect(await b.rowsOf(bOld), before, reason: '删除事务回滚，旧行一行不少');
    await b.reopen();
    final SrsNoteView? n = await _noteByGuid(b.store, guid);
    expect(n?.field(srsLapisFieldId(target, 'Expression')), '雨');
    expect((await b.store.history(await b.cardOf(n!.id))).state.reps, 1);

    await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
    );
    expect(await b.rowsOf(bOld), 0);
    expect(await srsPendingProfileMerges(b.srs.db), isEmpty);
    await b.reopen();
    expect(
      (await _noteByGuid(
        b.store,
        guid,
      ))?.field(srsLapisFieldId(target, 'Expression')),
      '雨',
    );
  });

  test('媒体与共享样式文件跟着搬到新 uid 目录', () async {
    final _Device b = await _Device.open('iphone');
    final String bOld = b.store.profileUid;
    await b.addNote('雨');
    final Directory media = Directory.systemTemp.createTempSync('srs_media_');
    addTearDown(() => media.deleteSync(recursive: true));
    final Directory old = Directory('${media.path}/$bOld')..createSync();
    File('${old.path}/abc.mp3').writeAsStringSync('audio');
    const String target = '01900000-0000-7000-8000-000000000004';
    await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
      mediaRoot: media,
    );
    expect(File('${media.path}/$target/abc.mp3').readAsStringSync(), 'audio');
    expect(old.existsSync(), isFalse);
  });

  test('目标 uid 已是本机另一个 profile：拒绝，不动任何数据', () async {
    final _Device b = await _Device.open('iphone');
    final String bOld = b.store.profileUid;
    await b.addNote('雨');
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int other = await b.db.insertProfile(
      ProfilesCompanion.insert(name: 'Other', createdAt: now, updatedAt: now),
    );
    final String otherUid = await b.db.profileUidOf(other);
    final int before = await b.rowsOf(bOld);
    await expectLater(
      srsMergeProfileUid(
        b.db,
        b.srs.db,
        core: b.srs.core,
        profileId: b.profileId,
        oldUid: bOld,
        newUid: otherUid,
        deviceId: b.deviceId,
      ),
      throwsStateError,
    );
    expect(await b.db.profileUidOf(b.profileId), bOld);
    expect(await b.rowsOf(bOld), before);
  });

  // BUG-4011：宿主把旧 profile 并入时，目标集合里已经有同一批修改记录（01a173ca 迁出的 `2RIr94…#1`：与宿主旧写入者
  // 逐条同 seq、同 HLC 物理时刻与计数，只是写入者名字不同），并入却改名成 `merged-…`，31 万条修改记录在目标里成了
  // 两份。目标里已有时沿用目标的名字：dot 相同 → 修改记录 ID 相同，认出已在，不再并。
  test('目标里已有同一批修改记录（同 seq 同 HLC）：沿用目标的写入者、不重复并；同 seq 不同 HLC 的照常改名', () async {
    final _Device b = await _Device.open('host');
    final String bOld = b.store.profileUid;
    const String target = '01900000-0000-7000-8000-0000000000aa';
    final SrsDbStore t = await SrsDbStore.open(
      db: b.srs.db,
      core: b.srs.core,
      profileUid: target,
      deviceId: b.deviceId,
      engine: const SrsFakeEngine(),
    );
    const int t0 = 1700000000000;
    SrsEditEvent legacy(String uid, String w, int seq, int at, String key) =>
        SrsEditEvent(
          SrsFieldEdit(
            profileUid: uid,
            entityKind: SrsEntityKind.deck,
            entityId: SrsIds.builtinDefaultDeck(uid),
            fieldKey: key,
            dot: SrsDot(w, seq),
            ctx: SrsCausalContext.empty(),
            value: 'v',
            hlc: Hlc(at, 0, w),
            timeSource: SrsTimeSource.wall,
          ),
        );
    await b.store.applyRemote(<SrsEvent>[
      for (int i = 1; i <= 3; i++)
        legacy(bOld, 'host-old#1', i, t0 + i, 'x/$i'),
      // 同 seq、不同 HLC：与目标里的任何一条都不是同一条记录。
      legacy(bOld, 'clone-a#1', 1, t0 + 10, 'c/a'),
    ]);
    await t.applyRemote(<SrsEvent>[
      for (int i = 1; i <= 3; i++) legacy(target, 'their#1', i, t0 + i, 'x/$i'),
      legacy(target, 'clone-b#1', 1, t0 + 20, 'c/b'),
    ]);

    await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
    );
    final List<QueryRow> rows = await b.srs.db
        .customSelect(
          'SELECT srs_idt(writer_id) AS w, field_key AS k FROM srs_field_edits '
          "WHERE profile_uid = ? AND (field_key LIKE 'x/%' OR field_key LIKE 'c/%') "
          'ORDER BY k, w',
          variables: <Variable<Object>>[Variable<String>(target, srsIdType)],
        )
        .get();
    final List<String> got = <String>[
      for (final QueryRow r in rows)
        '${r.read<String>('k')} ${r.read<String>('w')}',
    ];
    final String merged = got
        .firstWhere((String s) => s.startsWith('c/a '))
        .substring(4);
    expect(merged, startsWith(kSrsMergedWriterPrefix));
    expect(
      got,
      <String>[
        'c/a $merged',
        'c/b clone-b#1',
        'x/1 their#1',
        'x/2 their#1',
        'x/3 their#1',
      ],
      reason:
          'the shared edits land once, under the writer the target already has',
    );
  });

  // BUG-4217：同一次复习经两条路径进到目标集合时，合并必须落成同一条（同 ID）。以前导入 revlog 只在「旧 ID 恰好按
  // 旧卡片派生」时才按规则换 ID，否则按旧 ID 兜底；旧 profile 本身是更早一次并入的产物时，它的 revlog ID 早已是兜底
  // ID，于是同一条 Anki 复习在目标里有了第二个 ID（实测一个用户 5849 条复习里 2191 条是这种重复，FSRS-7 优化的
  // log loss 从 0.61 涨到 1.59）。原生日志同理：目标里已有原 ID，合并又按兜底 ID 加了一份。
  test('同一次复习（Anki revlog / 原生日志）已在目标里或在旧 profile 里有多个 ID：合并后只剩一条', () async {
    final _Device b = await _Device.open('host');
    final String bOld = b.store.profileUid;
    const String target = '01900000-0000-7000-8000-0000000000bb';
    final SrsDbStore t = await SrsDbStore.open(
      db: b.srs.db,
      core: b.srs.core,
      profileUid: target,
      deviceId: b.deviceId,
      engine: const SrsFakeEngine(),
    );
    const String guid = 'anki-guid-shared';
    Future<String> cardWith(SrsDbStore s) async {
      final String note = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(s.profileUid, 'Expression'): '雨',
          srsLapisFieldId(s.profileUid, 'MainDefinition'): 'rain',
        },
        guid: guid,
      );
      return (await s.cardsOfNote(note)).single.id;
    }

    final String tCard = await cardWith(t);
    final String bCard = await cardWith(b.store);
    const int revlog = 1792403304283;
    const int native = 1792572744194;
    SrsLogEvent log(String id, String uid, String card, {required bool anki}) =>
        SrsLogEvent(
          SrsReviewLog(
            id: id,
            profileUid: uid,
            cardId: card,
            kind: SrsLogKind.review,
            rating: 1,
            hlc: anki ? Hlc(revlog, 0, 'anki') : Hlc(native, 0, 'phone#1'),
            occurredAt: anki ? revlog : native,
            timeSource: SrsTimeSource.wall,
            origin: anki ? 'anki' : 'fushi',
            reviewType: 'learn',
            ankiRevlogId: anki ? revlog : null,
          ),
        );
    final String ruleId = SrsIds.importedRevlog(tCard, revlog);
    const String nativeId = '019a3a0b-0000-7000-8000-000000000001';
    // 目标：按规则派生的 revlog ID + 原生日志的原 ID（另一台设备直接写 / 同步来的）。
    await t.applyRemote(<SrsEvent>[
      log(ruleId, target, tCard, anki: true),
      log(nativeId, target, tCard, anki: false),
    ]);
    // 旧 profile：同一条 revlog 有两个都不按规则派生的 ID（更早并入的产物），同一条原生日志换了个 ID。
    await b.store.applyRemote(<SrsEvent>[
      log('01900000-0000-5000-8000-0000000000c1', bOld, bCard, anki: true),
      log('01900000-0000-5000-8000-0000000000c2', bOld, bCard, anki: true),
      log('01900000-0000-5000-8000-0000000000c3', bOld, bCard, anki: false),
    ]);

    Future<List<String>> logsOf(String card) async => <String>[
      for (final QueryRow r
          in await b.srs.db
              .customSelect(
                'SELECT srs_idt(id) AS id FROM srs_review_logs '
                'WHERE profile_uid = ? AND card_id = ? ORDER BY id',
                variables: <Variable<Object>>[
                  Variable<String>(target, srsIdType),
                  Variable<String>(card, srsIdType),
                ],
              )
              .get())
        r.read<String>('id'),
    ];

    Future<SrsProfileMergeResult> merge() => srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
    );
    final SrsProfileMergeResult merged = await merge();
    expect(
      await logsOf(tCard),
      unorderedEquals(<String>[ruleId, nativeId]),
      reason: 'one log per review, under the ids the target already has',
    );
    // 只有原生日志被沿用到目标 ID（revlog 的规则 ID 本来就等于目标的）。
    expect(merged.aliasedIds, 1);
    expect((await merge()).appliedEvents, 0);
    expect(await logsOf(tCard), hasLength(2));
  });

  // BUG-4217 回归：恢复备份写出的「重放副本」照抄了 ankiRevlogId / 种类 / 发生时刻（restore_plan.dart `_replayOf`），
  // 只换了 ID 与 HLC。规则 ID 若套到副本上，副本就和已被 undo 撤销的原日志撞成同一个 ID：只并一份、undo 指向它，
  // 这次复习整条消失。规则只认「自身身份就是那次导入」的日志（HLC 等于导入规则的 HLC、没有 replayOf）。
  // R（撤销）与 R'（重放）走真实的恢复计划（fushi_srs `srsPlanRevokeLogs` / `srsPlanStateRestore`），不手抄副本形状。
  test('导入 revlog / 锚点被恢复撤销、又被恢复重放：合并后有效历史与卡片状态不变，重放副本没被撤销', () async {
    final _Device b = await _Device.open('host');
    final String bOld = b.store.profileUid;
    const String target = '01900000-0000-7000-8000-0000000000cc';
    final String note = await b.store.createNote(
      noteTypeId: b.store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(bOld, 'Expression'): '雪',
        srsLapisFieldId(bOld, 'MainDefinition'): 'snow',
      },
      guid: 'anki-guid-replay',
    );
    final String card = (await b.store.cardsOfNote(note)).single.id;
    const int revlog = 1792403304283;
    const SrsScheduleResult afterImport = SrsScheduleResult(
      queue: SrsQueue.review,
      dueDay: 20750,
      scheduledDays: 4,
      reps: 1,
      lastReviewedAt: revlog,
    );
    final SrsReviewLog original = SrsReviewLog(
      id: SrsIds.importedRevlog(card, revlog),
      profileUid: bOld,
      cardId: card,
      kind: SrsLogKind.review,
      rating: 3,
      hlc: srsImportedRevlogHlc(revlog),
      occurredAt: revlog,
      timeSource: SrsTimeSource.wall,
      origin: SrsLogOrigin.anki,
      reviewType: 'review',
      algorithm: 'anki',
      result: afterImport,
      ankiRevlogId: revlog,
    );
    final SrsReviewLog anchor = SrsReviewLog(
      id: SrsIds.importAnchor(card, revlog),
      profileUid: bOld,
      cardId: card,
      kind: SrsLogKind.importAnchor,
      hlc: srsImportAnchorHlc(revlog),
      occurredAt: revlog,
      timeSource: SrsTimeSource.wall,
      origin: SrsLogOrigin.anki,
      reviewType: SrsReviewType.manual,
      result: afterImport,
    );
    await b.store.applyRemote(<SrsEvent>[
      SrsLogEvent(original),
      SrsLogEvent(anchor),
    ]);

    int nowMs = 1792500000000;
    final SrsLogContext ctx = SrsLogContext(
      profileUid: bOld,
      clock: HlcClock('host#1'),
      now: () => (nowMs, SrsTimeSource.wall),
      day: const SrsDayContext(utcOffsetMin: 0, rolloverHour: 4),
    );
    // R：恢复到导入前的备份（备份里没有这两条）→ 逐条 undo。
    final List<SrsReviewLog> undos = srsPlanRevokeLogs(
      logs: (await b.store.history(card)).all,
      backupLogIds: const <String>{},
      ctx: ctx,
      backupId: 'backup-before',
    );
    expect(<String?>[
      for (final SrsReviewLog l in undos) l.revokesId,
    ], unorderedEquals(<String>[original.id, anchor.id]));
    await b.store.applyRemote(<SrsEvent>[
      for (final SrsReviewLog l in undos) SrsLogEvent(l),
    ]);
    // R'：再恢复到导入后的备份（备份里有这两条，但它们已被 R 永久撤销）→ 重放副本。
    nowMs = 1792600000000;
    final List<SrsReviewLog> replays = srsPlanStateRestore(
      cardId: card,
      current: await b.store.history(card),
      backupLogIds: <String>{original.id, anchor.id},
      ctx: ctx,
      backupId: 'backup-after',
    );
    expect(
      <Object?>[
        for (final SrsReviewLog l in replays) l.extra[srsReplayOfLogExtraKey],
      ],
      unorderedEquals(<String>[original.id, anchor.id]),
      reason:
          'the restore planner takes the replay tier, not the manual fallback',
    );
    for (final SrsReviewLog l in replays) {
      expect(l.ankiRevlogId == null, l.kind == SrsLogKind.importAnchor);
    }
    await b.store.applyRemote(<SrsEvent>[
      for (final SrsReviewLog l in replays) SrsLogEvent(l),
    ]);
    final SrsCardHistory before = await b.store.history(card);
    expect(before.all, hasLength(6));
    expect(before.effective, hasLength(2), reason: 'the replay copies count');
    expect(before.state.queue, SrsQueue.review);

    await srsMergeProfileUid(
      b.db,
      b.srs.db,
      core: b.srs.core,
      profileId: b.profileId,
      oldUid: bOld,
      newUid: target,
      deviceId: b.deviceId,
    );
    await b.reopen();
    await b.store.afterRestore(freshIncarnation: true);
    final String newNote = SrsIds.note(target, 'anki-guid-replay');
    final String newCard = (await b.store.cardsOfNote(newNote)).single.id;
    final SrsCardHistory after = await b.store.history(newCard);
    expect(after.all, hasLength(6), reason: 'every log lands once');
    expect(
      <String>[for (final SrsReviewLog l in after.effective) l.kind],
      <String>[for (final SrsReviewLog l in before.effective) l.kind],
    );
    for (final SrsReviewLog l in after.effective) {
      expect(
        l.extra[srsReplayOfLogExtraKey],
        isNotNull,
        reason: 'the effective logs are still the replay copies',
      );
      expect(after.revoked, isNot(contains(l.id)));
    }
    expect(after.state, before.state);
    // 原日志仍按规则 ID（新卡片）落下，被撤销的正是它们。
    expect(
      after.revoked,
      containsAll(<String>[
        SrsIds.importedRevlog(newCard, revlog),
        SrsIds.importAnchor(newCard, revlog),
      ]),
    );
  });

  // [seededChain] 的原生日志：评分（[revokes] = null）或撤销 [revokes] 的 undo。
  SrsReviewLog chainLog(
    String uid,
    String card,
    String id,
    int at, {
    String? revokes,
  }) => SrsReviewLog(
    id: id,
    profileUid: uid,
    cardId: card,
    kind: revokes == null ? SrsLogKind.review : SrsLogKind.undo,
    rating: revokes == null ? 3 : null,
    revokesId: revokes,
    hlc: Hlc(at, 0, 'phone#1'),
    occurredAt: at,
    timeSource: SrsTimeSource.wall,
    origin: SrsLogOrigin.fushi,
    reviewType: revokes == null ? 'review' : SrsReviewType.manual,
  );

  // 一个旧 profile 里一张卡的三条原生日志（评分 r1、评分 r2、撤销 r2 的 undo）+ 三条同一写入者的修改记录。
  // [withRevoked] = false：r2 还没同步到这台设备，只有撤销它的 undo（同步顺序不保证）。
  Future<_Device> seededChain(
    String deviceId, {
    bool withRevoked = true,
  }) async {
    const String guid = 'anki-guid-chain';
    const int t0 = _kChainT0;
    final _Device d = await _Device.open(deviceId);
    final String uid = d.store.profileUid;
    final String note = await d.store.createNote(
      noteTypeId: d.store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(uid, 'Expression'): '霧',
        srsLapisFieldId(uid, 'MainDefinition'): 'fog',
      },
      guid: guid,
    );
    final String card = (await d.store.cardsOfNote(note)).single.id;
    SrsReviewLog native(String id, int at, {String? revokes}) =>
        chainLog(uid, card, id, at, revokes: revokes);
    await d.store.applyRemote(<SrsEvent>[
      for (int i = 1; i <= 3; i++)
        SrsEditEvent(
          SrsFieldEdit(
            profileUid: uid,
            entityKind: SrsEntityKind.deck,
            entityId: SrsIds.builtinDefaultDeck(uid),
            fieldKey: 'x/$i',
            dot: SrsDot('phone#1', i),
            ctx: SrsCausalContext.empty(),
            value: 'v$i',
            hlc: Hlc(t0 + i, 0, 'phone#1'),
            timeSource: SrsTimeSource.wall,
          ),
        ),
      SrsLogEvent(native(_kChainR1, t0 + 10)),
      if (withRevoked) SrsLogEvent(native(_kChainR2, t0 + 20)),
      SrsLogEvent(native(_kChainUndo, t0 + 30, revokes: _kChainR2)),
    ]);
    return d;
  }

  Future<void> mergeInto(_Device d, String newUid) async {
    await srsMergeProfileUid(
      d.db,
      d.srs.db,
      core: d.srs.core,
      profileId: d.profileId,
      oldUid: d.store.profileUid,
      newUid: newUid,
      deviceId: d.deviceId,
    );
    await d.reopen();
    await d.store.afterRestore(freshIncarnation: true);
  }

  Future<String> chainCardIn(_Device d, String uid) async =>
      (await d.store.cardsOfNote(
        SrsIds.note(uid, 'anki-guid-chain'),
      )).single.id;

  // 有效历史的内容（不比 ID：链式与直接合并给原生日志的 ID 可以不同，读侧按内容身份合并副本，BUG-4218）。
  List<String> effectiveShape(SrsCardHistory h) => <String>[
    for (final SrsReviewLog l in h.effective)
      '${l.kind}|${l.rating}|${l.occurredAt}|${l.hlc.encode()}|${l.revokesId}',
  ];

  // 写入者名字只取决于最初的写入者（不取决于上一跳的名字）：A→B→C 链式合并与 A→C 直接合并的修改记录同 dot、同 ID，
  // 不会落成两份。原生日志的兜底 ID 按旧 ID 算、与路径有关（见 srs_profile_merge.dart 第 7 步 b），两条路径的副本
  // 在同一个集合里相遇时由读侧按内容身份合并：有效历史与只走一条路径时相同。
  test('链式合并 A→B→C 与直接合并 A→C：写入者名字相同；两条路径的日志副本相遇后有效历史不变', () async {
    const String b = '01900000-0000-7000-8000-0000000000e1';
    const String c = '01900000-0000-7000-8000-0000000000e2';

    Future<List<String>> writersOf(_Device d) async => <String>[
      for (final QueryRow r
          in await d.srs.db
              .customSelect(
                'SELECT field_key AS k, srs_idt(writer_id) AS w '
                "FROM srs_field_edits WHERE profile_uid = ? AND field_key LIKE 'x/%' "
                'ORDER BY k',
                variables: <Variable<Object>>[Variable<String>(c, srsIdType)],
              )
              .get())
        '${r.read<String>('k')} ${r.read<String>('w')}',
    ];

    final _Device chained = await seededChain('chained');
    await mergeInto(chained, b);
    await mergeInto(chained, c);
    final _Device direct = await seededChain('direct');
    await mergeInto(direct, c);

    final List<String> writers1 = await writersOf(chained);
    final List<String> writers2 = await writersOf(direct);
    expect(writers1, hasLength(3));
    for (final String w in writers1) {
      expect(w, contains(' $kSrsMergedWriterPrefix'));
    }
    expect(
      writers1,
      writers2,
      reason: 'writer names do not depend on the merge path',
    );

    final String card = await chainCardIn(chained, c);
    expect(await chainCardIn(direct, c), card);
    final SrsCardHistory h1 = await chained.store.history(card);
    final SrsCardHistory h2 = await direct.store.history(card);
    expect(h1.all, hasLength(3));
    expect(h1.effective, hasLength(1));
    expect(effectiveShape(h1), effectiveShape(h2));
    expect(h1.state, h2.state);

    // 先只收到链式那份 r2（撤销它的 undo 还没到）：它与直接那份 r2 是同一次复习，读侧按内容身份归成一组，直接那份
    // 已被撤销，整组都算撤销——r2 不会借链式那份 ID 复活。
    final SrsReviewLog chainedR2 = h1.all.singleWhere(
      (SrsReviewLog l) =>
          l.kind == SrsLogKind.review && h1.revoked.contains(l.id),
    );
    expect(chainedR2.occurredAt, _kChainT0 + 20);
    expect(
      h2.all.map((SrsReviewLog l) => l.id),
      isNot(contains(chainedR2.id)),
      reason: 'the chained copy of r2 has its own id',
    );
    await direct.store.applyRemote(<SrsEvent>[SrsLogEvent(chainedR2)]);
    final SrsCardHistory onlyR2 = await direct.store.history(card);
    expect(onlyR2.all, hasLength(4));
    expect(
      onlyR2.effective.map((SrsReviewLog l) => l.id),
      isNot(contains(chainedR2.id)),
    );
    expect(onlyR2.revoked, contains(chainedR2.id));
    expect(effectiveShape(onlyR2), effectiveShape(h2));
    expect(onlyR2.state, h2.state);

    // 两条路径的副本同步到一起（同一个目标集合里一次复习两个 ID）：读侧选出的有效历史与只有一条路径时相同，
    // 被撤销的那次复习两份都算撤销。
    await direct.store.applyRemote(<SrsEvent>[
      for (final SrsReviewLog l in h1.all) SrsLogEvent(l),
    ]);
    final SrsCardHistory union = await direct.store.history(card);
    expect(
      union.all.length,
      greaterThan(3),
      reason: 'the two paths gave native logs different ids (copies meet)',
    );
    expect(effectiveShape(union), effectiveShape(h2));
    expect(union.state, h2.state);
  });

  // undo 的目标不在本机旧 profile 里（同步顺序不保证，undo 先到）：这台设备给不出与有目标的设备一致的 revokes——有
  // 目标的设备按导入规则 / 目标沿用给 ID，看不到内容只能按旧 ID 兜底，同一条 undo（同 ID）两份内容、先到先得，被撤销
  // 的复习可能复活（审查 PR #3004 先后发现的两个变体）。所以并入暂缓（SrsProfileMergeDeferred，任何落库之前），等同步
  // 把那条日志送进旧 profile 后重跑；重跑后两台设备写出的 undo 逐字段相同。
  Future<Map<String, SrsReviewLog>> logsOfCard(_Device d, String uid) async =>
      <String, SrsReviewLog>{
        for (final SrsReviewLog l in (await d.store.history(
          await chainCardIn(d, uid),
        )).all)
          l.id.toLowerCase(): l,
      };

  String fallbackIn(String uid, String oldId) =>
      uuidV5(srsNamespace, 'profile-merge/$uid/${oldId.toLowerCase()}');

  Future<int> logRowsUnder(_Device d, String uid) async =>
      (await d.srs.db
              .customSelect(
                'SELECT (SELECT COUNT(*) FROM srs_review_logs WHERE profile_uid = ?) + '
                '(SELECT COUNT(*) FROM sync2_log_meta WHERE profile_uid = ?) AS c',
                variables: <Variable<Object>>[
                  Variable<String>(uid, srsIdType),
                  Variable<String>(uid, srsIdType),
                ],
              )
              .getSingle())
          .read<int>('c');

  /// [d] 并入 [newUid] 必须暂缓：抛 [SrsProfileMergeDeferred]（缺的正是 [missing]），profiles.uid、旧 uid 的行、目标下的
  /// 日志都不动，并入标记留着。
  Future<void> expectDeferred(_Device d, String newUid, String missing) async {
    final String old = d.store.profileUid;
    final int before = await d.rowsOf(old);
    await expectLater(
      srsMergeProfileUid(
        d.db,
        d.srs.db,
        core: d.srs.core,
        profileId: d.profileId,
        oldUid: old,
        newUid: newUid,
        deviceId: d.deviceId,
      ),
      throwsA(
        isA<SrsProfileMergeDeferred>()
            .having(
              (SrsProfileMergeDeferred e) => e.missingRevoked,
              'missingRevoked',
              <String>[missing.toLowerCase()],
            )
            .having(
              (SrsProfileMergeDeferred e) => e.message,
              'message',
              contains('deferred'),
            ),
      ),
    );
    expect(await d.db.profileUidOf(d.profileId), old);
    expect(await d.rowsOf(old), before, reason: 'old rows untouched');
    expect(await logRowsUnder(d, newUid), 0, reason: 'nothing merged');
    final List<SrsPendingProfileMerge> pending = await srsPendingProfileMerges(
      d.srs.db,
    );
    expect(pending, hasLength(1));
    expect(pending.single.oldUid, old);
    expect(pending.single.newUid, newUid);
  }

  test('undo 的目标（原生日志）还没同步到：并入暂缓、什么都不写；目标到了再并，两台设备的 undo 逐字段相同', () async {
    const String c = '01900000-0000-7000-8000-0000000000e3';
    final _Device full = await seededChain('full');
    final _Device partial = await seededChain('partial', withRevoked: false);
    await mergeInto(full, c);
    await expectDeferred(partial, c, _kChainR2);

    // 同步把 r2 送进旧 profile（旧 uid 照常同步），重跑并入。
    final String pOld = partial.store.profileUid;
    final String pCard = (await partial.store.cardsOfNote(
      SrsIds.note(pOld, 'anki-guid-chain'),
    )).single.id;
    await partial.store.applyRemote(<SrsEvent>[
      SrsLogEvent(chainLog(pOld, pCard, _kChainR2, _kChainT0 + 20)),
    ]);
    await mergeInto(partial, c);
    expect(await srsPendingProfileMerges(partial.srs.db), isEmpty);

    final Map<String, SrsReviewLog> a = await logsOfCard(full, c);
    final Map<String, SrsReviewLog> p = await logsOfCard(partial, c);
    final SrsReviewLog undoFull = a[fallbackIn(c, _kChainUndo)]!;
    final SrsReviewLog undoPartial = p[fallbackIn(c, _kChainUndo)]!;
    expect(undoFull.revokesId, fallbackIn(c, _kChainR2));
    expect(undoPartial.toJson(), undoFull.toJson());
    for (final _Device d in <_Device>[full, partial]) {
      final SrsCardHistory h = await d.store.history(await chainCardIn(d, c));
      expect(h.revoked, contains(fallbackIn(c, _kChainR2)));
      expect(h.effective, hasLength(1));
    }
  });

  // 目标里已经有别的设备按兜底 ID 并好的那条日志（这台设备并入前先收了目标的数据）：本机算出的 revokes 正指向它，
  // 不用等。
  test('undo 的目标不在旧 profile 里、但已按兜底 ID 在目标里：不暂缓，undo 撤销的就是目标里那条', () async {
    const String c = '01900000-0000-7000-8000-0000000000e4';
    final _Device full = await seededChain('full');
    final _Device partial = await seededChain('partial', withRevoked: false);
    await mergeInto(full, c);
    expect((await full.round(dir)).error, isNull);

    await srsMergeProfileUid(
      partial.db,
      partial.srs.db,
      core: partial.srs.core,
      profileId: partial.profileId,
      oldUid: partial.store.profileUid,
      newUid: c,
      deviceId: partial.deviceId,
      pullTarget: (SrsDbStore t) async {
        expect(
          await srsSync2PullWithin(
            t,
            (SrsSync2Host h) async {
              final SrsSync2Report r = await srsSync2PullOnly(
                host: h,
                location: SrsAssetLocationStore(store: dir, profileUid: c),
                locationId: 'interconnect:host',
                nowMs: () => t.now().$1,
              );
              expect(r.error, isNull);
            },
            budget: kSrsPullBeforeMergeBudget,
            onError: (Object e, StackTrace s) => fail('$e'),
          ),
          isTrue,
        );
      },
    );
    await partial.reopen();
    final SrsCardHistory h = await partial.store.history(
      await chainCardIn(partial, c),
    );
    expect(h.revoked, contains(fallbackIn(c, _kChainR2)));
    expect(
      h.effective.map((SrsReviewLog l) => l.id),
      isNot(contains(fallbackIn(c, _kChainR2))),
    );
  });

  // 同一个变体落在 Anki 导入日志上：有目标的设备按导入规则给它 UUIDv5(新卡片, anki-revlog/<id>)，没有的设备若按旧 ID
  // 兜底，同一条 undo 就撤销一个没有日志的 ID，导入的那次复习复活。暂缓后等目标到了再并，undo 撤销的是规则 ID。
  test('undo 撤销的 Anki 导入 revlog 还没同步到：并入暂缓；到了以后两台设备的 undo 都撤销规则 ID', () async {
    const String c = '01900000-0000-7000-8000-0000000000e5';
    const int revlog = 1792403304283;
    const String undoId = '019a3a0b-0000-7000-8000-0000000000f9';

    Future<(_Device, String, SrsReviewLog)> seeded(
      String deviceId, {
      required bool withRevoked,
    }) async {
      final _Device d = await _Device.open(deviceId);
      final String uid = d.store.profileUid;
      final String note = await d.store.createNote(
        noteTypeId: d.store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(uid, 'Expression'): '霧',
          srsLapisFieldId(uid, 'MainDefinition'): 'fog',
        },
        guid: 'anki-guid-chain',
      );
      final String card = (await d.store.cardsOfNote(note)).single.id;
      final SrsReviewLog imported = SrsReviewLog(
        id: SrsIds.importedRevlog(card, revlog),
        profileUid: uid,
        cardId: card,
        kind: SrsLogKind.review,
        rating: 3,
        hlc: srsImportedRevlogHlc(revlog),
        occurredAt: revlog,
        timeSource: SrsTimeSource.wall,
        origin: SrsLogOrigin.anki,
        reviewType: 'review',
        ankiRevlogId: revlog,
      );
      await d.store.applyRemote(<SrsEvent>[
        if (withRevoked) SrsLogEvent(imported),
        SrsLogEvent(
          chainLog(uid, card, undoId, revlog + 5000, revokes: imported.id),
        ),
      ]);
      return (d, uid, imported);
    }

    final (_Device full, String _, SrsReviewLog _) = await seeded(
      'full',
      withRevoked: true,
    );
    final (_Device partial, String _, SrsReviewLog imported) = await seeded(
      'partial',
      withRevoked: false,
    );
    await mergeInto(full, c);
    await expectDeferred(partial, c, imported.id);

    await partial.store.applyRemote(<SrsEvent>[SrsLogEvent(imported)]);
    await mergeInto(partial, c);

    final String newCard = await chainCardIn(full, c);
    expect(await chainCardIn(partial, c), newCard);
    final String rule = SrsIds.importedRevlog(newCard, revlog);
    final Map<String, SrsReviewLog> a = await logsOfCard(full, c);
    final Map<String, SrsReviewLog> p = await logsOfCard(partial, c);
    final SrsReviewLog undoFull = a[fallbackIn(c, undoId)]!;
    final SrsReviewLog undoPartial = p[fallbackIn(c, undoId)]!;
    expect(undoFull.revokesId, rule);
    expect(undoPartial.toJson(), undoFull.toJson());
    for (final _Device d in <_Device>[full, partial]) {
      final SrsCardHistory h = await d.store.history(newCard);
      expect(h.revoked, contains(rule));
      expect(h.effective, isEmpty, reason: 'the revoked import stays revoked');
    }
  });

  // 暂缓经 link 层：不抛、不卡同步，日志里标成暂缓且同一批缺口只记一次；目标到了下一次 link 就把并入做完。
  test('并入暂缓经 link：不抛、同步照跑、只记一次；目标日志到了下一轮做完并入', () async {
    const String c = '01900000-0000-7000-8000-0000000000e6';
    final _Device b = await seededChain('host', withRevoked: false);
    final String bOld = b.store.profileUid;
    await expectDeferred(b, c, _kChainR2);

    final List<(String, Object)> errors = <(String, Object)>[];
    final SrsDbProfileLinker linker = SrsDbProfileLinker(
      db: b.db,
      activeProfileId: () async => b.profileId,
      reopenStore: () async => b.reopen(),
      onError: (String where, Object e, StackTrace _) => errors.add((where, e)),
    );
    for (int i = 1; i <= 2; i++) {
      final SrsProfileLinkOutcome out = await linker.link(dir, b.store);
      expect(out.store, same(b.store), reason: 'round $i keeps the old store');
      expect(errors, hasLength(1), reason: 'the same gap is logged once');
      expect(
        errors.single.$1,
        allOf(contains('deferred'), contains(bOld), contains(c)),
      );
      expect(errors.single.$2, isA<SrsProfileMergeDeferred>());
      expect((await b.round(dir)).error, isNull, reason: 'sync still runs');
    }
    expect(await srsPendingProfileMerges(b.srs.db), hasLength(1));

    final String card = (await b.store.cardsOfNote(
      SrsIds.note(bOld, 'anki-guid-chain'),
    )).single.id;
    await b.store.applyRemote(<SrsEvent>[
      SrsLogEvent(chainLog(bOld, card, _kChainR2, _kChainT0 + 20)),
    ]);
    final SrsProfileLinkOutcome out = await linker.link(dir, b.store);
    expect(out.linked, isTrue);
    expect(out.store.profileUid, c);
    expect(errors, hasLength(1));
    expect(await b.db.profileUidOf(b.profileId), c);
    expect(await srsPendingProfileMerges(b.srs.db), isEmpty);
    expect(
      (await out.store.history(await chainCardIn(b, c))).revoked,
      contains(fallbackIn(c, _kChainR2)),
    );
  });

  // 第 9 步的身份断言：两条身份不同的旧日志按规则映射到同一个新 ID（这里：同一张卡上两条「原始导入」revlog 同一个
  // Anki revlog id、评分不同）。静默只留一份会丢掉其中一次复习，所以并入中止、旧 profile 一行不动。
  Future<(_Device, int)> conflictingImports(String deviceId) async {
    final _Device d = await _Device.open(deviceId);
    final String uid = d.store.profileUid;
    final String note = await d.store.createNote(
      noteTypeId: d.store.lapisNoteTypeId,
      fieldsById: <String, String>{
        srsLapisFieldId(uid, 'Expression'): '霜',
        srsLapisFieldId(uid, 'MainDefinition'): 'frost',
      },
      guid: 'anki-guid-conflict',
    );
    final String card = (await d.store.cardsOfNote(note)).single.id;
    const int revlog = 1792403304283;
    SrsLogEvent imported(String id, int rating) => SrsLogEvent(
      SrsReviewLog(
        id: id,
        profileUid: uid,
        cardId: card,
        kind: SrsLogKind.review,
        rating: rating,
        hlc: srsImportedRevlogHlc(revlog),
        occurredAt: revlog,
        timeSource: SrsTimeSource.wall,
        origin: SrsLogOrigin.anki,
        reviewType: 'review',
        ankiRevlogId: revlog,
      ),
    );
    await d.store.applyRemote(<SrsEvent>[
      imported(SrsIds.importedRevlog(card, revlog), 3),
      imported('01900000-0000-5000-8000-0000000000d9', 1),
    ]);
    return (d, await d.rowsOf(uid));
  }

  test('两条不同的旧日志映射到同一个新 ID：抛 StateError，旧 profile 与 profiles.uid 不动', () async {
    final (_Device b, int before) = await conflictingImports('host');
    final String bOld = b.store.profileUid;
    const String target = '01900000-0000-7000-8000-0000000000d1';
    await expectLater(
      srsMergeProfileUid(
        b.db,
        b.srs.db,
        core: b.srs.core,
        profileId: b.profileId,
        oldUid: bOld,
        newUid: target,
        deviceId: b.deviceId,
      ),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('different reviews'),
        ),
      ),
    );
    expect(await b.db.profileUidOf(b.profileId), bOld);
    expect(await b.rowsOf(bOld), before);
  });

  // 第 8 步的写入者一一对应断言：旧写入者 V 按「同 seq 同 HLC」沿用目标里的写入者 N，而 N 恰好是另一个旧写入者 W
  // 按规则改出来的名字——两个旧写入者成了同一个，不同的修改记录同 dot。
  test('两个旧写入者会改成同一个名字：抛 StateError，旧 profile 与 profiles.uid 不动', () async {
    final _Device b = await _Device.open('host');
    final String bOld = b.store.profileUid;
    const String target = '01900000-0000-7000-8000-0000000000d2';
    final String taken =
        '$kSrsMergedWriterPrefix'
        '${uuidV5(srsNamespace, 'profile-merge/$target/writer/w-old#1')}~w-old#1';
    final SrsDbStore t = await SrsDbStore.open(
      db: b.srs.db,
      core: b.srs.core,
      profileUid: target,
      deviceId: b.deviceId,
      engine: const SrsFakeEngine(),
    );
    const int t0 = 1700000000000;
    SrsEditEvent edit(String uid, String w, int at, String key) => SrsEditEvent(
      SrsFieldEdit(
        profileUid: uid,
        entityKind: SrsEntityKind.deck,
        entityId: SrsIds.builtinDefaultDeck(uid),
        fieldKey: key,
        dot: SrsDot(w, 1),
        ctx: SrsCausalContext.empty(),
        value: 'v',
        hlc: Hlc(at, 0, w),
        timeSource: SrsTimeSource.wall,
      ),
    );
    await t.applyRemote(<SrsEvent>[edit(target, taken, t0 + 1, 'x/1')]);
    await b.store.applyRemote(<SrsEvent>[
      edit(bOld, 'v-old#1', t0 + 1, 'x/1'),
      edit(bOld, 'w-old#1', t0 + 50, 'y/1'),
    ]);
    final int before = await b.rowsOf(bOld);
    await expectLater(
      srsMergeProfileUid(
        b.db,
        b.srs.db,
        core: b.srs.core,
        profileId: b.profileId,
        oldUid: bOld,
        newUid: target,
        deviceId: b.deviceId,
      ),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('would both become $taken'),
        ),
      ),
    );
    expect(await b.db.profileUidOf(b.profileId), bOld);
    expect(await b.rowsOf(bOld), before);
  });

  // 并入标记在计划之前就写进 srs.db：计划阶段的断言失败后，之后每次 link 都会重跑这次并入。以前重跑再抛，整个复习
  // 同步永久卡死；现在 link 记错（onError → ErrorLogService）、跳过这次并入，按当前 uid 继续同步，标记留着下轮再试。
  test('并入在计划阶段失败：link 不再每轮抛出，记错后按当前 uid 继续同步，标记留着重试', () async {
    final (_Device b, int before) = await conflictingImports('host');
    final String bOld = b.store.profileUid;
    const String target = '01900000-0000-7000-8000-0000000000d3';
    await expectLater(
      srsMergeProfileUid(
        b.db,
        b.srs.db,
        core: b.srs.core,
        profileId: b.profileId,
        oldUid: bOld,
        newUid: target,
        deviceId: b.deviceId,
      ),
      throwsStateError,
    );
    expect(await srsPendingProfileMerges(b.srs.db), hasLength(1));

    final List<(String, Object)> errors = <(String, Object)>[];
    final SrsDbProfileLinker linker = SrsDbProfileLinker(
      db: b.db,
      activeProfileId: () async => b.profileId,
      reopenStore: () async => b.reopen(),
      onError: (String where, Object e, StackTrace _) => errors.add((where, e)),
    );
    for (int i = 1; i <= 2; i++) {
      final SrsProfileLinkOutcome out = await linker.link(dir, b.store);
      expect(out.store, same(b.store), reason: 'round $i keeps the old store');
      expect(errors, hasLength(i));
      expect(errors.last.$1, allOf(contains(bOld), contains(target)));
      expect(errors.last.$2, isA<StateError>());
      expect((await b.round(dir)).error, isNull, reason: 'sync still runs');
    }
    expect(await b.db.profileUidOf(b.profileId), bOld);
    expect(await srsPendingProfileMerges(b.srs.db), hasLength(1));
    // 同步只会给旧 uid 加本设备的 sync2 行，旧 profile 的数据一行不少。
    expect(await b.rowsOf(bOld), greaterThanOrEqualTo(before));
  });

  // BUG-4011 端到端：目标 uid 的数据只在同步位置上（另一台设备 A 迁出 / 写入的），本机 B 切到这个 uid 并入。并入前
  // 先只拉不发一轮（[srsMergeProfileUid] 的 pullTarget），合并就看得到目标里已有的同一批修改记录，不再改名造第二份。
  for (final bool pullFirst in <bool>[true, false]) {
    test(
      pullFirst
          ? '切 uid 并入前先收目标数据：同一批修改记录不再产生 merged- 写入者'
          : '对照：不先收目标数据，同一批修改记录改名成 merged- 落第二份',
      () async {
        final _Device a = await _Device.open('A');
        final _Device b = await _Device.open('B');
        final String target = a.store.profileUid;
        final String bOld = b.store.profileUid;
        const int t0 = 1700000000000;
        SrsEditEvent legacy(String uid, String w, int seq) => SrsEditEvent(
          SrsFieldEdit(
            profileUid: uid,
            entityKind: SrsEntityKind.deck,
            entityId: SrsIds.builtinDefaultDeck(uid),
            fieldKey: 'x/$seq',
            dot: SrsDot(w, seq),
            ctx: SrsCausalContext.empty(),
            value: 'v$seq',
            hlc: Hlc(t0 + seq, 0, w),
            timeSource: SrsTimeSource.wall,
          ),
        );
        await a.store.applyRemote(<SrsEvent>[
          for (int i = 1; i <= 3; i++) legacy(target, 'their#1', i),
        ]);
        expect((await a.round(dir)).error, isNull);
        await b.store.applyRemote(<SrsEvent>[
          for (int i = 1; i <= 3; i++) legacy(bOld, 'host-old#1', i),
        ]);

        await srsMergeProfileUid(
          b.db,
          b.srs.db,
          core: b.srs.core,
          profileId: b.profileId,
          oldUid: bOld,
          newUid: target,
          deviceId: b.deviceId,
          pullTarget: pullFirst
              ? (SrsDbStore t) async {
                  expect(
                    await srsSync2PullWithin(
                      t,
                      (SrsSync2Host h) async {
                        final SrsSync2Report r = await srsSync2PullOnly(
                          host: h,
                          location: SrsAssetLocationStore(
                            store: dir,
                            profileUid: target,
                          ),
                          locationId: 'interconnect:host',
                          nowMs: () => t.now().$1,
                        );
                        expect(r.error, isNull);
                        expect(r.applied, greaterThan(0));
                      },
                      budget: kSrsPullBeforeMergeBudget,
                      onError: (Object e, StackTrace s) => fail('$e'),
                    ),
                    isTrue,
                  );
                }
              : null,
        );
        final List<QueryRow> rows = await b.srs.db
            .customSelect(
              'SELECT srs_idt(writer_id) AS w FROM srs_field_edits '
              "WHERE profile_uid = ? AND field_key LIKE 'x/%'",
              variables: <Variable<Object>>[
                Variable<String>(target, srsIdType),
              ],
            )
            .get();
        final List<String> writers = <String>[
          for (final QueryRow r in rows) r.read<String>('w'),
        ];
        final int merged = writers
            .where((String w) => w.startsWith(kSrsMergedWriterPrefix))
            .length;
        if (pullFirst) {
          expect(merged, 0, reason: '$writers');
          expect(writers, <String>['their#1', 'their#1', 'their#1']);
        } else {
          expect(merged, 3, reason: '$writers');
        }
      },
    );
  }
}

/// 设备上唯一一条笔记的 guid（按缓存表读，不经 uid）。
Future<String> _guidOfOnly(_Device d) async =>
    (await d.srs.db
            .customSelect(
              'SELECT guid FROM srs_notes_cache WHERE profile_uid = ?',
              variables: <Variable<Object>>[
                Variable<String>(d.store.profileUid, srsIdType),
              ],
            )
            .getSingle())
        .read<String>('guid');

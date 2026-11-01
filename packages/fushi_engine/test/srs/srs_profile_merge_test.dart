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
import 'package:fushi_engine/srs/srs_profile_merge.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/srs/sync2/srs_location_store.dart';
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

// AnkiConnect 兼容层的增量状态（HBK-AUDIT-017 / L-5）：搜索语料、查重索引常驻原生浏览会话
// （native/fushi_fsrs/src/store/browse.rs），按写入增量更新；在每类变更之后都必须与「什么都不常驻、整份重读」
// 的结果逐字节相同。
//
// 判据：同一个 store 上，一直用着的 handler（会话、语料、查重索引在变更前已经建好，变更后只增量补读）先回答
// 整组请求；然后关掉原生会话（`browse_close`），新建的 handler 在整份重建的会话上再回答一遍，两边相同。
// 变更都绕过 handler 直接打在 store 上（同步、复习页、浏览页、导入都是这样写库的）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../support/srs_bulk_fixture.dart';
import '../support/srs_fake_engine.dart';
import '../support/srs_query_counter.dart';
import '../support/srs_test_storage.dart';
import 'ankiconnect_harness.dart' show kAcProfile, yomitanNote;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SrsDbStore store;
  late SrsAnkiConnectHandler resident;
  late int t;

  SrsAnkiConnectHandler fresh() =>
      SrsAnkiConnectHandler(store: () async => store, instanceId: 'oracle');

  Future<Object?> call(
    SrsAnkiConnectHandler h,
    String action,
    Map<String, Object?> params,
  ) => h.handle(<String, Object?>{
    'action': action,
    'version': 6,
    'params': params,
  });

  Future<Object?> ok(String action, Map<String, Object?> params) async {
    final Map<String, Object?> r =
        (await call(resident, action, params))! as Map<String, Object?>;
    if (r['error'] != null) throw StateError('$action: ${r['error']}');
    return r['result'];
  }

  /// 覆盖标签、模板、状态、到期数值列、牌组名、字段文本的一组查询。
  const List<String> queries = <String>[
    'deck:*',
    'deck:Default',
    'deck:Renamed',
    'tag:t0',
    'tag:moved',
    'is:new',
    'is:learn',
    'is:review',
    'is:due',
    'is:suspended',
    'is:buried',
    'card:1',
    'card:Renamed*',
    'prop:ivl>=1',
    'prop:due<=0',
    'prop:due>0',
    'prop:reps>0',
    'Expression:猫*',
    'Expression:改*',
    '猫',
  ];

  List<Map<String, Object?>> candidates() => <Map<String, Object?>>[
    for (final String w in <String>['猫0', '猫1', '猫2', '改名', '新', '外'])
      yomitanNote(w, allowDuplicate: false),
    yomitanNote(
      '猫3',
      allowDuplicate: false,
      duplicateScope: 'deck',
      deck: 'Default',
    ),
  ];

  /// 常驻 handler 与新 handler 对整组请求的回答相同（findCards / findNotes / canAddNotes /
  /// notesInfo / cardsInfo / getTags / deckNames）。
  Future<void> expectSameAsFresh(String label) async {
    Future<List<(String, Map<String, Object?>, Object?)>> answers(
      SrsAnkiConnectHandler h,
    ) async {
      final List<(String, Map<String, Object?>, Object?)> out =
          <(String, Map<String, Object?>, Object?)>[];
      Future<void> ask(String action, Map<String, Object?> params) async =>
          out.add((action, params, await call(h, action, params)));
      for (final String q in queries) {
        await ask('findCards', <String, Object?>{'query': q});
        await ask('findNotes', <String, Object?>{'query': q});
      }
      await ask('canAddNotesWithErrorDetail', <String, Object?>{
        'notes': candidates(),
      });
      final Map<String, Object?> all =
          (await call(h, 'findCards', <String, Object?>{'query': 'deck:*'}))!
              as Map<String, Object?>;
      await ask('cardsInfo', <String, Object?>{'cards': all['result']});
      final Map<String, Object?> notes =
          (await call(h, 'findNotes', <String, Object?>{'query': 'deck:*'}))!
              as Map<String, Object?>;
      await ask('notesInfo', <String, Object?>{'notes': notes['result']});
      await ask('getTags', <String, Object?>{});
      await ask('deckNamesAndIds', <String, Object?>{});
      return out;
    }

    final List<(String, Map<String, Object?>, Object?)> got = await answers(
      resident,
    );
    // 原生会话整份丢掉：新 handler 的回答来自整份重建的语料与查重索引。
    await store.browseCommand(<String, Object?>{'op': 'browse_close'});
    final List<(String, Map<String, Object?>, Object?)> want = await answers(
      fresh(),
    );
    expect(got.length, want.length);
    for (int i = 0; i < got.length; i++) {
      expect(
        got[i].$3,
        want[i].$3,
        reason: '$label: ${want[i].$1} ${want[i].$2}',
      );
    }
  }

  setUp(() async {
    final SrsStorage srs = await openTestSrsStorage();
    t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    store = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kAcProfile,
      deviceId: 'dev',
      engine: const SrsFakeEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => t,
        bootClockMs: () => t,
        bootId: 'boot',
      ),
      fallbackRolloverHour: () => 4,
    );
    resident = SrsAnkiConnectHandler(
      store: () async => store,
      instanceId: 'resident',
    );
    // 默认牌组的学习步长 60 分钟 / 1 天：「重来」后的学习卡在 40 分钟后才翻成到期。
    await store.editField(
      SrsEntityKind.deck,
      store.defaultDeckId,
      SrsFieldKeys.deckSteps,
      <String, Object?>{
        'learn': <double>[60, 1440],
        'relearn': <double>[60],
      },
    );
    final List<Object?> ids =
        (await ok('addNotes', <String, Object?>{
              'notes': <Map<String, Object?>>[
                for (int i = 0; i < 12; i++)
                  yomitanNote('猫$i', tags: <String>['t${i % 3}']),
              ],
            }))!
            as List<Object?>;
    expect(ids.whereType<int>(), hasLength(12));
    t += 1000;
    // 常驻状态（快照、语料、查询记忆、查重索引）在变更前全部建好。
    await expectSameAsFresh('warm');
  });

  Future<List<String>> noteIdsByQuery(String q) async {
    final List<String> out = <String>[];
    for (final Object? n
        in (await ok('findNotes', <String, Object?>{'query': q}))!
            as List<Object?>) {
      out.add((await store.noteIdForAnkiNumericId(n! as int))!);
    }
    return out;
  }

  Future<List<String>> cardIdsByQuery(String q) async {
    final List<String> out = <String>[];
    for (final Object? n
        in (await ok('findCards', <String, Object?>{'query': q}))!
            as List<Object?>) {
      out.add((await store.cardIdForAnkiNumericId(n! as int))!);
    }
    return out;
  }

  test('在 handler 之外建的笔记：整数 id 立即可查，搜索 / 查重立即看到', () async {
    final String typeId = (await store.noteTypes())
        .firstWhere((SrsNoteTypeView v) => v.name == 'Lapis')
        .id;
    final String id = await store.createNote(
      noteTypeId: typeId,
      fieldsById: <String, String>{
        srsLapisFieldId(kAcProfile, 'Expression'): '外',
      },
      tags: <String>['moved'],
    );
    final Map<String, Object?> info =
        ((await ok('notesInfo', <String, Object?>{
                      'notes': <int>[SrsIds.ankiNumericId(id)],
                    }))!
                    as List<Object?>)
                .single!
            as Map<String, Object?>;
    expect(info['noteId'], SrsIds.ankiNumericId(id));
    await expectSameAsFresh('createNote');
  });

  test('标签 / 字段 / 暂停 / 牌组 / 删除', () async {
    final List<String> notes = await noteIdsByQuery('deck:*');
    await store.editFieldsBatch(<SrsFieldChange>[
      SrsFieldChange(
        SrsEntityKind.note,
        notes[0],
        SrsFieldKeys.noteTags,
        <String>['moved'],
      ),
    ]);
    await expectSameAsFresh('tags');

    // 首字段改了：旧值不再算重复、新值算重复。
    await store.updateNote(
      notes[1],
      fieldsById: <String, String>{
        srsLapisFieldId(kAcProfile, 'Expression'): '改名',
      },
    );
    await expectSameAsFresh('first field');

    final List<String> cards = await cardIdsByQuery('deck:*');
    await store.editField(
      SrsEntityKind.card,
      cards[2],
      SrsFieldKeys.suspended,
      true,
    );
    await expectSameAsFresh('suspend');

    await store.editField(
      SrsEntityKind.deck,
      store.defaultDeckId,
      SrsFieldKeys.name,
      'Renamed',
    );
    await expectSameAsFresh('deck rename');

    await store.deleteNote(notes[3]);
    await expectSameAsFresh('delete');
  });

  test('模板改名', () async {
    final SrsNoteTypeView lapis = (await store.noteTypes()).firstWhere(
      (SrsNoteTypeView v) => v.name == 'Lapis',
    );
    await store.updateTemplate(
      lapis.id,
      lapis.templates.first.id,
      name: 'Renamed card',
    );
    await expectSameAsFresh('template rename');
  });

  test('复习改状态 / 到期；时间推移让学习卡与埋卡翻转（库没变）', () async {
    final List<String> cards = await cardIdsByQuery('deck:*');
    await store.answer(cards[0], 1); // 重来 → 学习中，60 分钟后到期。
    await store.answer(cards[1], 3);
    await store.answer(cards[1], 3); // 学完 → 复习卡。
    final SrsDayContext day = await store.dayContext();
    await store.buryUntil(cards[2], day.dayIndexOf(t) + 1);
    await expectSameAsFresh('answer');
    for (final int minutes in <int>[30, 15, 20, 120, 24 * 60]) {
      t += minutes * 60000;
      await expectSameAsFresh('+$minutes min');
    }
  });

  test('整体重建缓存之后', () async {
    final List<String> notes = await noteIdsByQuery('deck:*');
    await store.editFieldsBatch(<SrsFieldChange>[
      SrsFieldChange(
        SrsEntityKind.note,
        notes[0],
        SrsFieldKeys.noteTags,
        <String>['moved'],
      ),
    ]);
    await store.rebuildCaches();
    await expectSameAsFresh('rebuildCaches');
  });

  test('addNotes：批内重复与逐条加同结果', () async {
    final List<Map<String, Object?>> batch = <Map<String, Object?>>[
      yomitanNote('批', allowDuplicate: false),
      yomitanNote('批', allowDuplicate: false), // 与本批第一条重复。
      yomitanNote('批', allowDuplicate: true), // 允许重复：照加。
      yomitanNote('批', allowDuplicate: false), // 与前面已加的重复。
      yomitanNote('猫0', allowDuplicate: false), // 与库里的重复。
      yomitanNote('', allowDuplicate: true), // 空首字段。
      yomitanNote(
        '批',
        allowDuplicate: false,
        duplicateScope: 'deck',
        scopeDeckName: 'Nope',
      ), // 范围牌组不存在 → 不算重复。
      yomitanNote('批2', model: 'Nope'),
    ];
    final List<Object?> got =
        (await ok('addNotes', <String, Object?>{'notes': batch}))!
            as List<Object?>;
    expect(
      <bool>[for (final Object? x in got) x != null],
      <bool>[true, false, true, false, false, false, true, false],
    );
    // 每条都真的进了库、可查（整数 id 与 notesInfo 对得上）。
    final List<Object?> info =
        (await ok('notesInfo', <String, Object?>{
              'notes': <Object?>[for (final Object? x in got) ?x],
            }))!
            as List<Object?>;
    for (final Object? i in info) {
      expect((i! as Map<String, Object?>)['noteId'], isA<int>());
    }
    await expectSameAsFresh('addNotes');
  });

  test('并发请求：查询未落记忆前插进来的写入不会让记忆存旧结果、也不碰已释放的语料', () async {
    // 常驻视图跨请求共享：请求 A 的 _matchCards 在语料 prepare/match 的几次 await 之后才写
    // memo；若请求不串行，B 的 _refresh → markStale 会在这段时间里清空 memo、释放 delta 语料，
    // A 随后把旧命中写进新一代的 memo（C 读到旧结果），或在已释放的语料上抛错。
    // handler 的 [SrsAnkiConnectHandler.handle] 把请求排进同一条队列；这里同时发出不等待，
    // 锁住「A → B → C 依次跑完、互不交错」。
    const String q = 'Expression:并*';
    Future<Object?> send(String action, Map<String, Object?> params) =>
        call(resident, action, params);
    final List<Future<Object?>> inFlight = <Future<Object?>>[
      send('findNotes', <String, Object?>{'query': q}), // A：记忆未命中，要跑语料。
      send('addNote', <String, Object?>{'note': yomitanNote('并发')}), // B：写入。
      send('findNotes', <String, Object?>{'query': q}), // C：必须看到 B。
      send('addNote', <String, Object?>{'note': yomitanNote('并发2')}),
      send('findCards', <String, Object?>{'query': q}),
    ];
    final List<Map<String, Object?>> got = <Map<String, Object?>>[
      for (final Object? r in await Future.wait(inFlight))
        r! as Map<String, Object?>,
    ];
    for (final Map<String, Object?> r in got) {
      expect(r['error'], isNull, reason: '$r');
    }
    expect(got[0]['result'], isEmpty);
    final int added = got[1]['result']! as int;
    expect(got[2]['result'], <Object?>[added]);
    final Object? wantCards =
        ((await call(fresh(), 'findCards', <String, Object?>{'query': q}))!
            as Map<String, Object?>)['result'];
    expect((wantCards! as List<Object?>), isNotEmpty);
    expect(got[4]['result'], wantCards);
    expect(await ok('findNotes', <String, Object?>{'query': q}), hasLength(2));
    await expectSameAsFresh('concurrent');
  });

  test('未知整数 id：不重建索引，直接回空', () async {
    final CountingInterceptor counter = CountingInterceptor();
    final Directory dir = Directory.systemTemp.createTempSync('srs_ac_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄晚释放。
      }
    });
    final TestSrs srs = await openTestSrsAt(
      '${dir.path}/srs.db',
      interceptor: counter,
    );
    final SrsDbStore s = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: kAcProfile,
      deviceId: 'dev',
      fallbackRolloverHour: () => 4,
    );
    await s.noteIdForAnkiNumericId(1); // 首次：回填。
    counter.reset();
    for (int i = 2; i < 50; i++) {
      expect(await s.noteIdForAnkiNumericId(i), isNull);
      expect(await s.cardIdForAnkiNumericId(i), isNull);
    }
    expect(counter.total, 0, reason: counter.summary());
  });

  test('大库：热请求不再整库读，addNotes 整批一个事务', () async {
    final BulkFixture f = await BulkFixture.open(notes: 2000);
    final SrsAnkiConnectHandler h = SrsAnkiConnectHandler(
      store: () async => f.store,
      instanceId: 'bulk',
    );
    Future<Object?> run(String action, Map<String, Object?> params) async {
      final Map<String, Object?> r =
          (await h.handle(<String, Object?>{
                'action': action,
                'version': 6,
                'params': params,
              }))!
              as Map<String, Object?>;
      if (r['error'] != null) throw StateError('$action: ${r['error']}');
      return r['result'];
    }

    final String model =
        ((await run('modelNames', <String, Object?>{}))! as List<Object?>)
            .cast<String>()
            .firstWhere((String m) => m.startsWith('Basic'));
    Map<String, Object?> note(String w) => <String, Object?>{
      'deckName': 'Lang',
      'modelName': model,
      'fields': <String, Object?>{'Front': w, 'Back': 'b'},
      'options': <String, Object?>{'allowDuplicate': false},
    };
    // 冷请求：整份读一次。
    await run('canAddNotes', <String, Object?>{
      'notes': <Object?>[note('語1')],
    });
    await run('findNotes', <String, Object?>{'query': 'Front:語1*'});

    f.counter.reset();
    expect(
      await run('canAddNotes', <String, Object?>{
        'notes': <Object?>[note('語1'), note('新しい')],
      }),
      <bool>[false, true],
    );
    await run('findNotes', <String, Object?>{'query': 'Front:語2*'});
    // 热请求只读日界（profile 的修改记录），不碰笔记 / 卡片表。
    expect(f.counter.rowsRead, lessThan(20), reason: f.counter.summary());

    f.counter.reset();
    final List<Object?> added =
        (await run('addNotes', <String, Object?>{
              'notes': <Object?>[for (int i = 0; i < 50; i++) note('一括$i')],
            }))!
            as List<Object?>;
    expect(added.whereType<int>(), hasLength(50));
    expect(f.counter.transactions, 1, reason: f.counter.summary());

    // 写后的下一次请求只补读变了的 50 条（连同它们的卡），不整库重读。
    f.counter.reset();
    expect(
      await run('findNotes', <String, Object?>{'query': 'Front:一括*'}),
      hasLength(50),
    );
    expect(f.counter.rowsRead, lessThan(2000), reason: f.counter.summary());
    expect(
      await run('canAddNotes', <String, Object?>{
        'notes': <Object?>[note('一括7'), note('語5'), note('無')],
      }),
      <bool>[false, false, true],
    );
  });
}

// 偏好里持久化的 SRS 实体 ID 归一（G9-6，lib/src/srs/srs_persisted_ids.dart）：真偏好仓库（内存主库）+ 假的
// `canonical_ids`。三条制卡偏好（键名冻结）读时归一、写回规范 ID；并入后再跑重归一；归一不到的原值保留；只读视图
// （别的配置的快照）不写。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/srs/srs_persisted_ids.dart';
import 'package:fushi/src/srs/srs_word_audio_backfill.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  final Map<String, String> aliases = <String, String>{};
  final List<int> batchSizes = <int>[];

  Future<List<String>> lookup(List<String> ids) async {
    batchSizes.add(ids.length);
    return <String>[for (final String id in ids) aliases[id] ?? id];
  }

  setUp(() async {
    aliases.clear();
    batchSizes.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
  });
  tearDown(() => db.close());

  Future<String> stored(String key) async =>
      PrefCodec.decode<String>(await db.getPref(key) ?? '', '');

  test('带盐成员 ID 换成规范 ID 并写回三条偏好（键名不变）', () async {
    await prefs.setSrsMiningDeckId('member-deck');
    await prefs.setSrsMiningNoteTypeId('member-type');
    await prefs.setSrsMiningFieldMappings(<String, Map<String, String>>{
      'member-type': <String, String>{'member-field': '{expression}'},
    });
    aliases.addAll(<String, String>{
      'member-deck': 'canon-deck',
      'member-type': 'canon-type',
      'member-field': 'canon-field',
    });
    final List<String> written = await srsNormalizePersistedPreferenceIds(
      lookup: lookup,
      prefs: prefs,
    );
    expect(written, <String>[
      'srs_mining_deck_id',
      'srs_mining_note_type_id',
      'srs_mining_field_mappings',
    ]);
    expect(batchSizes, <int>[3], reason: '三条偏好的 ID 合成一批问');
    expect(prefs.srsMiningDeckId, 'canon-deck');
    expect(prefs.srsMiningNoteTypeId, 'canon-type');
    expect(prefs.srsMiningFieldMappings, <String, Map<String, String>>{
      'canon-type': <String, String>{'canon-field': '{expression}'},
    });
    // 落进了主库同一个键（存量偏好键名冻结）。
    expect(await stored('srs_mining_deck_id'), 'canon-deck');
    expect(await stored('srs_mining_note_type_id'), 'canon-type');
  });

  test('并入后（别名类变了）再跑一次：重归一并落盘', () async {
    await prefs.setSrsMiningDeckId('member-deck');
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: prefs),
      isEmpty,
    );
    expect(prefs.srsMiningDeckId, 'member-deck');
    aliases['member-deck'] = 'joined-canon';
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: prefs),
      <String>['srs_mining_deck_id'],
    );
    expect(await stored('srs_mining_deck_id'), 'joined-canon');
  });

  test('归一不到（实体已不存在）保留原值，「没选过」的空串不动', () async {
    await prefs.setSrsMiningDeckId('deleted-deck');
    await prefs.setSrsMiningFieldMappings(<String, Map<String, String>>{
      'deleted-type': <String, String>{'f': 'x'},
    });
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: prefs),
      isEmpty,
    );
    expect(prefs.srsMiningDeckId, 'deleted-deck');
    expect(prefs.srsMiningNoteTypeId, '');
    expect(prefs.srsMiningFieldMappings, <String, Map<String, String>>{
      'deleted-type': <String, String>{'f': 'x'},
    });
  });

  test('只读视图（别的配置的快照）不写，也不问内核', () async {
    final PreferencesRepository view = PreferencesRepository.readOnlySnapshot(
      db,
      <String, String>{'srs_mining_deck_id': PrefCodec.encode('member-deck')},
    );
    aliases['member-deck'] = 'canon-deck';
    expect(
      await srsNormalizePersistedPreferenceIds(lookup: lookup, prefs: view),
      isEmpty,
    );
    expect(view.srsMiningDeckId, 'member-deck');
    expect(batchSizes, isEmpty);
  });

  group('真内核（新库，先 `identity` 绑定）', () {
    late SrsDbStore store;

    setUp(() async {
      final SrsStorage srs = await openSrsTestStorage();
      srs.core.sync2(<String, Object?>{
        'op': 'identity',
        'profile': kSrsTestProfile,
        'now': DateTime.now().millisecondsSinceEpoch,
      });
      final (FushiDatabase main, SrsDbStore opened) = await openSrsTestStore(
        storage: srs,
      );
      store = opened;
      addTearDown(main.close);
    });

    test('统一入口：偏好里的带盐存量 ID 写回成牌组树里的规范 ID，内置 ID 也是规范的', () async {
      // G9-7 起 createDeck 回的就是规范 ID；带盐成员是协议 3 迁移来的存量（`<uid>/deck/<名字>` 的 v5），作为存量写进库，
      // `identity` 的 `Salts{uid}` 把它归到同一个类。
      final String canonical = await store.createDeck('Mining');
      final String member = uuidV5(
        srsNamespace,
        '$kSrsTestProfile/deck/Mining',
      );
      expect(member, isNot(canonical));
      await store.writeEdits(
        <SrsEditSpec>[
          SrsEditSpec(SrsEntityKind.deck, member, SrsFieldKeys.name, 'Mining'),
        ],
        records: <SrsEntityRecord>[
          SrsEntityRecord(
            id: member,
            profileUid: kSrsTestProfile,
            kind: SrsEntityKind.deck,
            payload: const <String, Object?>{'createdAt': 0},
          ),
        ],
      );
      await prefs.setSrsMiningDeckId(member);
      expect(await srsNormalizeStoreIds(store: store, prefs: prefs), <String>[
        'srs_mining_deck_id',
      ]);
      expect(prefs.srsMiningDeckId, canonical);
      final SrsDeckTree tree = await store.deckTree();
      expect(tree[prefs.srsMiningDeckId], isNotNull);
      expect(tree.fullName(prefs.srsMiningDeckId), 'Mining');
      expect(tree[store.defaultDeckId], isNotNull);
    });

    test('补单词音频的笔记类型 / 字段 ID 按规范 ID 取（G9-7 起按 profile 现算的就是它）', () async {
      final SrsWordAudioBackfillFields fields =
          await SrsWordAudioBackfillFields.ofStore(store);
      expect(fields.noteTypeId, store.fushiCardNoteTypeId);
      final SrsNoteTypeView type = (await store.noteType(fields.noteTypeId))!;
      expect(type.id, fields.noteTypeId);
      final Set<String> fieldIds = <String>{
        for (final SrsFieldDef f in type.fields) f.id,
      };
      expect(
        fieldIds,
        containsAll(<String>[
          fields.termFieldId,
          fields.readingFieldId,
          fields.audioFieldId,
        ]),
      );
      expect(
        fields.noteTypeId,
        SrsWordAudioBackfillFields.forProfile(kSrsTestProfile).noteTypeId,
      );
    });
  });
}

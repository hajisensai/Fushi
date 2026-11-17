// 持久化 SRS 实体 ID 归一（G9-6）对真内核：新代的规范 ID 不带盐；协议 3 按 profile uid 加盐算出的 ID（存量偏好里
// 存的内置实体、牌组、笔记类型 ID）只是别名类成员，牌组树等读命令回的都是规范 ID。G9-7 起 Dart 向内核要的 ID
// （[SrsKernelIds]、`createDeck` 等的返回值）本身就是规范 ID，成员 ID 在这里按存量公式 [_salted] 现算，并由
// [_seedLegacy] 把那几个带盐实体作为存量写进库（别名层只归一库里出现过的成员：迁移来的库里偏好指向的实体都在）。
//
// - 内置实体：开库后 [SrsDbStore.defaultDeckId] 等是规范 ID（在牌组树里查得到）；再跑 `ensureBuiltins` 不重发。
// - 偏好位置（制卡牌组 / 笔记类型 / 字段映射，经 srsMiningDestinationIdSites）：成员 ID → 规范 ID；归一不到的保留；
//   实体后来出现（别名类变了）再跑一次重归一；补盐（`bindingChanged`）之后统一入口再跑，结果稳定。
// - 读时归一：`resolveSrsMiningDestination` 拿成员 ID 不再误判「已删除」。
// - 批量上限：内核一次最多 4096 条，统一入口分批。
// - 覆写 / 取字段 / 按类型列映射（新建的 SrsMiner，没走过解析落点）：字段映射按规范 ID 查，成员 ID 键的映射照样生效。
// - 只读打开（Secondary，作品会话 / 扩展的副本）：开库就拿到内置规范 ID，不靠调用方补调。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_canonical_ids.dart';
import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_test_storage.dart';

const String _uid = '0193a1b2-0000-7000-8000-0000000000a1';
const String _otherUid = '0193a1b2-0000-7000-8000-0000000000b2';

/// 协议 3 的存量规则：`<uid>/<名字>` 的 v5（G9-7 之前 `SrsKernelIds(uid)` 答的就是它）。
String _salted(String name) => uuidV5(srsNamespace, '$_uid/$name');

/// 迁移来的存量：协议 3 按 [_uid] 加盐写下的内置实体（[builtins]）、牌组（[decks]，名字）、笔记类型（[noteTypes]，
/// ankiNum）。`identity` 写了 `Salts{_uid}`，别名层把它们归到同一个规范 ID。
Future<void> _seedLegacy(
  SrsDbStore s, {
  bool builtins = false,
  List<String> decks = const <String>[],
  List<int> noteTypes = const <int>[],
}) => s.writeEdits(
  <SrsEditSpec>[
    for (final String name in decks)
      SrsEditSpec(
        SrsEntityKind.deck,
        _salted('deck/$name'),
        SrsFieldKeys.name,
        name,
      ),
  ],
  records: <SrsEntityRecord>[
    if (builtins)
      for (final SrsEntityRecord r in srsBuiltinEntities(_uid))
        SrsEntityRecord(
          id: _salted(
            r.kind == SrsEntityKind.deck
                ? 'builtin-deck/default'
                : 'notetype/${r.payload['ankiNum']}',
          ),
          profileUid: _uid,
          kind: r.kind,
          payload: r.payload,
        ),
    for (final String name in decks)
      SrsEntityRecord(
        id: _salted('deck/$name'),
        profileUid: _uid,
        kind: SrsEntityKind.deck,
        payload: const <String, Object?>{'createdAt': 0},
      ),
    for (final int n in noteTypes)
      SrsEntityRecord(
        id: _salted('notetype/$n'),
        profileUid: _uid,
        kind: SrsEntityKind.noteType,
        payload: <String, Object?>{
          'ankiNum': n,
          'ntKind': SrsNoteTypeKind.standard,
          'createdAt': 0,
        },
      ),
  ],
);

/// 新库里给 [_uid] 建绑定与本机身份（`identity`，G9-4），再开副本。
Future<(SrsStorage, SrsDbStore)> _open() async {
  final SrsStorage srs = await openTestSrsStorage();
  srs.core.sync2(<String, Object?>{
    'op': 'identity',
    'profile': _uid,
    'now': DateTime.now().millisecondsSinceEpoch,
  });
  final SrsDbStore s = await SrsDbStore.open(
    core: srs.core,
    profileUid: _uid,
    deviceId: 'dev-a',
  );
  return (srs, s);
}

/// 内存里的三条制卡偏好。
final class _Prefs {
  SrsMiningDestination value = const SrsMiningDestination();

  List<SrsPersistedIdSite> get sites => srsMiningDestinationIdSites(
    read: () => value,
    writeDeckId: (String id) async => value = SrsMiningDestination(
      deckId: id,
      noteTypeId: value.noteTypeId,
      fieldMappingsByType: value.fieldMappingsByType,
    ),
    writeNoteTypeId: (String id) async => value = SrsMiningDestination(
      deckId: value.deckId,
      noteTypeId: id,
      fieldMappingsByType: value.fieldMappingsByType,
    ),
    writeFieldMappings: (Map<String, Map<String, String>> m) async =>
        value = SrsMiningDestination(
          deckId: value.deckId,
          noteTypeId: value.noteTypeId,
          fieldMappingsByType: m,
        ),
  );
}

void main() {
  test('内置实体：开库后是规范 ID，牌组树里查得到；再跑 ensureBuiltins 不重发', () async {
    final (_, SrsDbStore s) = await _open();
    final SrsKernelIds ids = SrsKernelIds(_uid);
    expect(
      <String>[s.defaultDeckId, s.lapisNoteTypeId, s.fushiCardNoteTypeId],
      <String>[
        ids.defaultDeck,
        ids.builtinNoteType(kSrsBuiltinLapisKey),
        ids.builtinNoteType(kSrsBuiltinFushiCardKey),
      ],
      reason: '内核答的就是规范 ID',
    );
    final String saltedDefault = _salted('builtin-deck/default');
    expect(saltedDefault, isNot(s.defaultDeckId), reason: '规范 ID 不带盐');
    await _seedLegacy(s, builtins: true);
    expect(
      await s.canonicalIds(<String>[
        saltedDefault,
        _salted(
          'notetype/${SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey)}',
        ),
        _salted(
          'notetype/${SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinFushiCardKey)}',
        ),
      ]),
      <String>[s.defaultDeckId, s.lapisNoteTypeId, s.fushiCardNoteTypeId],
    );
    final SrsDeckTree tree = await s.deckTree();
    expect(tree[s.defaultDeckId], isNotNull);
    expect((await s.noteType(s.lapisNoteTypeId))?.id, s.lapisNoteTypeId);
    final int before = s.revision;
    await s.ensureBuiltins();
    expect(s.revision, before, reason: '内置实体已在（按规范 ID 判），不重发');
  });

  test('偏好位置：成员 ID → 规范 ID；归一不到的保留；实体出现后再跑重归一', () async {
    final (_, SrsDbStore s) = await _open();
    final String canonDeck = await s.createDeck('Mining');
    final SrsDeckTree tree = await s.deckTree();
    expect(
      tree.decks
          .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'Mining')
          .id,
      canonDeck,
      reason: 'createDeck 回的是规范 ID',
    );
    final String member = _salted('deck/Mining');
    expect(member, isNot(canonDeck));
    await _seedLegacy(s, builtins: true, decks: <String>['Mining']);
    final String lapisMember = _salted(
      'notetype/${SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey)}',
    );
    final String fieldId = (await s.noteType(
      s.lapisNoteTypeId,
    ))!.fields.first.id;
    final String later = _salted('deck/Later');
    final _Prefs prefs = _Prefs()
      ..value = SrsMiningDestination(
        deckId: member,
        noteTypeId: lapisMember,
        fieldMappingsByType: <String, Map<String, String>>{
          lapisMember: <String, String>{fieldId: '{expression}'},
          later: <String, String>{'f': 'x'},
        },
      );
    final SrsCanonicalIdsLookup lookup = srsStoreCanonicalIds(s);

    expect(await srsNormalizePersistedIds(prefs.sites, lookup), <String>[
      'srs_mining_deck_id',
      'srs_mining_note_type_id',
      'srs_mining_field_mappings',
    ]);
    expect(prefs.value.deckId, canonDeck);
    expect(prefs.value.noteTypeId, s.lapisNoteTypeId);
    expect(prefs.value.fieldMappingsByType, <String, Map<String, String>>{
      s.lapisNoteTypeId: <String, String>{fieldId: '{expression}'},
      // 还不存在的牌组：原样保留。
      later: <String, String>{'f': 'x'},
    });

    // 别名类变了（带盐的存量实体后来才进库，如旧设备的操作）：同一个入口再跑一次，把它也换成规范 ID。
    await _seedLegacy(s, decks: <String>['Later']);
    final SrsDeckTree t2 = await s.deckTree();
    final String laterCanon = t2.decks
        .firstWhere((SrsDeckView d) => t2.fullName(d.id) == 'Later')
        .id;
    expect(await srsNormalizePersistedIds(prefs.sites, lookup), <String>[
      'srs_mining_field_mappings',
    ]);
    expect(prefs.value.fieldMappingsByType.keys, <String>[
      s.lapisNoteTypeId,
      laterCanon,
    ]);

    // 补盐（bindingChanged）之后：内置重读（store 收到回包里的 bindingChanged 自己重读根上 ID）、偏好重归一，
    // 已是规范 ID 的稳定不变。
    final String defaultBefore = s.defaultDeckId;
    final Map<String, Object?> salts = (await s.sync2Command(<String, Object?>{
      'op': 'collection_salts_add',
      'salts': <String>[_otherUid],
      'now': DateTime.now().millisecondsSinceEpoch,
    })).map;
    expect(salts['bindingChanged'], isNotNull);
    expect(s.debugBindingChanges, greaterThanOrEqualTo(1));
    expect(s.defaultDeckId, defaultBefore);
    expect(await srsNormalizePersistedIds(prefs.sites, lookup), isEmpty);
    expect(prefs.value.deckId, canonDeck);
  });

  test('读时归一：resolveSrsMiningDestination 拿成员 ID 不误判已删除；真删了照旧回落默认', () async {
    final (_, SrsDbStore s) = await _open();
    await s.createDeck('Mining');
    await _seedLegacy(s, builtins: true, decks: <String>['Mining']);
    final String member = _salted('deck/Mining');
    final String typeMember = _salted(
      'notetype/${SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey)}',
    );
    final SrsResolvedMiningDestination r = await resolveSrsMiningDestination(
      s,
      SrsMiningDestination(
        deckId: member,
        fieldMappingsByType: <String, Map<String, String>>{
          typeMember: <String, String>{'f': '{reading}'},
        },
      ),
    );
    expect(r.deckFellBack, isFalse);
    // 设置页按 `resolved.destination` 查字段映射：键已是规范 ID。
    expect(r.destination!.fieldMappingsByType, <String, Map<String, String>>{
      s.lapisNoteTypeId: <String, String>{'f': '{reading}'},
    });
    expect(r.deckName, 'Mining');
    expect((await s.deckTree())[r.deckId], isNotNull);

    final SrsResolvedMiningDestination gone = await resolveSrsMiningDestination(
      s,
      SrsMiningDestination(deckId: _salted('deck/Never')),
    );
    expect(gone.deckFellBack, isTrue);
    expect(gone.deckId, s.defaultDeckId);
  });

  test('批量上限：内核一次最多 4096 条，统一入口分批', () async {
    final (_, SrsDbStore s) = await _open();
    await _seedLegacy(s, builtins: true);
    final List<String> ids = <String>[
      for (int i = 0; i <= kSrsCanonicalIdsBatchMax; i++) 'plain-$i',
      _salted('builtin-deck/default'),
    ];
    await expectLater(s.canonicalIds(ids), throwsA(anything));
    final List<int> sizes = <int>[];
    final Map<String, String> m = await srsCanonicalIdMap(ids, (
      List<String> batch,
    ) {
      sizes.add(batch.length);
      return s.canonicalIds(batch);
    });
    expect(sizes, <int>[kSrsCanonicalIdsBatchMax, 2]);
    expect(m['plain-0'], 'plain-0');
    expect(m[_salted('builtin-deck/default')], s.defaultDeckId);
  });

  test('覆写 / 取字段 / 按类型列映射：新建的 SrsMiner 按规范 ID 查字段映射（偏好里是成员 ID 键）', () async {
    final (_, SrsDbStore s) = await _open();
    final String typeId = await s.createStockNoteType(
      SrsStockNoteType.basic,
      'Vocab',
    );
    final SrsNoteTypeView type = (await s.noteType(typeId))!;
    expect(type.id, typeId, reason: '新建回的是规范 ID');
    // 被测的是偏好里的成员 ID 键：协议 3 按 uid 加盐的那个 ID。
    final String typeMember = _salted('notetype/${type.ankiNum}');
    await _seedLegacy(s, noteTypes: <int>[type.ankiNum]);
    expect(await s.canonicalIds(<String>[typeMember]), <String>[typeId]);
    final String front = type.fields
        .firstWhere((SrsFieldDef f) => f.name == 'Front')
        .id;
    final String back = type.fields
        .firstWhere((SrsFieldDef f) => f.name == 'Back')
        .id;
    final String noteId = await s.createNote(
      noteTypeId: type.id,
      fieldsById: <String, String>{front: 'old front', back: 'old back'},
    );
    final Directory tmp = Directory.systemTemp.createTempSync('g96_miner_');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } on FileSystemException {
        // 句柄滞后；留给系统清理。
      }
    });
    // 作品级覆盖层 / 开库归一之前的偏好：映射按成员 ID 键存。故意与按字段名猜的结果相反（Front ← 读音、Back ← 词形）。
    final SrsMiner miner = SrsMiner(
      store: s,
      media: SrsMediaStore(Directory('${tmp.path}/media')),
      destination: SrsMiningDestination(
        noteTypeId: typeMember,
        fieldMappingsByType: <String, Map<String, String>>{
          typeMember: <String, String>{
            front: '{reading}',
            back: '{expression}',
          },
        },
      ),
    );
    final String payload = jsonEncode(<String, Object?>{
      'expression': '雪',
      'reading': 'ゆき',
      'glossary': '<ol><li>snow</li></ol>',
      'glossaryFirst': '<ol><li>snow</li></ol>',
      'audio': '',
    });
    const AnkiMiningContext context = AnkiMiningContext(sentence: '');

    final Map<String, String> Function(SrsNoteTypeView) lookup = await miner
        .miningFieldMappingLookup();
    expect(lookup(type), <String, String>{
      front: '{reading}',
      back: '{expression}',
    });

    final Map<String, String> prepared = await miner.prepareFieldsFor(
      noteId: noteId,
      settings: const AnkiSettings(),
      rawPayloadJson: payload,
      context: context,
    );
    expect(prepared['Front'], 'ゆき');
    expect(prepared['Back'], '雪');

    final MineOutcome out = await miner.overwrite(
      noteId: noteId,
      settings: const AnkiSettings(),
      rawPayloadJson: payload,
      context: context,
    );
    expect(out.result, MineResult.success, reason: out.errorDetail);
    final SrsNoteView note = (await s.note(noteId))!;
    expect(note.field(front), 'ゆき');
    expect(note.field(back), '雪');
  });

  test('只读打开（Secondary）：开库就拿到内置规范 ID，牌组树里查得到', () async {
    final (SrsStorage srs, SrsDbStore primary) = await _open();
    final SrsCore core = SrsCore.open(
      srs.directory,
      mode: SrsOpenMode.secondary,
    );
    addTearDown(core.close);
    SrsCoreWorkers.of(
      core.libraryPath,
    ).setQueryConcurrency(core.readConcurrency);
    final SrsDbStore secondary = await SrsDbStore.open(
      core: core,
      profileUid: _uid,
      deviceId: 'dev-a',
    );
    expect(secondary.defaultDeckId, primary.defaultDeckId);
    expect(secondary.lapisNoteTypeId, primary.lapisNoteTypeId);
    expect(secondary.fushiCardNoteTypeId, primary.fushiCardNoteTypeId);
    expect((await secondary.deckTree())[secondary.defaultDeckId], isNotNull);
  });
}

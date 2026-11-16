// 持久化 SRS 实体 ID 归一（G9-6）对真内核：新代的规范 ID 不带盐，Dart 按 profile uid 加盐算出的 ID（内置实体、
// `createDeck` 返回的派生 ID……）只是别名类成员，牌组树等读命令回的都是规范 ID。
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
    final SrsKernelIds derived = SrsKernelIds(_uid);
    expect(
      s.defaultDeckId,
      isNot(derived.defaultDeck),
      reason: '规范 ID 不带盐，与派生值不同',
    );
    expect(
      await s.canonicalIds(<String>[
        derived.defaultDeck,
        derived.builtinNoteType(kSrsBuiltinLapisKey),
        derived.builtinNoteType(kSrsBuiltinFushiCardKey),
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
    final (SrsStorage srs, SrsDbStore s) = await _open();
    final String member = await s.createDeck('Mining');
    final SrsDeckTree tree = await s.deckTree();
    final String canonDeck = tree.decks
        .firstWhere((SrsDeckView d) => tree.fullName(d.id) == 'Mining')
        .id;
    expect(member, isNot(canonDeck), reason: 'createDeck 回的是派生（带盐）ID');
    final String lapisMember = SrsKernelIds(
      _uid,
    ).builtinNoteType(kSrsBuiltinLapisKey);
    final String fieldId = (await s.noteType(
      s.lapisNoteTypeId,
    ))!.fields.first.id;
    final String later = SrsKernelIds(_uid).deck('Later');
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

    // 别名类变了（实体出现）：同一个入口再跑一次，把它也换成规范 ID。
    await s.createDeck('Later');
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

    // 补盐（bindingChanged）之后：内置重问、偏好重归一，已是规范 ID 的稳定不变。
    final Map<String, Object?> salts = srs.core.sync2(<String, Object?>{
      'op': 'collection_salts_add',
      'profile': _uid,
      'salts': <String>[_otherUid],
      'now': DateTime.now().millisecondsSinceEpoch,
    }).map;
    expect(salts['bindingChanged'], isNotNull);
    final String defaultBefore = s.defaultDeckId;
    await s.resolveBuiltinIds();
    expect(s.defaultDeckId, defaultBefore);
    expect(await srsNormalizePersistedIds(prefs.sites, lookup), isEmpty);
    expect(prefs.value.deckId, canonDeck);
  });

  test('读时归一：resolveSrsMiningDestination 拿成员 ID 不误判已删除；真删了照旧回落默认', () async {
    final (_, SrsDbStore s) = await _open();
    final String member = await s.createDeck('Mining');
    final SrsResolvedMiningDestination r = await resolveSrsMiningDestination(
      s,
      SrsMiningDestination(deckId: member),
    );
    expect(r.deckFellBack, isFalse);
    expect(r.deckName, 'Mining');
    expect((await s.deckTree())[r.deckId], isNotNull);

    final SrsResolvedMiningDestination gone = await resolveSrsMiningDestination(
      s,
      SrsMiningDestination(deckId: SrsKernelIds(_uid).deck('Never')),
    );
    expect(gone.deckFellBack, isTrue);
    expect(gone.deckId, s.defaultDeckId);
  });

  test('批量上限：内核一次最多 4096 条，统一入口分批', () async {
    final (_, SrsDbStore s) = await _open();
    final List<String> ids = <String>[
      for (int i = 0; i <= kSrsCanonicalIdsBatchMax; i++) 'plain-$i',
      SrsKernelIds(_uid).defaultDeck,
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
    expect(m[SrsKernelIds(_uid).defaultDeck], s.defaultDeckId);
  });

  test('覆写 / 取字段 / 按类型列映射：新建的 SrsMiner 按规范 ID 查字段映射（偏好里是成员 ID 键）', () async {
    final (_, SrsDbStore s) = await _open();
    final String typeMember = await s.createStockNoteType(
      SrsStockNoteType.basic,
      'Vocab',
    );
    // 按成员 ID 读视图在集成分支上会崩（`_prefetchEdits` 按请求 ID 取内核按规范 ID 回的键，交接 G9-6 节「没做」），
    // 这里只拿规范 ID 去读；被测的是偏好里的成员 ID 键。
    final String typeId = (await s.canonicalIds(<String>[typeMember])).single;
    expect(typeId, isNot(typeMember), reason: '新建回的是派生（带盐）ID');
    final SrsNoteTypeView type = (await s.noteType(typeId))!;
    final String front = type.fields
        .firstWhere((SrsFieldDef f) => f.name == 'Front')
        .id;
    final String back = type.fields
        .firstWhere((SrsFieldDef f) => f.name == 'Back')
        .id;
    final String noteId = (await s.canonicalIds(<String>[
      await s.createNote(
        noteTypeId: type.id,
        fieldsById: <String, String>{front: 'old front', back: 'old back'},
      ),
    ])).single;
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

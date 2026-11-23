// G9-7 ID 口径，经 SrsDbStore 端到端（真内核）：两种来源各走一遍「建牌组 → 建笔记 → 读回 → 改 → 撤销」。
//
// - 全新库：Dart 向内核要的根上 ID（[SrsKernelIds]）就是读命令回的规范 ID；建实体的入口返回内核落下的 ID（回包
//   `entityWrites`）；新卡在队列里。
// - 迁移形的库：协议 3 按 profile uid 加盐派生的 ID（`uuidV5(ns, '<uid>/…')`）作为存量写进去——身份记录、修改、
//   带盐的内置默认牌组与内置 Lapis。全新 profile 的 `identity` 写了 `Salts{uid}`，派生层把它们归到规范 ID（与迁移
//   出来的库同一个状态：存量操作带盐、盐集合有 uid）。按带盐 ID 读视图不崩（`_prefetchEdits` 按回包 `canon` 对回去）、
//   重开不另建内置实体、按成员 ID 改的字段撤销项带 dot 并撤得回去（`_SrsUndoRecorder.noteWritten` 按输入下标认领）。
import 'dart:io';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show FakeFsrsEngine;

const String kProfile = '01928c3e-0000-7000-8000-0000000000d7';

/// 协议 3 的存量规则：`<uid>/<名字>` 的 v5（G9-7 之前 `SrsKernelIds(uid)` 答的就是它）。
String salted(String name) => uuidV5(srsNamespace, '$kProfile/$name');

void main() {
  final int now = DateTime.utc(2026, 11, 17, 3).millisecondsSinceEpoch;
  late Directory dir;
  final List<SrsStorage> opened = <SrsStorage>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('srs_id_derivation_e2e_');
  });

  tearDown(() async {
    for (final SrsStorage s in opened.reversed) {
      await s.close();
    }
    opened.clear();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄滞后：留给系统清理。
    }
  });

  Future<SrsDbStore> open() async {
    final SrsStorage s = await SrsStorage.open(
      directory: dir.path,
      mode: SrsOpenMode.primary,
    );
    opened.add(s);
    return SrsDbStore.open(
      core: s.core,
      profileUid: kProfile,
      deviceId: 'legacy-device-ignored',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => now,
        bootClockMs: () => now,
      ),
      fallbackRolloverHour: () => 4,
      localOffsetMin: () => 0,
    );
  }

  /// 在 [store.undoable] 里写一条修改，回撤销凭据。
  Future<SrsEditUndo> change(
    SrsDbStore store,
    SrsEntityKind kind,
    String id,
    String key,
    Object? value,
  ) async {
    final (_, SrsEditUndo undo) = await store.undoable(
      () => store.writeEdits(<SrsEditSpec>[SrsEditSpec(kind, id, key, value)]),
    );
    return undo;
  }

  void expectDot(SrsEditUndo undo) {
    expect(undo.items, hasLength(1));
    expect(
      undo.items.single.writer,
      isNotNull,
      reason: 'the undo item carries the dot of the write it undoes',
    );
    expect(undo.items.single.seq, isNotNull);
  }

  test('全新库：建牌组 → 建笔记 → 读回 → 改 → 撤销，ID 全是读命令回的那一份', () async {
    final SrsDbStore store = await open();
    final SrsKernelIds ids = SrsKernelIds(kProfile);
    expect(store.defaultDeckId, ids.defaultDeck);
    expect(store.lapisNoteTypeId, ids.builtinNoteType(kSrsBuiltinLapisKey));

    final String deck = await store.createDeck('Lang');
    expect(deck, ids.deck('Lang'));
    expect((await store.deckTree())[deck]?.name, 'Lang');

    final String expression = srsLapisFieldId(kProfile, 'Expression');
    final String note = await store.createNote(
      noteTypeId: store.lapisNoteTypeId,
      fieldsById: <String, String>{expression: '鯨'},
      deckId: deck,
      guid: 'g97-fresh',
    );
    expect(note, ids.note('g97-fresh'));
    final String card = (await store.cardsOfNote(note)).single.id;
    expect(
      (await store.studyState(deck))?.next,
      card,
      reason: 'the new card is not hidden',
    );
    expect((await store.note(note))?.field(expression), '鯨');
    expect(
      (await store.noteType(
        store.lapisNoteTypeId,
      ))?.fields.map((SrsFieldDef f) => f.id),
      contains(expression),
    );

    final SrsEditUndo undo = await change(
      store,
      SrsEntityKind.note,
      note,
      SrsFieldKeys.noteField(expression),
      '鯱',
    );
    expectDot(undo);
    expect((await store.note(note))?.field(expression), '鯱');
    final SrsEditUndoResult r = await store.revertEdits(undo);
    expect(r.reverted, 1);
    expect(r.kept, isEmpty);
    expect((await store.note(note))?.field(expression), '鯨');

    // 给空字段写值（补音频 / 例句的常见形）：改前值按同一次 `edits` 读的回包取，不为键里嵌的字段 ID 另发
    // `canonical_ids`（全新库里键本来就是规范形）。
    final String other = (await store.noteType(store.lapisNoteTypeId))!.fields
        .map((SrsFieldDef f) => f.id)
        .firstWhere((String f) => f != expression);
    final int calls = store.debugCanonicalIdsCalls;
    final SrsEditUndo fill = await change(
      store,
      SrsEntityKind.note,
      note,
      SrsFieldKeys.noteField(other),
      'filled',
    );
    expect(store.debugCanonicalIdsCalls, calls, reason: 'no canonical_ids');
    expectDot(fill);
    expect((await store.note(note))?.field(other), 'filled');
    expect((await store.revertEdits(fill)).reverted, 1);
    expect((await store.note(note))?.field(other), anyOf(isNull, isEmpty));
  });

  test('迁移形的库（存量 ID 带盐）：按带盐 ID 读写、建同名牌组 / 同 guid 笔记落在同一个类、撤销带 dot', () async {
    final SrsDbStore first = await open();
    final SrsKernelIds ids = SrsKernelIds(kProfile);
    final int lapisNum = SrsIds.builtinNoteTypeAnkiNum(kSrsBuiltinLapisKey);
    final String saltedDefault = salted('builtin-deck/default');
    final String saltedLapis = salted('notetype/$lapisNum');
    final String saltedDeck = salted('deck/Old');
    final String saltedNote = salted('note/g97-old');
    final int exprNum = SrsIds.builtinFieldAnkiNum(
      kSrsBuiltinLapisKey,
      srsBuiltinFieldSeed(kSrsBuiltinLapisKey, 'Expression'),
    );
    final String saltedExpr = SrsIds.field(saltedLapis, exprNum);
    final String expression = srsLapisFieldId(kProfile, 'Expression');
    expect(saltedDefault, isNot(first.defaultDeckId));
    expect(saltedExpr, isNot(expression));

    // 存量：协议 3 按 uid 加盐写下的内置默认牌组、内置 Lapis（连同它的字段定义——别名层按定义史把带盐字段 ID
    // 归到规范字段）、一个牌组、一条笔记。
    final SrsFieldDef exprDef = (await first.noteType(
      first.lapisNoteTypeId,
    ))!.fields.firstWhere((SrsFieldDef f) => f.id == expression);
    await first.writeEdits(
      <SrsEditSpec>[
        SrsEditSpec(
          SrsEntityKind.noteType,
          saltedLapis,
          SrsFieldKeys.fieldDef(saltedExpr),
          exprDef.toValue(),
        ),
        SrsEditSpec(SrsEntityKind.deck, saltedDeck, SrsFieldKeys.name, 'Old'),
        SrsEditSpec(
          SrsEntityKind.note,
          saltedNote,
          SrsFieldKeys.noteField(saltedExpr),
          '狼',
        ),
      ],
      records: <SrsEntityRecord>[
        SrsEntityRecord(
          id: saltedDefault,
          profileUid: kProfile,
          kind: SrsEntityKind.deck,
          payload: const <String, Object?>{'builtin': 'default'},
        ),
        SrsEntityRecord(
          id: saltedLapis,
          profileUid: kProfile,
          kind: SrsEntityKind.noteType,
          payload: <String, Object?>{
            'ankiNum': lapisNum,
            'ntKind': SrsNoteTypeKind.standard,
            'builtin': kSrsBuiltinLapisKey,
          },
        ),
        SrsEntityRecord(
          id: saltedDeck,
          profileUid: kProfile,
          kind: SrsEntityKind.deck,
          payload: const <String, Object?>{'createdAt': 0},
        ),
        SrsEntityRecord(
          id: saltedNote,
          profileUid: kProfile,
          kind: SrsEntityKind.note,
          payload: <String, Object?>{
            'noteTypeId': saltedLapis,
            'guid': 'g97-old',
            'createdAt': now,
          },
        ),
      ],
    );
    expect(
      await first.canonicalIds(<String>[
        saltedDefault,
        saltedLapis,
        saltedDeck,
        saltedNote,
      ]),
      <String>[
        ids.defaultDeck,
        ids.builtinNoteType(kSrsBuiltinLapisKey),
        ids.deck('Old'),
        ids.note('g97-old'),
      ],
      reason: 'the salted ids fold into the ids Dart asks the kernel for',
    );

    // 重开：内置实体已在（带盐的那份归到同一个类），不再写；默认牌组只有一个。
    final String before = await first.changeFingerprint();
    final SrsDbStore store = await open();
    expect(await store.changeFingerprint(), before);
    final SrsDeckTree tree = await store.deckTree();
    expect(
      tree.decks.where((SrsDeckView d) => d.id == store.defaultDeckId),
      hasLength(1),
    );
    expect(tree[saltedDefault], isNull, reason: 'the tree holds canonical ids');
    expect(tree[ids.deck('Old')]?.name, 'Old');

    // 按带盐 ID 读视图（以前 `_prefetchEdits` 按请求 ID 预建槽、按规范 ID 取，Null check 崩）。
    expect((await store.note(saltedNote))?.field(expression), '狼');
    expect(
      (await store.noteType(saltedLapis))?.fields.map((SrsFieldDef f) => f.id),
      contains(expression),
    );
    expect(
      (await store.notes(<String>[
        saltedNote,
        ids.note('g97-old'),
      ])).values.map((SrsNoteView? v) => v?.field(expression)),
      <String>['狼', '狼'],
    );

    // 建同名牌组 / 同 guid 笔记：落在已有的类上，返回规范 ID。
    final String deck = await store.createDeck('Old');
    expect(deck, ids.deck('Old'));
    final String note = await store.createNote(
      noteTypeId: saltedLapis,
      fieldsById: <String, String>{saltedExpr: '狼'},
      deckId: saltedDeck,
      guid: 'g97-old',
    );
    expect(note, ids.note('g97-old'));
    final String card = (await store.cardsOfNote(note)).single.id;
    expect((await store.studyState(deck))?.next, card);

    // 按带盐成员改牌组名与笔记字段：撤销项带 dot，撤得回去。
    final SrsEditUndo deckUndo = await change(
      store,
      SrsEntityKind.deck,
      saltedDeck,
      SrsFieldKeys.name,
      'Renamed',
    );
    expectDot(deckUndo);
    expect((await store.deckTree())[deck]?.name, 'Renamed');
    // 键里嵌着带盐字段 ID：改前值按 `edits` 读回包的 `keyCanon` 换成规范键取（不另发 `canonical_ids`），撤得回 '狼'。
    final int calls = store.debugCanonicalIdsCalls;
    final SrsEditUndo noteUndo = await change(
      store,
      SrsEntityKind.note,
      saltedNote,
      SrsFieldKeys.noteField(saltedExpr),
      '狐',
    );
    expectDot(noteUndo);
    expect(store.debugCanonicalIdsCalls, calls, reason: 'no canonical_ids');
    expect((await store.note(note))?.field(expression), '狐');

    expect((await store.revertEdits(noteUndo)).reverted, 1);
    expect((await store.note(note))?.field(expression), '狼');
    expect((await store.revertEdits(deckUndo)).reverted, 1);
    expect((await store.deckTree())[deck]?.name, 'Old');
  });
}

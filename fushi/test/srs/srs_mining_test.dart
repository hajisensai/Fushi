// 挖词目标「Fushi SRS」（计划 PR3a）：SrsMiningAnkiRepository（只写复习）、落地牌组 /
// 笔记类型 / 字段映射与被删回落、
// 媒体落盘与引用改写、出处、判重（同形异读不算重复），以及「模块关着时装饰层根本不在
// ankiRepositoryProvider 的链上」。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import '../helpers/test_platform_services.dart';
import 'srs_test_support.dart';

/// 假的内层 Anki 仓库：记录 mineEntry，结果与查重可配。
class _FakeAnki extends BaseAnkiRepository {
  _FakeAnki({this.duplicate = false});

  MineOutcome outcome = const MineOutcome.success(deckName: 'Anki deck');
  bool duplicate;
  int mined = 0;

  /// 复习模式下任何「写 Anki / 依赖 Anki」的调用都不该落到这里（见各用例）。
  int ankiCalls = 0;
  AnkiSettings settings = const AnkiSettings(tags: 'mine-tag');

  @override
  Future<AnkiSettings> loadSettings() async => settings;

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    ankiCalls++;
    return const MineOutcome.success();
  }

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    ankiCalls++;
    return true;
  }

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async {
    ankiCalls++;
    return const <MinedNoteRef>[MinedNoteRef(noteId: 1)];
  }

  /// 出处不在复习里时才会问到 Anki。
  int sourceLookups = 0;

  @override
  Future<AnkiSourceNote?> readSourceNote(String sourceId) async {
    sourceLookups++;
    return null;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mined++;
    return outcome;
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async =>
      duplicate;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

String _payload(
  String expression,
  String reading, {
  String audio = '',
  bool allowDuplicate = false,
}) => jsonEncode(<String, Object?>{
  'expression': expression,
  'reading': reading,
  'glossary': '<ol><li>snow</li></ol>',
  'glossaryFirst': '<ol><li>snow</li></ol>',
  'audio': audio,
  if (allowDuplicate) AnkiMiningPayload.allowDuplicateKey: 'true',
});

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsMediaStore media;
  late File cover;
  late File sentenceAudio;
  late File wordAudio;

  // 没选过笔记类型时制卡落进内置 Fushi 卡片（2026-10-16 起的默认）。
  String fid(String key) => srsFushiCardFieldId(kSrsTestProfile, key);
  String lapisFid(String key) => srsLapisFieldId(kSrsTestProfile, key);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_srs_mining_');
    (db, store) = await openSrsTestStore();
    media = SrsMediaStore(Directory('${tmp.path}/srs_media/$kSrsTestProfile'));
    cover = File('${tmp.path}/shot.PNG')..writeAsBytesSync(<int>[1, 2, 3, 4]);
    sentenceAudio = File('${tmp.path}/line.mp3')
      ..writeAsBytesSync(<int>[9, 9, 9]);
    wordAudio = File('${tmp.path}/word.ogg')..writeAsBytesSync(<int>[7, 7]);
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  SrsMiningAnkiRepository repoFor(_FakeAnki inner) => SrsMiningAnkiRepository(
    inner: inner,
    miner: () async => SrsMiner(store: store, media: media),
  );

  AnkiMiningContext bookContext() => AnkiMiningContext(
    sentence: '雪が降る。',
    documentTitle: 'Snow Country',
    coverPath: cover.path,
    sentenceAudioPath: sentenceAudio.path,
    source: AnkiMiningSource.book,
    sourceLink: CardSourceLink(
      kind: CardSourceKind.book,
      uid: 'book_1',
      sourceId: CardSourceLink.newSourceId(),
      chapterIndex: 3,
      charOffset: 120,
      charLength: 1,
      bookKey: 'Snow Country',
    ),
  );

  Future<SrsNoteView> noteOf(String expression, String reading) async {
    final Map<String, SrsTermStatus> hit = await store.lookupTermStatus(
      <SrsTermQuery>[SrsTermQuery(expression, reading)],
    );
    expect(hit, contains(expression));
    return (await store.note(hit[expression]!.noteId))!;
  }

  test('目标 = SRS：默认落进 Fushi 卡片（字段按 fieldId），媒体按内容哈希存盘并改写引用，出处为书', () async {
    final _FakeAnki inner = _FakeAnki();
    final MineOutcome out = await repoFor(inner).mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき', audio: wordAudio.path),
      context: bookContext(),
    );
    expect(out.result, MineResult.success);
    expect(inner.mined, 0, reason: '仅 SRS 时不碰 Anki');

    final SrsNoteView note = await noteOf('雪', 'ゆき');
    expect(note.noteTypeId, store.fushiCardNoteTypeId);
    expect(note.field(fid('Expression')), '雪');
    expect(note.field(fid('ExpressionReading')), 'ゆき');
    expect(note.field(fid('Sentence')), contains('降る'));

    final String coverName = SrsMediaStore.contentName('x.png', <int>[
      1,
      2,
      3,
      4,
    ]);
    final String lineName = SrsMediaStore.contentName('x.mp3', <int>[9, 9, 9]);
    final String wordName = SrsMediaStore.contentName('x.ogg', <int>[7, 7]);
    expect(note.field(fid('Picture')), contains('src="$coverName"'));
    expect(note.field(fid('SentenceAudio')), contains('[sound:$lineName]'));
    expect(note.field(fid('ExpressionAudio')), contains('[sound:$wordName]'));
    // 本地临时路径绝不进字段。
    for (final String v in note.fields.values) {
      expect(v, isNot(contains(tmp.path)));
    }
    expect(await media.load(coverName), <int>[1, 2, 3, 4]);
    expect(await media.load(lineName), <int>[9, 9, 9]);
    expect(await media.load(wordName), <int>[7, 7]);

    expect(note.tags, contains('mine-tag'));
    final SrsSourceRef src = note.source!;
    expect(src.kind, SrsSourceKind.book);
    expect(src.data['bookKey'], 'Snow Country');
    expect(src.data['section'], 3);
    expect(src.data['start'], 120);
    expect(src.title, 'Snow Country');
    expect(note.deckId, store.defaultDeckId);
  });

  test('判重：同词同读重复；同形异读不算重复；allowDuplicate 跳过判重', () async {
    final SrsMiningAnkiRepository repo = repoFor(_FakeAnki());
    const AnkiMiningContext ctx = AnkiMiningContext(sentence: '');
    expect(
      (await repo.mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず'),
        context: ctx,
      )).result,
      MineResult.success,
    );
    expect(await repo.isDuplicate('上手', 'じょうず'), isTrue);
    expect(await repo.isDuplicate('上手', 'うわて'), isFalse);
    expect(
      (await repo.mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず'),
        context: ctx,
      )).result,
      MineResult.duplicate,
    );
    expect(
      (await repo.mineEntry(
        rawPayloadJson: _payload('上手', 'うわて'),
        context: ctx,
      )).result,
      MineResult.success,
      reason: '同形异读是另一个词',
    );
    expect(
      (await repo.mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず', allowDuplicate: true),
        context: ctx,
      )).result,
      MineResult.success,
    );
    final Map<String, SrsTermStatus> s = await store.lookupTermStatus(
      const <SrsTermQuery>[SrsTermQuery('上手', 'じょうず')],
    );
    expect(s['上手']!.cardCount, 2);
    // 没有定位的制卡：出处为 manual。
    expect((await store.note(s['上手']!.noteId))!.source!.kind, isNotNull);
  });

  test('SRS 层二选一：制卡不发往 Anki；判重只看 SRS，Anki 那边有也不算', () async {
    final _FakeAnki inner = _FakeAnki(duplicate: true);
    final SrsMiningAnkiRepository repo = repoFor(inner);
    expect(await repo.isDuplicate('雪', 'ゆき'), isFalse);
    final MineOutcome out = await repo.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.success);
    expect(inner.mined, 0, reason: '目标是 Fushi 复习时不再同时发往 Anki');
    expect(await repo.isDuplicate('雪', 'ゆき'), isTrue);
    expect(
      await store.lookupTermStatus(const <SrsTermQuery>[SrsTermQuery('雪')]),
      isNotEmpty,
    );
  });

  test('SRS 打不开：制卡报错（不悄悄落回 Anki），判重为否', () async {
    final _FakeAnki inner = _FakeAnki(duplicate: true);
    final SrsMiningAnkiRepository repo = SrsMiningAnkiRepository(
      inner: inner,
      miner: () async => null,
    );
    final MineOutcome out = await repo.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.error);
    expect(inner.mined, 0);
    expect(await repo.isDuplicate('雪', 'ゆき'), isFalse);
  });

  /// 一个非 Lapis 的笔记类型：字段 Word / Meaning / Sentence，词条字段 = Word。
  Future<String> createVocabType() async {
    const String id = 'nt-vocab';
    await store.importEvents(<SrsEvent>[
      SrsEntityEvent(
        SrsEntityRecord(
          id: id,
          profileUid: kSrsTestProfile,
          kind: SrsEntityKind.noteType,
          payload: <String, Object?>{
            'ankiNum': 1,
            'ntKind': SrsNoteTypeKind.standard,
            'createdAt': 1,
          },
        ),
      ),
    ]);
    await store.editFields(SrsEntityKind.noteType, id, <String, Object?>{
      SrsFieldKeys.name: 'Vocab',
      SrsFieldKeys.fieldDef('fw'): const SrsFieldDef(
        id: 'fw',
        name: 'Word',
        ord: 0,
      ).toValue(),
      SrsFieldKeys.fieldDef('fm'): const SrsFieldDef(
        id: 'fm',
        name: 'Meaning',
        ord: 1,
      ).toValue(),
      SrsFieldKeys.fieldDef('fs'): const SrsFieldDef(
        id: 'fs',
        name: 'Sentence',
        ord: 2,
      ).toValue(),
      SrsFieldKeys.templateDef('t1'): const SrsTemplateDef(
        id: 't1',
        name: 'Card 1',
        ord: 0,
        front: '{{fld:fw}}',
        back: '{{fld:fm}}',
      ).toValue(),
      SrsFieldKeys.termField: 'fw',
    });
    return id;
  }

  SrsMiningAnkiRepository repoWith(SrsMiningDestination destination) =>
      SrsMiningAnkiRepository(
        inner: _FakeAnki(),
        miner: () async =>
            SrsMiner(store: store, media: media, destination: destination),
      );

  test('落地：选定牌组 → 卡进该牌组，回执带牌组名', () async {
    final String deck = await store.createDeck('Mining');
    final MineOutcome out = await repoWith(
      SrsMiningDestination(deckId: deck),
    ).mineEntry(rawPayloadJson: _payload('雪', 'ゆき'), context: bookContext());
    expect(out.result, MineResult.success);
    expect(out.deckName, 'Mining');
    final SrsNoteView note = await noteOf('雪', 'ゆき');
    expect(note.deckId, deck);
    expect(note.noteTypeId, store.fushiCardNoteTypeId);
  });

  test('落地：明确选了 Lapis 的仍落 Lapis（只改「没选过」的默认）', () async {
    final MineOutcome out = await repoWith(
      SrsMiningDestination(noteTypeId: store.lapisNoteTypeId),
    ).mineEntry(rawPayloadJson: _payload('雪', 'ゆき'), context: bookContext());
    expect(out.result, MineResult.success);
    final SrsNoteView note = await noteOf('雪', 'ゆき');
    expect(note.noteTypeId, store.lapisNoteTypeId);
    expect(note.field(lapisFid('Expression')), '雪');
    expect(note.field(lapisFid('ExpressionReading')), 'ゆき');
  });

  test('落地：非 Lapis 笔记类型按映射落字段；没映射过的同名字段沿用 Lapis 默认', () async {
    final String type = await createVocabType();
    final MineOutcome out = await repoWith(
      SrsMiningDestination(
        noteTypeId: type,
        fieldMappingsByType: <String, Map<String, String>>{
          type: <String, String>{'fw': '{expression}', 'fm': '{glossary}'},
        },
      ),
    ).mineEntry(rawPayloadJson: _payload('雪', 'ゆき'), context: bookContext());
    expect(out.result, MineResult.success);
    final SrsNoteView note = await noteOf('雪', 'ゆき');
    expect(note.noteTypeId, type);
    expect(note.field('fw'), '雪');
    expect(note.field('fm'), contains('snow'));
    expect(note.field('fs'), contains('降る'), reason: 'Sentence 与 Lapis 同名');
    expect(note.deckId, store.defaultDeckId);
    // 查重仍按 SRS 词状态：同一个词再制一次是重复。
    expect(
      (await repoWith(SrsMiningDestination(noteTypeId: type)).mineEntry(
        rawPayloadJson: _payload('雪', 'ゆき'),
        context: bookContext(),
      )).result,
      MineResult.duplicate,
    );
  });

  test('落地：非 Lapis 类型第一字段映射成空 → 拒绝建卡', () async {
    final String type = await createVocabType();
    final MineOutcome out = await repoWith(
      SrsMiningDestination(
        noteTypeId: type,
        fieldMappingsByType: <String, Map<String, String>>{
          type: <String, String>{'fw': ''},
        },
      ),
    ).mineEntry(rawPayloadJson: _payload('雪', 'ゆき'), context: bookContext());
    expect(out.result, MineResult.error);
    expect(out.errorCode, AnkiErrorCode.firstFieldEmpty);
  });

  test('落地：选中的牌组 / 笔记类型被删 → 回落默认牌组 + Lapis', () async {
    final String deck = await store.createDeck('Gone');
    final String type = await createVocabType();
    await store.deleteDeck(deck);
    await store.editField(
      SrsEntityKind.noteType,
      type,
      SrsFieldKeys.deleted,
      1,
    );
    final SrsMiningDestination dest = SrsMiningDestination(
      deckId: deck,
      noteTypeId: type,
    );
    final SrsResolvedMiningDestination resolved =
        await resolveSrsMiningDestination(store, dest);
    expect(resolved.deckFellBack, isTrue);
    expect(resolved.noteTypeFellBack, isTrue);
    expect(resolved.usesLapis, isTrue);
    expect(resolved.deckId, store.defaultDeckId);

    final MineOutcome out = await repoWith(
      dest,
    ).mineEntry(rawPayloadJson: _payload('雪', 'ゆき'), context: bookContext());
    expect(out.result, MineResult.success);
    final SrsNoteView note = await noteOf('雪', 'ゆき');
    expect(note.deckId, store.defaultDeckId);
    expect(note.noteTypeId, store.lapisNoteTypeId);
    expect(note.field(lapisFid('Expression')), '雪');
  });

  test('落地：没选过 = 默认牌组 + Fushi 卡片，不算回落', () async {
    final SrsResolvedMiningDestination resolved =
        await resolveSrsMiningDestination(store, const SrsMiningDestination());
    expect(resolved.deckFellBack, isFalse);
    expect(resolved.noteTypeFellBack, isFalse);
    expect(resolved.usesLapis, isFalse);
    expect(resolved.noteType?.id, store.fushiCardNoteTypeId);
    expect(resolved.deckId, store.defaultDeckId);
  });

  group('复习模式下的其余制卡操作走 SRS（不碰 Anki）', () {
    late _FakeAnki inner;
    late List<String> opened;
    late SrsMiningAnkiRepository repo;

    setUp(() {
      inner = _FakeAnki();
      opened = <String>[];
      repo = SrsMiningAnkiRepository(
        inner: inner,
        miner: () async => SrsMiner(store: store, media: media),
        openNote: (String id) async {
          opened.add(id);
          return true;
        },
      );
    });

    Future<int> mine(String expression, String reading) async {
      final MineOutcome out = await repo.mineEntry(
        rawPayloadJson: _payload(expression, reading, allowDuplicate: true),
        context: bookContext(),
      );
      expect(out.result, MineResult.success);
      expect(out.noteId, isNotNull, reason: '有整数句柄才能进「可覆写」态');
      return out.noteId!;
    }

    test('覆写：按句柄改同一条复习笔记的字段，标签只增不减，不新建', () async {
      final int handle = await mine('雪', 'ゆき');
      final SrsNoteView before = await noteOf('雪', 'ゆき');
      final MineOutcome out = await repo.updateMinedNote(
        noteId: handle,
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '雪',
          'reading': 'ゆき',
          'glossary': '<ol><li>snowfall</li></ol>',
          'glossaryFirst': '<ol><li>snowfall</li></ol>',
          'audio': '',
        }),
        context: const AnkiMiningContext(sentence: '雪が積もる。'),
      );
      expect(out.result, MineResult.success);
      expect(out.noteId, handle);
      final SrsNoteView after = (await store.note(before.id))!;
      expect(after.field(fid('Sentence')), contains('積もる'));
      expect(after.field(fid('Glossary')), contains('snowfall'));
      expect(after.tags, containsAll(before.tags));
      expect(
        (await repo.findMatchingNotes('雪', 'ゆき')).length,
        1,
        reason: '覆写不新建笔记',
      );
      expect(inner.ankiCalls, 0);
      expect(inner.mined, 0);
    });

    test('覆写：原笔记已删 → 明确失败', () async {
      final int handle = await mine('雪', 'ゆき');
      await store.deleteNote((await noteOf('雪', 'ゆき')).id);
      final MineOutcome out = await repo.updateMinedNote(
        noteId: handle,
        rawPayloadJson: _payload('雪', 'ゆき'),
        context: const AnkiMiningContext(sentence: ''),
      );
      expect(out.result, MineResult.error);
      expect(inner.ankiCalls, 0);
    });

    test('覆写范围：仅最近一张 → null；全部 → 这个词最新的复习笔记', () async {
      await mine('雪', 'ゆき');
      final int newer = await mine('雪', 'ゆき');
      expect(await repo.findOverwriteTargetNoteId('雪', 'ゆき'), isNull);
      inner.settings = inner.settings.copyWith(
        overwriteScope: AnkiOverwriteScope.all,
      );
      expect(await repo.findOverwriteTargetNoteId('雪', 'ゆき'), newer);
      expect(await repo.findOverwriteTargetNoteId('雨', 'あめ'), isNull);
    });

    test('同词反查新建的在前；读字段按字段名；已删复核只报明确删掉的', () async {
      final int older = await mine('雪', 'ゆき');
      final int newer = await mine('雪', 'ゆき');
      final List<MinedNoteRef> refs = await repo.findMatchingNotes('雪', 'ゆき');
      expect(refs.map((MinedNoteRef r) => r.noteId), <int>[newer, older]);
      expect(refs.first.preview, '雪');
      expect((await repo.noteFields(newer))!['Expression'], '雪');
      expect(await repo.noteFields(12345), isNull);

      final String olderId = (await store.noteIdForAnkiNumericId(older))!;
      await store.deleteNote(olderId);
      expect(await repo.findDeletedNotes(<int>{older, newer}), <int>{older});
      expect(inner.ankiCalls, 0);
    });

    test('打开笔记 / 打开这个词：打开复习的笔记编辑页', () async {
      final int handle = await mine('雪', 'ゆき');
      final String id = (await store.noteIdForAnkiNumericId(handle))!;
      expect(await repo.openNoteInAnki(handle), isTrue);
      expect(opened, <String>[id]);
      expect(await repo.openWordInAnki('雪', 'ゆき'), AnkiOpenWordOutcome.opened);
      expect(opened, <String>[id, id]);
      expect(await repo.openWordInAnki('雨', 'あめ'), AnkiOpenWordOutcome.noMatch);
      expect(await repo.openNoteInAnki(98765), isFalse);
      expect(inner.ankiCalls, 0);
    });

    test('回到出处改卡：出处在复习里时读写复习笔记；不在复习里才问 Anki', () async {
      final AnkiMiningContext ctx = bookContext();
      final MineOutcome out = await repo.mineEntry(
        rawPayloadJson: _payload('雪', 'ゆき'),
        context: ctx,
      );
      final String sourceId = ctx.sourceLink!.sourceId;
      final AnkiSourceNote? original = await repo.readSourceNote(sourceId);
      expect(original, isNotNull, reason: 'MiscInfo 的出处链接带着 sourceId');
      expect(original!.noteId, out.noteId);
      expect(inner.sourceLookups, 0);

      await repo.patchSourceNote(
        original: original,
        fields: <String, String>{'Sentence': '雪が止む。'},
      );
      expect((await noteOf('雪', 'ゆき')).field(fid('Sentence')), '雪が止む。');

      expect(await repo.readSourceNote(CardSourceLink.newSourceId()), isNull);
      expect(inner.sourceLookups, 1, reason: '复习里没有 → 交给 Anki（切换前的卡）');
    });

    test('Anki 专属能力在复习模式下关闭', () async {
      expect(repo.supportsNoteTypeEditing, isFalse);
      expect(repo.supportsMediaMaintenance, isFalse);
      expect(await repo.probeMediaMaintenance(), isFalse);
      expect(repo.supportsDeckReposition, isFalse);
      expect(await repo.rendersSynchronizedClip(), isNull);
      expect(repo.canVerifyExistingCards, isTrue);
      expect(() => repo.createDeck('X'), throwsUnsupportedError);
      expect(() => repo.listNewCards('X'), throwsUnsupportedError);
    });
  });

  test('出处转换：漫画 / 本地视频 / 在线视频 / 游戏 / 无定位', () {
    SrsSourceRef ref(AnkiMiningContext c) => srsSourceRefFromMiningContext(c);
    final SrsSourceRef manga = ref(
      AnkiMiningContext(
        sentence: '',
        sourceLink: CardSourceLink(
          kind: CardSourceKind.manga,
          uid: 'book_2',
          sourceId: CardSourceLink.newSourceId(),
          chapterId: 'ch-7',
          pageIndex: 12,
          bookKey: 'Yotsuba',
        ),
      ),
    );
    expect(manga.kind, SrsSourceKind.manga);
    expect(manga.data['mangaKey'], 'Yotsuba');
    expect(manga.data['chapterKey'], 'ch-7');
    expect(manga.data['page'], 12);

    final String fp = 'a' * 64;
    final SrsSourceRef video = ref(
      AnkiMiningContext(
        sentence: '',
        clipStartMs: 1000,
        clipEndMs: 2500,
        sourceLink: CardSourceLink(
          kind: CardSourceKind.video,
          uid: 'video/ep1',
          sourceId: CardSourceLink.newSourceId(),
          fingerprint: fp,
          episodeIndex: 0,
          startMs: 900,
          endMs: 2600,
        ),
      ),
    );
    expect(video.kind, SrsSourceKind.video);
    expect(video.data['mediaKey'], fp);
    expect(video.data['startMs'], 1000);
    expect(video.data['endMs'], 2500);

    final SrsSourceRef online = ref(
      AnkiMiningContext(
        sentence: '',
        clipStartMs: 5,
        sourceLink: CardSourceLink(
          kind: CardSourceKind.video,
          uid: 'anime-source:eu.kanade.ext:123:/ep/9?x=1',
          sourceId: CardSourceLink.newSourceId(),
          fingerprint: fp,
          episodeIndex: 0,
          startMs: 5,
          endMs: 50,
        ),
      ),
    );
    expect(online.kind, SrsSourceKind.onlineVideo);
    expect(online.data['sourceId'], 'eu.kanade.ext:123');
    expect(online.data['episodeUrl'], '/ep/9?x=1');

    expect(
      ref(
        const AnkiMiningContext(
          sentence: '',
          source: AnkiMiningSource.game,
          documentTitle: 'Game',
        ),
      ).kind,
      SrsSourceKind.game,
    );
    expect(
      ref(const AnkiMiningContext(sentence: '')).kind,
      SrsSourceKind.manual,
    );
  });

  group('ankiRepositoryProvider 装饰链', () {
    ProviderContainer container({
      required bool srsEnabled,
      required SrsMiningTarget target,
    }) {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
          appProvider.overrideWith((Ref ref) => _TargetAppModel(target)),
          srsModuleEnabledProvider.overrideWithValue(srsEnabled),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('模块关着：链上没有 SRS 层（不论偏好怎么设）', () {
      for (final SrsMiningTarget t in SrsMiningTarget.values) {
        final BaseAnkiRepository repo = container(
          srsEnabled: false,
          target: t,
        ).read(ankiRepositoryProvider);
        expect(repo, isNot(isA<SrsMiningAnkiRepository>()));
      }
    });

    test('模块开着、目标仍是 Anki：也不包', () {
      final BaseAnkiRepository repo = container(
        srsEnabled: true,
        target: SrsMiningTarget.anki,
      ).read(ankiRepositoryProvider);
      expect(repo, isNot(isA<SrsMiningAnkiRepository>()));
    });

    test('模块开着、目标是 Fushi 复习：最外层是 SRS 层', () {
      final BaseAnkiRepository repo = container(
        srsEnabled: true,
        target: SrsMiningTarget.srs,
      ).read(ankiRepositoryProvider);
      expect(repo, isA<SrsMiningAnkiRepository>());
    });
  });

  test('偏好 wire 值', () {
    // 没设过 = 新默认 Fushi 复习（所有者 2026-10-16）；认不出的显式值仍按 Anki。
    expect(SrsMiningTarget.fromWire(null), SrsMiningTarget.srs);
    expect(SrsMiningTarget.fromWire('garbage'), SrsMiningTarget.anki);
    // 只有二选一两档。
    expect(SrsMiningTarget.values, <SrsMiningTarget>[
      SrsMiningTarget.anki,
      SrsMiningTarget.srs,
    ]);
    // 已退役的「两者」存量值读成 Anki：老用户更新后继续发 Anki。
    expect(SrsMiningTarget.fromWire('both'), SrsMiningTarget.anki);
    for (final SrsMiningTarget t in SrsMiningTarget.values) {
      expect(SrsMiningTarget.fromWire(t.wire), t);
    }
  });
}

class _TargetAppModel extends AppModel {
  _TargetAppModel(this._target) : super(testPlatformServices());

  final SrsMiningTarget _target;

  @override
  SrsMiningTarget get srsMiningTarget => _target;
}

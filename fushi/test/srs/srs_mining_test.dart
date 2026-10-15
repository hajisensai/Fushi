// 挖词目标「Fushi SRS」（计划 PR3a）：SrsMiningAnkiRepository 的三种目标、字段映射、
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

  @override
  Future<AnkiSettings> loadSettings() async =>
      const AnkiSettings(tags: 'mine-tag');

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

  String fid(String key) => srsLapisFieldId(kSrsTestProfile, key);

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

  test('目标 = SRS：Lapis 字段按 fieldId 落库，媒体按内容哈希存盘并改写引用，出处为书', () async {
    final _FakeAnki inner = _FakeAnki();
    final MineOutcome out = await repoFor(inner).mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき', audio: wordAudio.path),
      context: bookContext(),
    );
    expect(out.result, MineResult.success);
    expect(inner.mined, 0, reason: '仅 SRS 时不碰 Anki');

    final SrsNoteView note = await noteOf('雪', 'ゆき');
    expect(note.noteTypeId, store.lapisNoteTypeId);
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
    expect(SrsMiningTarget.fromWire(null), SrsMiningTarget.anki);
    expect(SrsMiningTarget.fromWire('garbage'), SrsMiningTarget.anki);
    // 只有二选一两档；已退役的「两者」存量值读成 Fushi 复习。
    expect(SrsMiningTarget.values, <SrsMiningTarget>[
      SrsMiningTarget.anki,
      SrsMiningTarget.srs,
    ]);
    expect(SrsMiningTarget.fromWire('both'), SrsMiningTarget.srs);
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

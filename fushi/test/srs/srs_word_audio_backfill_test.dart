// 「补全单词音频」（反馈 LOIae5mPUS）：筛选缺音频的 Fushi 卡片、取卡上现成的词与读音、
// 逐张串行补全 / 取消 / 汇总；扫描与写字段走真 SrsDbStore（内存库），音频来源用假实现。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_word_audio_backfill.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

/// 假音频来源：按词查表；记录每次收到的（词, 读音）。
class _FakeSource {
  _FakeSource(this.table);

  /// 词 → 结果；不在表里 = 没查到；值为 null = 抛异常。
  final Map<String, SrsWordAudioFetch?> table;
  final List<(String, String)> queries = <(String, String)>[];

  Future<SrsWordAudioFetch> fetch(String term, String reading) async {
    queries.add((term, reading));
    if (!table.containsKey(term)) return const SrsWordAudioNotFound();
    final SrsWordAudioFetch? r = table[term];
    if (r == null) throw StateError('boom');
    return r;
  }
}

void main() {
  group('srsWordAudioFieldIsEmpty', () {
    test('blank / whitespace / empty markup count as empty', () {
      expect(srsWordAudioFieldIsEmpty(''), isTrue);
      expect(srsWordAudioFieldIsEmpty('   \n'), isTrue);
      expect(srsWordAudioFieldIsEmpty('<br>'), isTrue);
      expect(srsWordAudioFieldIsEmpty('<div> </div>'), isTrue);
    });

    test('any audio reference or visible text is kept', () {
      expect(srsWordAudioFieldIsEmpty('[sound:a.mp3]'), isFalse);
      expect(
        srsWordAudioFieldIsEmpty(
          '<audio class="fushi-word-audio" src="a.ogg"></audio>',
        ),
        isFalse,
      );
      expect(srsWordAudioFieldIsEmpty('note'), isFalse);
    });
  });

  group('srsWordAudioQueryText', () {
    test('drops ruby annotations and markup, keeps the base text', () {
      expect(srsWordAudioQueryText('<ruby>漢字<rt>かんじ</rt></ruby>'), '漢字');
      expect(
        srsWordAudioQueryText('<ruby>食<rp>(</rp><rt>た</rt><rp>)</rp></ruby>べる'),
        '食べる',
      );
      expect(srsWordAudioQueryText('<b>猫</b>&nbsp;'), '猫');
      expect(srsWordAudioQueryText(''), '');
    });
  });

  group('runSrsWordAudioBackfill', () {
    const List<SrsWordAudioBackfillItem> items = <SrsWordAudioBackfillItem>[
      SrsWordAudioBackfillItem(noteId: 'n1', term: '猫', reading: 'ねこ'),
      SrsWordAudioBackfillItem(noteId: 'n2', term: '犬', reading: ''),
      SrsWordAudioBackfillItem(noteId: 'n3', term: '', reading: 'から'),
      SrsWordAudioBackfillItem(noteId: 'n4', term: '鳥', reading: 'とり'),
      SrsWordAudioBackfillItem(noteId: 'n5', term: '魚', reading: 'さかな'),
      SrsWordAudioBackfillItem(noteId: 'n6', term: '馬', reading: 'うま'),
    ];

    test('fills / skips / fails and reports counts and progress', () async {
      final _FakeSource source = _FakeSource(<String, SrsWordAudioFetch?>{
        '猫': const SrsWordAudioStored('a.mp3'),
        '犬': const SrsWordAudioStored('b.ogg'),
        '鳥': const SrsWordAudioFetchFailed('HTTP 404'),
        '魚': null,
      });
      final Map<String, String> written = <String, String>{};
      final List<(int, int)> progress = <(int, int)>[];
      final SrsWordAudioBackfillResult r = await runSrsWordAudioBackfill(
        items,
        SrsWordAudioBackfillDeps(
          fetch: source.fetch,
          write: (String id, String value) async => written[id] = value,
        ),
        onProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(r.total, 6);
      expect(r.filled, 2);
      expect(r.skipped, 2); // 空词 + 没查到
      expect(r.failed, 2); // 下载失败 + 抛异常
      expect(r.cancelled, isFalse);
      expect(r.failures, hasLength(2));
      expect(written, <String, String>{
        'n1': '[sound:a.mp3]',
        'n2': '[sound:b.ogg]',
      });
      // 读音原样交给来源（空读音也原样为空，不推断）；空词的卡不查。
      expect(source.queries, <(String, String)>[
        ('猫', 'ねこ'),
        ('犬', ''),
        ('鳥', 'とり'),
        ('魚', 'さかな'),
        ('馬', 'うま'),
      ]);
      expect(progress, <(int, int)>[for (int i = 1; i <= 6; i++) (i, 6)]);
    });

    test('a write failure counts as failed, not filled', () async {
      final SrsWordAudioBackfillResult r = await runSrsWordAudioBackfill(
        items.take(1).toList(),
        SrsWordAudioBackfillDeps(
          fetch: (String term, String reading) async =>
              const SrsWordAudioStored('a.mp3'),
          write: (String id, String value) async => throw StateError('db'),
        ),
      );
      expect((r.filled, r.skipped, r.failed), (0, 0, 1));
    });

    test(
      'cancel stops before the next card and keeps what was written',
      () async {
        final Map<String, String> written = <String, String>{};
        int done = 0;
        final SrsWordAudioBackfillResult r = await runSrsWordAudioBackfill(
          items,
          SrsWordAudioBackfillDeps(
            fetch: (String term, String reading) async =>
                SrsWordAudioStored('$term.mp3'),
            write: (String id, String value) async => written[id] = value,
          ),
          onProgress: (int processed, int total) => done = processed,
          isCancelled: () => done >= 2,
        );
        expect(r.cancelled, isTrue);
        expect(r.processed, 2);
        expect(r.filled, 2);
        expect(written.keys, <String>['n1', 'n2']);
      },
    );
  });

  group('loadSrsWordAudioBackfillItems (store)', () {
    late FushiDatabase db;
    late SrsDbStore store;
    String fid(String key) => srsFushiCardFieldId(kSrsTestProfile, key);
    String lapisFid(String key) => srsLapisFieldId(kSrsTestProfile, key);

    setUp(() async {
      (db, store) = await openSrsTestStore();
    });

    tearDown(() async {
      await db.close();
    });

    Future<String> fushiNote(
      String deckId,
      String term, {
      String reading = '',
      String audio = '',
    }) => store.createNote(
      noteTypeId: store.fushiCardNoteTypeId,
      deckId: deckId,
      fieldsById: <String, String>{
        fid('Term'): term,
        if (reading.isNotEmpty) fid('TermReading'): reading,
        if (audio.isNotEmpty) fid('TermAudio'): audio,
      },
    );

    test('finds empty-audio Fushi cards in the deck subtree only, then '
        'writes the field through the store', () async {
      final String parent = await store.createDeck('JP');
      final String child = await store.createDeck('Verbs', parentId: parent);
      final String other = await store.createDeck('Other');

      final String a = await fushiNote(parent, '猫', reading: 'ねこ');
      final String b = await fushiNote(child, '<b>食べる</b>');
      await fushiNote(parent, '犬', reading: 'いぬ', audio: '[sound:x.mp3]');
      await fushiNote(other, '鳥', reading: 'とり');
      // 别的笔记类型（Lapis）不处理，即使音频为空。
      await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        deckId: parent,
        fieldsById: <String, String>{lapisFid('Expression'): '魚'},
      );
      // 已删的不处理。
      final String gone = await fushiNote(parent, '馬');
      await store.deleteNote(gone);

      final List<SrsWordAudioBackfillItem> items =
          await loadSrsWordAudioBackfillItems(store, parent);
      expect(
        items,
        unorderedEquals(<SrsWordAudioBackfillItem>[
          SrsWordAudioBackfillItem(noteId: a, term: '猫', reading: 'ねこ'),
          SrsWordAudioBackfillItem(noteId: b, term: '食べる', reading: ''),
        ]),
      );

      final SrsWordAudioBackfillFields fields =
          SrsWordAudioBackfillFields.forProfile(store.profileUid);
      final SrsWordAudioBackfillResult r = await runSrsWordAudioBackfill(
        items,
        SrsWordAudioBackfillDeps(
          fetch: (String term, String reading) async => term == '猫'
              ? const SrsWordAudioStored('neko.mp3')
              : const SrsWordAudioNotFound(),
          write: (String id, String value) => store.updateNote(
            id,
            fieldsById: <String, String>{fields.audioFieldId: value},
          ),
        ),
      );
      expect((r.filled, r.skipped, r.failed), (1, 1, 0));

      final SrsNoteView? filled = await store.note(a);
      expect(filled!.field(fid('TermAudio')), '[sound:neko.mp3]');
      expect(filled.field(fid('Term')), '猫');
      expect(filled.field(fid('TermReading')), 'ねこ');
      expect((await store.note(b))!.field(fid('TermAudio')), '');

      // 写进去的是修改记录（可同步、编辑历史可见）；补过的卡下次不再列出。
      final SrsEntityEdits edits = await store.entityEdits(
        SrsEntityKind.note,
        a,
      );
      expect(
        edits.value(SrsFieldKeys.noteField(fid('TermAudio'))),
        '[sound:neko.mp3]',
      );
      expect(
        (await loadSrsWordAudioBackfillItems(
          store,
          parent,
        )).map((SrsWordAudioBackfillItem i) => i.noteId),
        <String>[b],
      );
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

const String sourceId = '00112233-4455-4677-8899-aabbccddeeff';
final CardSourceLink link = CardSourceLink(
  kind: CardSourceKind.book,
  uid: 'book-uid',
  sourceId: sourceId,
  chapterIndex: 2,
  charOffset: 42,
);
final AnkiSourceNote original = AnkiSourceNote(
  sourceId: sourceId,
  noteId: 17,
  fields: <String, String>{'Sentence': 'original', 'Meaning': 'hand edit'},
);

void main() {
  late Directory scratch;
  late Directory root;
  late SourceReviewDraftStore store;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('fushi_source_draft_test_');
    root = Directory(p.join(scratch.path, 'drafts'));
    store = SourceReviewDraftStore(root);
  });
  tearDown(() async {
    await scratch.delete(recursive: true);
  });

  test(
    'media survives producer cleanup and every context field round trips',
    () async {
      final Directory producer = await Directory(
        p.join(scratch.path, 'producer'),
      ).create();
      final File cover = await File(
        p.join(producer.path, 'cover.png'),
      ).writeAsBytes(<int>[1, 2]);
      final File sentence = await File(
        p.join(producer.path, 'sentence.wav'),
      ).writeAsBytes(<int>[3, 4]);
      final File word = await File(
        p.join(producer.path, 'word.mp3'),
      ).writeAsBytes(<int>[5, 6]);
      final AnkiMiningContext context = AnkiMiningContext(
        sentence: 'sentence',
        cueSentence: 'cue',
        documentTitle: 'title',
        coverPath: cover.path,
        sentenceAudioPath: sentence.path,
        sentenceOffset: 8,
        source: AnkiMiningSource.book,
        bookTitleTag: 'book',
        collectionTag: 'series',
        charPositionTag: 'chars_42',
        clipStartMs: 10,
        clipEndMs: 20,
        sourceLink: link,
      );
      await store.saveMining(
        link: link,
        rawPayloadJson: jsonEncode(<String, dynamic>{
          'expression': 'word',
          'audio': word.uri.toString(),
          'glossarySelectionHighlighted': true,
        }),
        context: context,
        peerUrl:
            'https://username:secret@example.test:8765/?token=secret#secret',
        peerIdentity: 'a' * 64,
      );
      await producer.delete(recursive: true);
      final SourceReviewDraft draft = (await SourceReviewDraftStore(
        root,
      ).read(sourceId))!;
      expect(draft.peerUrl, 'https://example.test:8765');
      expect(draft.peerIdentity, 'a' * 64);
      expect(
        await File(p.join(root.path, sourceId, 'draft.json')).readAsString(),
        isNot(contains('secret')),
      );
      final AnkiMiningContext restored = draft.mining!.context;
      expect(restored.sentence, context.sentence);
      expect(restored.cueSentence, context.cueSentence);
      expect(restored.documentTitle, context.documentTitle);
      expect(restored.sentenceOffset, context.sentenceOffset);
      expect(restored.source, context.source);
      expect(restored.bookTitleTag, context.bookTitleTag);
      expect(restored.collectionTag, context.collectionTag);
      expect(restored.charPositionTag, context.charPositionTag);
      expect(restored.clipStartMs, context.clipStartMs);
      expect(restored.clipEndMs, context.clipEndMs);
      expect(restored.sourceLink!.toUri(), context.sourceLink!.toUri());
      expect(await File(restored.coverPath!).readAsBytes(), <int>[1, 2]);
      expect(await File(restored.sentenceAudioPath!).readAsBytes(), <int>[
        3,
        4,
      ]);
      final Map<String, dynamic> payload =
          jsonDecode(draft.mining!.rawPayloadJson) as Map<String, dynamic>;
      expect(await File(payload['audio'] as String).readAsBytes(), <int>[5, 6]);
      expect(payload['glossarySelectionHighlighted'], true);
    },
  );

  test(
    'patch keeps the original snapshot and prepared media until explicit delete',
    () async {
      await store.saveMining(
        link: link,
        rawPayloadJson: '{}',
        context: const AnkiMiningContext(sentence: 'new'),
        peerUrl: 'https://peer.test',
        peerIdentity: 'b' * 64,
      );
      await store.savePatch(
        original: original,
        fields: <String, String>{'Sentence': 'new'},
      );
      final SourceReviewDraft draft = (await store.read(sourceId))!;
      expect(draft.patch!.original.fields, original.fields);
      expect(draft.patch!.fields, <String, String>{'Sentence': 'new'});
      expect(draft.mining!.context.sentence, 'new');
      expect(draft.peerUrl, 'https://peer.test');
      expect(draft.peerIdentity, 'b' * 64);
      await store.delete(sourceId);
      expect(await store.read(sourceId), isNull);
      expect(await root.exists(), isTrue);
    },
  );

  test('failed media copy leaves the previous usable draft intact', () async {
    await store.savePatch(
      original: original,
      fields: <String, String>{'Sentence': 'saved'},
    );
    await expectLater(
      store.saveMining(
        link: link,
        rawPayloadJson: '{}',
        context: AnkiMiningContext(
          sentence: 'lost',
          coverPath: p.join(scratch.path, 'missing.png'),
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect((await store.read(sourceId))!.patch!.fields['Sentence'], 'saved');
  });

  test(
    'crash in Windows replace gap recovers the previous complete manifest',
    () async {
      await store.savePatch(
        original: original,
        fields: <String, String>{'Sentence': 'saved'},
      );
      final Directory directory = Directory(p.join(root.path, sourceId));
      await File(
        p.join(directory.path, 'draft.json'),
      ).rename(p.join(directory.path, 'previous-$sourceId.json'));
      await File(
        p.join(directory.path, 'next-$sourceId.json'),
      ).writeAsString('{incomplete');
      expect((await store.read(sourceId))!.patch!.fields['Sentence'], 'saved');
      await store.savePatch(
        original: original,
        fields: <String, String>{'Sentence': 'next'},
      );
      expect((await store.read(sourceId))!.patch!.fields['Sentence'], 'next');
    },
  );

  test('a corrupt current manifest falls back to its intact backup', () async {
    await store.savePatch(
      original: original,
      fields: <String, String>{'Sentence': 'one'},
    );
    await store.savePatch(
      original: original,
      fields: <String, String>{'Sentence': 'two'},
    );
    await File(
      p.join(root.path, sourceId, 'draft.json'),
    ).writeAsString('{corrupt');
    expect((await store.read(sourceId))!.patch!.fields['Sentence'], 'one');
  });

  test(
    'source IDs cannot traverse paths and delete leaves sibling drafts intact',
    () async {
      for (final String bad in <String>[
        '../outside',
        '$sourceId/..',
        sourceId.toUpperCase(),
        '',
      ]) {
        await expectLater(store.read(bad), throwsFormatException);
        await expectLater(store.delete(bad), throwsFormatException);
      }
      final Directory sibling = await Directory(
        p.join(root.path, 'keep'),
      ).create(recursive: true);
      await store.savePatch(
        original: original,
        fields: <String, String>{'Sentence': 'new'},
      );
      await store.delete(sourceId);
      expect(await sibling.exists(), isTrue);
    },
  );

  test(
    'serialized writes across store instances do not lose or truncate snapshots',
    () async {
      await Future.wait(<Future<SourceReviewDraft>>[
        store.savePatch(
          original: original,
          fields: <String, String>{'Sentence': 'one'},
        ),
        SourceReviewDraftStore(root).savePatch(
          original: original,
          fields: <String, String>{'Sentence': 'two'},
        ),
      ]);
      expect((await store.read(sourceId))!.patch!.fields['Sentence'], 'two');
    },
  );

  test(
    'inline audio stays self-contained and a new mining draft clears stale patch',
    () async {
      await store.savePatch(
        original: original,
        fields: <String, String>{'Sentence': 'old'},
      );
      const String audio = 'data:audio/mpeg;base64,AQID';
      await store.saveMining(
        link: link,
        rawPayloadJson: jsonEncode(<String, dynamic>{'audio': audio}),
        context: const AnkiMiningContext(sentence: 'new'),
      );
      final SourceReviewDraft draft = (await store.read(sourceId))!;
      expect(draft.patch, isNull);
      expect((jsonDecode(draft.mining!.rawPayloadJson) as Map)['audio'], audio);
    },
  );
}

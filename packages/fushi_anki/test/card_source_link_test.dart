import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _sourceId = '12345678-1234-4234-8234-123456789abc';
const String _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class _SourceRepository extends BaseAnkiRepository {
  List<int> matches = <int>[42];
  Map<String, String> saved = <String, String>{
    'Sentence': 'old sentence',
    'Meaning': 'my handwritten meaning',
  };
  Map<String, String>? written;
  String? concurrentSentenceAfterWrite;
  int writeCount = 0;

  Future<AnkiMiningContext> existingContext(AnkiMiningContext context) =>
      contextForExistingSourceNote(42, context);

  @override
  Future<List<int>> findSourceNoteIds(String markerTag) async {
    expect(markerTag, 'fushi_source_12345678123442348234123456789abc');
    return matches;
  }

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => saved;

  @override
  Future<void> writeSourceNoteFields(
    int noteId,
    Map<String, String> fields,
  ) async {
    written = fields;
    saved.addAll(fields);
    writeCount++;
    if (concurrentSentenceAfterWrite != null) {
      saved['Sentence'] = concurrentSentenceAfterWrite!;
    }
  }

  List<String> tags(CardSourceLink source) => buildNoteTags(
        '',
        sourceLink: source,
        includeHibiki: false,
        includeCategory: false,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CardSourceLink book() => CardSourceLink(
        kind: CardSourceKind.book,
        uid: 'portable-book-uid',
        sourceId: _sourceId,
        chapterIndex: 2,
        charOffset: 1234,
        charLength: 28,
        audioFileIndex: 1,
        startMs: 45000,
        endMs: 49000,
      );

  test('all media locators round trip with their original position', () {
    final List<CardSourceLink> links = <CardSourceLink>[
      book(),
      CardSourceLink(
        kind: CardSourceKind.video,
        fingerprint: _fingerprint,
        uid: 'video-uid',
        sourceId: _sourceId,
        episodeIndex: 2,
        startMs: 1000,
        endMs: 2400,
      ),
      CardSourceLink(
        kind: CardSourceKind.manga,
        uid: 'manga-uid',
        sourceId: _sourceId,
        pageIndex: 9,
        chapterId: 'chapter-3',
      ),
    ];
    for (final CardSourceLink link in links) {
      expect(
        CardSourceLink.parse(link.toUri().toString()).toUri(),
        link.toUri(),
      );
    }
    expect(CardSourceLink.parse(book().toUri().toString()).charOffset, 1234);
  });

  test('Windows shell root-path normalization preserves the complete locator',
      () {
    final CardSourceLink source = book();
    final String shellUrl = source.toUri().replace(path: '/').toString();
    expect(CardSourceLink.parse(shellUrl).toUri(), source.toUri());
    final String html =
        '<a href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(shellUrl)}">Fushi</a>';
    expect(CardSourceLink.fromHtml(html).single.toUri(), source.toUri());
    for (final String path in <String>['//', '/path', '/source']) {
      expect(
        () =>
            CardSourceLink.parse(source.toUri().replace(path: path).toString()),
        throwsFormatException,
      );
    }
  });

  test(
      'video requires a valid file fingerprint and preserves it across note updates',
      () {
    final CardSourceLink video = CardSourceLink(
        kind: CardSourceKind.video,
        uid: 'video/作品',
        sourceId: _sourceId,
        episodeIndex: 0,
        startMs: 1000,
        endMs: 2000,
        fingerprint: _fingerprint);
    expect(CardSourceLink.parse(video.toUri().toString()).fingerprint,
        _fingerprint);
    expect(video.withSourceId(CardSourceLink.newSourceId()).fingerprint,
        _fingerprint);
    for (final String? invalid in <String?>[
      null,
      '',
      'abc',
      '${_fingerprint}f'
    ]) {
      expect(
          () => CardSourceLink(
              kind: CardSourceKind.video,
              uid: 'video/作品',
              sourceId: _sourceId,
              episodeIndex: 0,
              startMs: 1000,
              endMs: 2000,
              fingerprint: invalid),
          throwsFormatException);
    }
  });

  test('real video namespace and Unicode title identities survive round trip',
      () {
    for (final String uid in <String>[
      'video/夏目友人帳 第1話 (2)',
      'video/playlist/我的 播放列表 (3)',
      'video/日本語 ${List<String>.filled(150, '文').join()}',
    ]) {
      final CardSourceLink link = CardSourceLink(
          kind: CardSourceKind.video,
          fingerprint: _fingerprint,
          uid: uid,
          sourceId: _sourceId,
          episodeIndex: 0,
          startMs: 15000,
          endMs: 16000);
      expect(CardSourceLink.parse(link.toUri().toString()).uid, uid);
    }
    for (final String uid in <String>[
      '/home/private.mp4',
      r'C:\private.mp4',
      'file:///private.mp4',
      '../private.mp4',
      'video/../private.mp4',
      'video/\u0000title'
    ]) {
      expect(
          () => CardSourceLink(
              kind: CardSourceKind.video,
              fingerprint: _fingerprint,
              uid: uid,
              sourceId: _sourceId,
              episodeIndex: 0,
              startMs: 0,
              endMs: 1),
          throwsFormatException);
    }
  });

  test(
    'AnkiConnect source lookup verifies exact tags and rejects malformed data',
    () async {
      final String marker = book().markerTag;
      bool malformed = false;
      final AnkiConnectService service = AnkiConnectService(
        client: MockClient((http.Request request) async {
          final Map<String, dynamic> body =
              jsonDecode(request.body) as Map<String, dynamic>;
          final Object result;
          if (body['action'] == 'findNotes') {
            expect(body['params']['query'], 'tag:$marker');
            result = <int>[42, 43];
          } else {
            expect(body['action'], 'notesInfo');
            result = <Object>[
              <String, Object>{
                'noteId': 42,
                'tags': <String>[marker],
              },
              <String, Object>{
                'noteId': 43,
                if (!malformed) 'tags': <String>['$marker::descendant'],
              },
            ];
          }
          return http.Response(
            jsonEncode(<String, Object?>{'result': result, 'error': null}),
            200,
          );
        }),
      );
      expect(await service.findNotesBySourceMarker(marker), <int>[42]);
      malformed = true;
      await expectLater(
        service.findNotesBySourceMarker(marker),
        throwsA(isA<AnkiConnectException>()),
      );
    },
  );

  test('rejects commands, paths, invalid anchors and ambiguous URL inputs', () {
    final String valid = book().toUri().toString();
    for (final String raw in <String>[
      valid.replaceFirst('v=1', 'v=2'),
      valid.replaceFirst('charOffset=1234', 'charOffset=-1'),
      valid.replaceFirst('charOffset=1234', 'charOffset=1.5'),
      valid.replaceFirst('charOffset=1234', 'charOffset=2147483648'),
      valid.replaceFirst('charOffset=1234', 'charOffset=01'),
      valid.replaceFirst('uid=portable-book-uid', 'uid=C%3A%5Csecret.epub'),
      valid.replaceFirst('kind=book', 'kind=video'),
      valid.replaceFirst('endMs=49000', 'endMs=1'),
      '$valid&v=1',
      '$valid&command=delete',
      '$valid#fragment',
      valid.replaceFirst('fushi://source', 'fushi://source/path'),
      valid.replaceFirst('fushi://source', 'fushi://user@source'),
      'file:///tmp/book.epub',
    ]) {
      expect(CardSourceLink.tryParse(raw), isNull, reason: raw);
    }
  });

  test('HTML escaping and media replacement preserve the source link', () {
    final CardSourceLink link = book();
    final AnkiMiningContext copied = AnkiMiningContext(
      sentence: 'sentence',
      sourceLink: link,
      coverPath: '/private/local.png',
    ).withMediaRefs(
      coverRef: '<img src="uploaded.png">',
      sentenceAudioRef: null,
    );
    expect(copied.sourceLink, same(link));
    final String html = AnkiHandlebarRenderer.render(
      '{source-link}',
      const AnkiMiningPayload(expression: 'word'),
      copied,
    );
    expect(html, contains('fushi://source?'));
    expect(html, contains('&amp;'));
    expect(html, isNot(contains('/private')));
    expect(link.toHtml(label: '<script>'), contains('&lt;script&gt;'));
  });

  test('source marker is always present independently of optional tags', () {
    expect(_SourceRepository().tags(book()), <String>[book().markerTag]);
    expect(
      CardSourceLink.markerForSourceId(CardSourceLink.newSourceId()),
      matches(RegExp(r'^fushi_source_[0-9a-f]{32}$')),
    );
  });

  test('AnkiDroid resolves the marker and sends only the selected fields',
      () async {
    const MethodChannel channel = MethodChannel('app.fushi.reader/anki');
    final List<MethodCall> calls = <MethodCall>[];
    final Map<String, String> fields = <String, String>{
      'Sentence': 'original',
      'Meaning': 'manual note',
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'requestAnkidroidPermissions':
          return true;
        case 'findNotesBySourceMarker':
          expect((call.arguments as Map)['markerTag'], book().markerTag);
          return <int>[42];
        case 'notesInfo':
          return fields;
        case 'updateNoteFields':
          fields.addAll(Map<String, String>.from(
              (call.arguments as Map)['fieldValues'] as Map));
          return true;
        default:
          throw StateError('Unexpected channel call ${call.method}');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final AnkiRepository repo = AnkiRepository();
    final AnkiSourceNote original = (await repo.readSourceNote(_sourceId))!;
    await repo.patchSourceNote(
        original: original,
        fields: <String, String>{'Sentence': 'replacement'});
    final MethodCall write =
        calls.singleWhere((MethodCall c) => c.method == 'updateNoteFields');
    expect(write.arguments, <String, Object>{
      'noteId': 42,
      'fieldValues': <String, String>{'Sentence': 'replacement'}
    });
  });

  test(
    'ordinary overwrite keeps original marker identity and new position',
    () async {
      final _SourceRepository repo = _SourceRepository();
      repo.saved['MiscInfo'] = book().toHtml();
      final CardSourceLink next = CardSourceLink(
        kind: CardSourceKind.book,
        uid: book().uid,
        sourceId: CardSourceLink.newSourceId(),
        chapterIndex: 3,
        charOffset: 999,
      );
      final AnkiMiningContext adjusted = await repo.existingContext(
        AnkiMiningContext(sentence: 'new', sourceLink: next),
      );
      expect(adjusted.sourceLink!.sourceId, _sourceId);
      expect(adjusted.sourceLink!.charOffset, 999);
      expect(adjusted.sourceLink!.chapterIndex, 3);
    },
  );

  test(
    'ordinary overwrite does not add an unbound source URL to legacy notes',
    () async {
      final AnkiMiningContext adjusted =
          await _SourceRepository().existingContext(
        AnkiMiningContext(sentence: 'new', sourceLink: book()),
      );
      expect(adjusted.sourceLink, isNull);
    },
  );

  test(
      'ordinary overwrite without a locator preserves the entire old source link',
      () async {
    final _SourceRepository repo = _SourceRepository();
    repo.saved['MiscInfo'] = 'Original title ${book().toHtml()}';
    final AnkiMiningContext adjusted = await repo.existingContext(
        const AnkiMiningContext(sentence: 'dictionary update'));
    expect(adjusted.sourceLink!.toUri(), book().toUri());
    expect(adjusted.sentence, 'dictionary update');
  });

  test('all exact legacy defaults migrate while custom mappings survive', () {
    for (final String value in <String>[
      '{document-title}',
      '{document-title} {clip-timestamp}',
      '{document-title} {clip-timestamp} {source-link}',
    ]) {
      final String upgraded = BaseAnkiRepository.upgradeMiscInfoMapping(
        jsonEncode(<String, Object>{
          'fieldMappings': <String, String>{
            'MiscInfo': value,
            'Meaning': '{glossary}',
          },
        }),
      )!;
      expect(
        (jsonDecode(upgraded) as Map)['fieldMappings']['MiscInfo'],
        LapisNoteType.defaultFieldMappings['MiscInfo'],
      );
      expect(BaseAnkiRepository.upgradeMiscInfoMapping(upgraded), isNull);
    }
    expect(
      BaseAnkiRepository.upgradeMiscInfoMapping(
        jsonEncode(<String, Object>{
          'fieldMappings': <String, String>{
            'MiscInfo': '{document-title} custom',
          },
        }),
      ),
      isNull,
    );
  });

  test(
    'partial patch keeps unselected manual fields even when they changed',
    () async {
      final _SourceRepository repo = _SourceRepository();
      final AnkiSourceNote original = (await repo.readSourceNote(_sourceId))!;
      repo.saved['Meaning'] = 'edited elsewhere';
      await repo.patchSourceNote(
        original: original,
        fields: <String, String>{'Sentence': 'new sentence'},
      );
      expect(repo.written, <String, String>{'Sentence': 'new sentence'});
      expect(repo.saved['Meaning'], 'edited elsewhere');
    },
  );

  test('selected-field conflicts reject before writing', () async {
    final _SourceRepository repo = _SourceRepository();
    final AnkiSourceNote original = (await repo.readSourceNote(_sourceId))!;
    repo.saved['Sentence'] = 'edited elsewhere';
    await expectLater(
      repo.patchSourceNote(
        original: original,
        fields: <String, String>{'Sentence': 'replacement'},
      ),
      throwsStateError,
    );
    expect(repo.written, isNull);
  });

  test(
      'write-after-read conflict preserves concurrent changes without retry or rollback',
      () async {
    final _SourceRepository repo = _SourceRepository();
    final AnkiSourceNote original = (await repo.readSourceNote(_sourceId))!;
    repo.concurrentSentenceAfterWrite = 'newer external edit';
    await expectLater(
        repo.patchSourceNote(
            original: original,
            fields: <String, String>{'Sentence': 'replacement'}),
        throwsStateError);
    expect(repo.writeCount, 1);
    expect(repo.saved['Sentence'], 'newer external edit');
    expect(original.fields['Sentence'], 'old sentence');
  });

  test(
    'marker deletion, duplication or identity change rejects before writing',
    () async {
      for (final List<int> matches in <List<int>>[
        <int>[],
        <int>[42, 43],
        <int>[43],
      ]) {
        final _SourceRepository repo = _SourceRepository();
        final AnkiSourceNote original = (await repo.readSourceNote(_sourceId))!;
        repo.matches = matches;
        await expectLater(
          repo.patchSourceNote(
            original: original,
            fields: <String, String>{'Sentence': 'replacement'},
          ),
          throwsStateError,
        );
        expect(repo.written, isNull);
      }
    },
  );
}

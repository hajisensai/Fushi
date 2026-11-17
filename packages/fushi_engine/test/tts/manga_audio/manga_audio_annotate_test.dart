import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

MokuroBlock _block(String text, {double left = 0, double top = 0}) =>
    MokuroBlock(
      rectangle: MokuroRect.fromLTRB(left, top, left + 100, top + 200),
      isVertical: true,
      fontSize: 12,
      zIndex: 0,
      lines: <String>[text],
    );

MokuroImage _page(List<MokuroBlock> blocks) => MokuroImage(
  url: 'p.jpg',
  size: const MokuroSize(1000, 2000),
  blocks: blocks,
);

Map<String, TtsCastCharacter> _roster() => <String, TtsCastCharacter>{
  '宮城': const TtsCastCharacter(
    name: '宮城',
    aliases: <String>['宮城さん'],
    gender: 'female',
    age: 'teen',
  ),
  '仙台': const TtsCastCharacter(name: '仙台'),
};

MangaScriptLine _line(
  int page,
  List<int> blocks, {
  String speaker = '宮城',
  CastLineKind kind = CastLineKind.spoken,
  TtsCastSource source = TtsCastSource.llm,
}) => MangaScriptLine(
  page: page,
  blocks: blocks,
  speaker: speaker,
  kind: kind,
  source: source,
);

void main() {
  group('prompts', () {
    test('page prompt lists normalized boxes, roster and previous lines', () {
      final String prompt = buildMangaPageUserPrompt(
        page: 4,
        pageCount: 20,
        image: _page(<MokuroBlock>[
          _block('こんにちは', left: 500, top: 1000),
          _block('"引用"'),
        ]),
        roster: _roster().values,
        previous: const <MangaPreviousLine>[
          (speaker: kTtsUnknown, kind: CastLineKind.shout, text: 'まて'),
        ],
      );
      expect(prompt, contains('[page 5 of 20]'));
      expect(prompt, contains('- 宮城 | aliases: 宮城さん | female | teen'));
      expect(prompt, contains('0 [500,500,600,600] V "こんにちは"'));
      // 文字按 JSON 字面量写出：引号转义，不会和行结构串。
      expect(prompt, contains(r'1 [0,0,100,100] V "\"引用\""'));
      expect(prompt, contains('- UNKNOWN (shout): "まて"'));
    });

    test('page system prompt carries the closed vocabularies', () {
      for (final CastLineKind k in CastLineKind.values) {
        expect(kMangaPageSystemPrompt, contains('"${k.wire}"'));
      }
      for (final CastEmotion e in CastEmotion.values) {
        expect(kMangaPageSystemPrompt, contains('"${e.wire}"'));
      }
    });

    test('roster prompt names attached images in order', () {
      final String prompt = buildMangaRosterUserPrompt(
        roster: const <TtsCastCharacter>[],
        pages: <({int page, MokuroImage image})>[
          (page: 2, image: _page(<MokuroBlock>[_block('あ')])),
          (page: 3, image: _page(const <MokuroBlock>[])),
        ],
        hasCover: true,
      );
      expect(prompt, contains('(empty)'));
      expect(
        prompt,
        contains('3 attached in order: the cover, then page 3, page 4.'),
      );
      expect(prompt, contains('[page 4 text blocks]\n(no text)'));
    });

    test('roster image pages skip the cover and textless pages', () {
      final List<MokuroImage> images = <MokuroImage>[
        _page(<MokuroBlock>[_block('表紙')]),
        _page(const <MokuroBlock>[]),
        for (int i = 0; i < 6; i++) _page(<MokuroBlock>[_block('$i')]),
      ];
      expect(mangaRosterImagePages(images), <int>[2, 3, 4, 5]);
    });
  });

  group('parseMangaRosterReply', () {
    test('keeps valid characters, drops reserved names and bad enums', () {
      final List<TtsCastCharacter>? out = parseMangaRosterReply('''
```json
{"characters":[
 {"name":"宮城","aliases":["宮城","宮城ちゃん"],"gender":"female","age":"teen"},
 {"name":"UNKNOWN"},
 {"name":"店員","gender":"robot","age":"ageless","desc":" polite "}
]}
```''');
      expect(out, isNotNull);
      expect(out!.map((TtsCastCharacter c) => c.name), <String>['宮城', '店員']);
      expect(out.first.aliases, <String>['宮城ちゃん']);
      expect(out.last.gender, isNull);
      expect(out.last.age, isNull);
      expect(out.last.description, 'polite');
    });

    test('non-object reply is null', () {
      expect(parseMangaRosterReply('no idea'), isNull);
      expect(parseMangaRosterReply('{"cast":[]}'), isNull);
    });
  });

  group('parseMangaPageReply', () {
    test('aliases map to canonical names, new characters join the roster', () {
      final Map<String, TtsCastCharacter> roster = _roster();
      final MangaPageAnnotation? a = parseMangaPageReply(
        jsonEncode(<String, Object?>{
          'lines': <Object?>[
            <String, Object?>{
              'b': <int>[2, 0],
              's': '宮城さん',
              'k': 'spoken',
            },
            <String, Object?>{
              'b': <int>[1],
              's': '店員',
              'k': 'shout',
              'c': 0.4,
            },
            <String, Object?>{
              'b': <int>[3],
              's': 'NARRATOR',
              'k': 'narration',
            },
            <String, Object?>{
              'b': <int>[4],
              's': 'UNKNOWN',
              'k': 'skip',
            },
          ],
          'new': <Object?>[
            <String, Object?>{'name': '店員', 'gender': 'female'},
            <String, Object?>{'name': '宮城'},
          ],
          'hold': 9000,
          'lead': 99999,
        }),
        page: 7,
        blockCount: 5,
        roster: roster,
      );
      expect(a, isNotNull);
      expect(a!.newCharacters.map((TtsCastCharacter c) => c.name), <String>[
        '店員',
      ]);
      expect(roster.keys, contains('店員'));
      final List<MangaScriptLine> lines = a.validation.accepted;
      expect(lines.map((MangaScriptLine l) => l.speaker), <String>[
        '宮城',
        '店員',
        kTtsNarrator,
        kTtsUnknown,
      ]);
      expect(lines.first.blocks, <int>[2, 0]);
      expect(lines.first.page, 7);
      expect(lines[1].confidence, 0.4);
      // 模型有意标「不读」的行照样保留为不读。
      expect(lines.last.kind, CastLineKind.skip);
      expect(a.validation.rejected, isEmpty);
      // 有发声行：hold 丢掉，lead 夹到上限。
      expect(a.directive.holdMs, isNull);
      expect(a.directive.leadMs, MangaScriptLimits.maxLeadMs);
      expect(a.allRejected, isFalse);
    });

    test(
      'invalid lines are rejected with reasons; all rejected flags page',
      () {
        final MangaPageAnnotation? a = parseMangaPageReply(
          jsonEncode(<String, Object?>{
            'lines': <Object?>[
              <String, Object?>{
                'b': <int>[9],
                's': '宮城',
                'k': 'spoken',
              },
              <String, Object?>{
                'b': <int>[0],
                's': '誰か',
                'k': 'spoken',
              },
              <String, Object?>{
                'b': <int>[1],
                's': '宮城',
                'k': 'whisper',
              },
            ],
          }),
          page: 0,
          blockCount: 2,
          roster: _roster(),
        );
        expect(
          a!.validation.rejected.map((MangaRejectedLine r) => r.reason),
          <MangaLineRejection>[
            MangaLineRejection.blockOutOfRange,
            MangaLineRejection.unknownSpeaker,
            MangaLineRejection.unknownKind,
          ],
        );
        expect(a.allRejected, isTrue);
        expect(a.validation.unclaimedBlocks, <int>[0, 1]);
      },
    );

    test(
      'empty lines on a textless decision keeps hold and is not a failure',
      () {
        final MangaPageAnnotation? a = parseMangaPageReply(
          '{"lines":[],"hold":5000}',
          page: 3,
          blockCount: 2,
          roster: _roster(),
        );
        expect(a!.allRejected, isFalse);
        expect(a.directive.holdMs, 5000);
      },
    );

    test('no lines array is null', () {
      expect(
        parseMangaPageReply(
          '{"x":1}',
          page: 0,
          blockCount: 1,
          roster: _roster(),
        ),
        isNull,
      );
    });
  });

  group('previous lines and scenes', () {
    test('previous lines are the last audible lines before the page', () {
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0, <int>[0]),
          _line(1, <int>[0], kind: CastLineKind.skip),
          _line(1, <int>[1], speaker: '仙台'),
          _line(2, <int>[0]),
        ],
      );
      final List<MangaPreviousLine> prev = mangaPreviousLines(
        script,
        2,
        (MangaScriptLine l) => l.lineId,
      );
      expect(prev.map((MangaPreviousLine l) => l.text), <String>[
        'p0b0',
        'p1b1',
      ]);
    });

    test('scenes split on gaps, page and line caps', () {
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          for (final int p in <int>[0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])
            _line(p, <int>[0]),
          _line(3, <int>[0], kind: CastLineKind.skip),
        ],
      );
      final List<MangaScene> scenes = chunkMangaScenes(
        script,
        List<int>.generate(12, (int i) => i),
      );
      expect(scenes, <List<int>>[
        <int>[0, 1, 2],
        <int>[4, 5, 6, 7, 8, 9],
        <int>[10, 11],
      ]);
      expect(chunkMangaScenes(script, <int>[0, 1, 2], maxLines: 2), <List<int>>[
        <int>[0, 1],
        <int>[2],
      ]);
    });
  });

  group('scene review', () {
    test('edits apply only to AI lines inside the scene, fields validated', () {
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(0, <int>[0], speaker: kTtsUnknown),
          _line(0, <int>[1], source: TtsCastSource.user),
          _line(1, <int>[0]),
          _line(5, <int>[0]),
        ],
      );
      final List<MangaReviewEdit>? edits = parseMangaSceneReviewReply(
        jsonEncode(<String, Object?>{
          'edits': <Object?>[
            <String, Object?>{'id': 'p0b0', 's': '仙台', 'e': 'anger', 'ei': 300},
            <String, Object?>{'id': 'p0b1', 's': '仙台'},
            <String, Object?>{'id': 'p1b0', 's': '知らない人', 'k': 'thought'},
            <String, Object?>{'id': 'p5b0', 's': '仙台'},
            <String, Object?>{'id': 'p1b0', 'k': 'bogus'},
          ],
        }),
        roster: _roster(),
      );
      expect(edits, hasLength(4));
      final int changed = applyMangaSceneReview(script, <int>[0, 1], edits!);
      expect(changed, 2);
      expect(script.lines[0].speaker, '仙台');
      expect(script.lines[0].emotion, CastEmotion.anger);
      expect(script.lines[0].intensity, MangaScriptLimits.maxIntensity);
      expect(script.lines[1].speaker, '宮城', reason: 'user line untouched');
      expect(script.lines[2].speaker, '宮城', reason: 'unknown name dropped');
      expect(script.lines[2].kind, CastLineKind.thought);
      expect(script.lines[3].speaker, '宮城', reason: 'outside the scene');
    });

    test('review prompt lists audible lines with ids', () {
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          _line(2, <int>[1, 0], speaker: kTtsNarrator),
          _line(2, <int>[2], kind: CastLineKind.skip),
        ],
      );
      final String prompt = buildMangaSceneReviewUserPrompt(
        script: script,
        scene: <int>[2],
        roster: _roster().values,
        textOf: (MangaScriptLine l) => 'T',
      );
      expect(prompt, contains('p2b1.0 | NARRATOR | spoken | - | 0 | "T"'));
      expect(prompt, isNot(contains('p2b2')));
    });
  });

  group('series roster', () {
    test('merged roster keeps series names; learning carries forward', () {
      final SeriesCastProfile series = SeriesCastProfile(
        seriesKey: 'collection:1',
        roster: _roster(),
      );
      final Map<String, TtsCastCharacter> volume = <String, TtsCastCharacter>{
        '宮城さん': const TtsCastCharacter(name: '宮城さん', description: 'x'),
        '舞香': const TtsCastCharacter(name: '舞香'),
      };
      final Map<String, TtsCastCharacter> merged = mergedMangaRoster(
        series: series.roster,
        volume: volume,
      );
      expect(merged.keys, <String>['宮城', '仙台', '舞香']);
      expect(merged['宮城']!.description, 'x');

      series.learnRoster(merged.values);
      expect(series.roster.keys, containsAll(<String>['宮城', '仙台', '舞香']));
      // 下一卷用系列角色表起步：别名照样归到同一个人。
      final Map<String, TtsCastCharacter> next = mergedMangaRoster(
        series: series.roster,
        volume: const <String, TtsCastCharacter>{},
      );
      expect(normalizeMangaSpeaker(next, '宮城さん'), '宮城');
    });
  });

  group('estimate and image size', () {
    test('estimate counts only pages with text', () {
      final MangaAnnotationEstimate e = estimateMangaAnnotation(<int>[
        0,
        3,
        5,
        0,
        ...List<int>.filled(10, 1),
      ]);
      expect(e.pageRequests, 12);
      expect(e.rosterRequests, 1);
      expect(e.reviewRequests, 2);
      expect(e.total, 15);
      expect(e.imageRequests, 13);
      expect(estimateMangaAnnotation(<int>[0, 0]).total, 0);
    });

    test('image target keeps aspect and never upscales', () {
      expect(mangaAnnotateImageTarget(1000, 1200), isNull);
      expect(mangaAnnotateImageTarget(2000, 3000), (width: 853, height: 1280));
      expect(mangaAnnotateImageTarget(0, 10), isNull);
    });
  });

  group('ledger', () {
    test('retry bookkeeping walks providers not yet tried', () {
      final MangaAnnotationLedger ledger = MangaAnnotationLedger();
      ledger.recordFailure(
        stage: MangaAnnotateStage.page,
        page: 4,
        providerId: 'a',
        model: 'm1',
        code: MangaAnnotateFailureCode.network,
      );
      final MangaAnnotateFailure f = ledger.recordFailure(
        stage: MangaAnnotateStage.page,
        page: 4,
        providerId: 'b',
        model: 'm2',
        code: MangaAnnotateFailureCode.validation,
      );
      expect(f.attempts, hasLength(2));
      expect(f.nextRetryProvider(<String>['a', 'b', 'c']), 'c');
      expect(f.nextRetryProvider(<String>['a', 'b']), isNull);
      expect(ledger.failedPages, <int>[4]);
      expect(ledger.resolve(MangaAnnotateStage.page, 4), isTrue);
      expect(ledger.failedPages, isEmpty);
    });

    test('json round trip and store deletes empty ledgers', () async {
      final Directory dir = await Directory.systemTemp.createTemp('ledger');
      addTearDown(() => dir.delete(recursive: true));
      final MangaAnnotationLedgerStore store = MangaAnnotationLedgerStore(dir);
      final MangaAnnotationLedger ledger = MangaAnnotationLedger();
      ledger.recordFailure(
        stage: MangaAnnotateStage.review,
        page: 10,
        scene: <int>[10, 11],
        providerId: 'a',
        model: 'm',
        code: MangaAnnotateFailureCode.aiFailed,
        detail: 'http_401',
        now: DateTime.fromMillisecondsSinceEpoch(5),
      );
      ledger.setRejected(3, <MangaRejectedLine>[
        const MangaRejectedLine(
          index: 0,
          raw: <String, Object?>{
            'b': <Object?>[7, 'x'],
          },
          reason: MangaLineRejection.blockOutOfRange,
          detail: '7',
        ),
      ]);
      await store.save('book', ledger);
      final MangaAnnotationLedger back = await store.load('book');
      final MangaAnnotateFailure f = back.failureOf(
        MangaAnnotateStage.review,
        10,
      )!;
      expect(f.scene, <int>[10, 11]);
      expect(f.last!.detail, 'http_401');
      expect(f.last!.atMs, 5);
      expect(back.rejected[3]!.single.blocks, <int>[7]);
      expect(
        back.rejected[3]!.single.reason,
        MangaLineRejection.blockOutOfRange,
      );

      back.clear();
      await store.save('book', back);
      expect(await store.fileFor('book').exists(), isFalse);
    });
  });
}

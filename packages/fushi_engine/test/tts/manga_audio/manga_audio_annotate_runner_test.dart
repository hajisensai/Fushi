import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

MokuroBlock _block(String text) => MokuroBlock(
  rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
  isVertical: true,
  fontSize: 12,
  zIndex: 0,
  lines: <String>[text],
);

MokuroImage _page(int blocks) => MokuroImage(
  url: 'p.jpg',
  size: const MokuroSize(100, 100),
  blocks: <MokuroBlock>[for (int i = 0; i < blocks; i++) _block('t$i')],
);

/// 页 0 封面（1 块）、页 1 两块、页 2 无字、页 3 一块。
MokuroPayload _payload({String signature = 'sig-1'}) => MokuroPayload(
  images: <MokuroImage>[_page(1), _page(2), _page(0), _page(1)],
  ocr: MangaOcrMetadata(
    engine: 'test',
    engineSignature: signature,
    schemaVersion: 1,
  ),
);

String _pageReply(List<Map<String, Object?>> lines, {Object? extra}) =>
    jsonEncode(<String, Object?>{
      'lines': lines,
      if (extra is Map<String, Object?>) ...extra,
    });

/// 按系统提示词分派回复；[pageReplies] 按页给（值为 Exception 时抛出）。
class _FakeAi {
  _FakeAi({
    required this.roster,
    required this.pageReplies,
    this.review = '{"edits":[]}',
  });

  final Object roster;
  final Map<int, Object> pageReplies;
  final Object review;
  final List<List<AiChatMessage>> calls = <List<AiChatMessage>>[];

  Future<String> ask(List<AiChatMessage> messages) async {
    calls.add(messages);
    final String system = messages.first.content;
    final String user = messages.last.content;
    final Object reply;
    if (system == kMangaRosterSystemPrompt) {
      reply = roster;
    } else if (system == kMangaSceneReviewSystemPrompt) {
      reply = review;
    } else {
      final int page =
          int.parse(RegExp(r'\[page (\d+) of').firstMatch(user)!.group(1)!) - 1;
      reply = pageReplies[page]!;
    }
    if (reply is Exception) throw reply;
    return reply as String;
  }
}

MangaAnnotateRunner _runner(
  _FakeAi ai, {
  MangaAudioScript? script,
  MangaAnnotationLedger? ledger,
  Map<String, TtsCastCharacter> series = const <String, TtsCastCharacter>{},
  MokuroPayload? payload,
  String providerId = 'prov-a',
  Set<int> unreadableImages = const <int>{},
  List<String>? log,
}) => MangaAnnotateRunner(
  payload: payload ?? _payload(),
  script: script ?? MangaAudioScript(),
  ledger: ledger ?? MangaAnnotationLedger(),
  seriesRoster: series,
  ask: ai.ask,
  imageFor: (int page) async =>
      unreadableImages.contains(page) ? null : AiChatImage(bytes: <int>[page]),
  providerId: providerId,
  model: 'model-x',
  checkpoint: () async => log?.add('save'),
  isCancelled: () => false,
  clock: () => DateTime.fromMillisecondsSinceEpoch(1),
);

void main() {
  test(
    'three passes: series roster seeds, new names learned, review applied',
    () async {
      final _FakeAi ai = _FakeAi(
        roster: '{"characters":[{"name":"仙台","gender":"female"}]}',
        pageReplies: <int, Object>{
          0: _pageReply(<Map<String, Object?>>[
            <String, Object?>{
              'b': <int>[0],
              's': 'NARRATOR',
              'k': 'narration',
            },
          ]),
          1: _pageReply(
            <Map<String, Object?>>[
              <String, Object?>{
                'b': <int>[1],
                's': '宮城さん',
                'k': 'spoken',
              },
              <String, Object?>{
                'b': <int>[0],
                's': '店員',
                'k': 'skip',
              },
            ],
            extra: <String, Object?>{
              'new': <Object?>[
                <String, Object?>{'name': '店員'},
              ],
            },
          ),
          3: _pageReply(<Map<String, Object?>>[
            <String, Object?>{
              'b': <int>[0],
              's': 'UNKNOWN',
              'k': 'spoken',
            },
          ]),
        },
        review: '{"edits":[{"id":"p3b0","s":"仙台"}]}',
      );
      final List<String> log = <String>[];
      final MangaAudioScript script = MangaAudioScript();
      final MangaAnnotateRunner runner = _runner(
        ai,
        script: script,
        log: log,
        series: <String, TtsCastCharacter>{
          '宮城': const TtsCastCharacter(name: '宮城', aliases: <String>['宮城さん']),
        },
      );
      final MangaAnnotateRunSummary summary = await runner.run(
        pages: mangaPagesToAnnotate(script, 4),
      );

      expect(summary.annotatedPages, <int>[0, 1, 2, 3]);
      expect(summary.failedPages, isEmpty);
      expect(script.engineSignature, 'sig-1');
      expect(script.annotatedPages, <int>{0, 1, 2, 3});
      // 无字页不发请求：角色表 1 + 有字页 3 + 复核（页 0..1 一场、页 3 一场）2。
      expect(ai.calls, hasLength(6));
      // 角色表请求带封面 + 有字的正文页。
      expect(ai.calls.first.last.images, hasLength(3));
      expect(script.lines.map((MangaScriptLine l) => l.speaker), <String>[
        kTtsNarrator,
        '宮城',
        '店員',
        '仙台',
      ]);
      expect(script.lines[2].kind, CastLineKind.skip);
      expect(script.roster.keys, containsAll(<String>['宮城', '仙台', '店員']));
      expect(
        runner.workingRoster.keys,
        containsAll(<String>['宮城', '仙台', '店員']),
      );
      expect(summary.reviewedLines, 1);
      expect(log.length, greaterThanOrEqualTo(4));
      expect(runner.ledger.isEmpty, isTrue);
    },
  );

  test('per-page failures are recorded and the volume keeps going', () async {
    final _FakeAi ai = _FakeAi(
      roster: '{"characters":[]}',
      pageReplies: <int, Object>{
        0: const AiChatFailure('network_error'),
        1: 'not json at all',
        3: _pageReply(<Map<String, Object?>>[
          <String, Object?>{
            'b': <int>[5],
            's': 'UNKNOWN',
            'k': 'spoken',
          },
        ]),
      },
    );
    final MangaAnnotateRunner runner = _runner(ai);
    final MangaAnnotateRunSummary s = await runner.run(
      pages: <int>[0, 1, 2, 3],
      withReview: false,
    );
    expect(s.annotatedPages, <int>[2]);
    expect(s.failedPages, <int>[0, 1, 3]);
    final MangaAnnotationLedger ledger = runner.ledger;
    expect(
      ledger.failureOf(MangaAnnotateStage.page, 0)!.last!.code,
      MangaAnnotateFailureCode.network,
    );
    expect(
      ledger.failureOf(MangaAnnotateStage.page, 1)!.last!.code,
      MangaAnnotateFailureCode.badOutput,
    );
    expect(
      ledger.failureOf(MangaAnnotateStage.page, 3)!.last!.code,
      MangaAnnotateFailureCode.validation,
    );
    expect(ledger.rejected[3], hasLength(1));
    expect(
      ledger.failureOf(MangaAnnotateStage.page, 0)!.last!.providerId,
      'prov-a',
    );
  });

  test('unreadable page image is an image failure, no request sent', () async {
    final _FakeAi ai = _FakeAi(
      roster: '{"characters":[]}',
      pageReplies: <int, Object>{},
    );
    final MangaAnnotateRunner runner = _runner(ai, unreadableImages: <int>{3});
    await runner.run(pages: <int>[3], withRoster: false);
    expect(ai.calls, isEmpty);
    expect(
      runner.ledger.failureOf(MangaAnnotateStage.page, 3)!.last!.code,
      MangaAnnotateFailureCode.image,
    );
  });

  test(
    'non-transient failure aborts the run; later pages stay unannotated',
    () async {
      final _FakeAi ai = _FakeAi(
        roster: '{"characters":[]}',
        pageReplies: <int, Object>{
          0: const AiChatFailure('http_401'),
          1: _pageReply(const <Map<String, Object?>>[]),
        },
      );
      final MangaAnnotateRunner runner = _runner(ai);
      await expectLater(
        runner.run(pages: <int>[0, 1], withRoster: false),
        throwsA(
          isA<MangaAnnotateAbort>().having(
            (MangaAnnotateAbort a) => a.code,
            'code',
            'http_401',
          ),
        ),
      );
      expect(runner.script.annotatedPages, isEmpty);
      expect(runner.ledger.failedPages, <int>[0]);
      expect(
        runner.ledger.failureOf(MangaAnnotateStage.page, 0)!.last!.code,
        MangaAnnotateFailureCode.aiFailed,
      );
    },
  );

  test(
    'retry with another provider resolves the failure and keeps user edits',
    () async {
      final MangaAnnotationLedger ledger = MangaAnnotationLedger();
      final MangaAudioScript script = MangaAudioScript(
        lines: <MangaScriptLine>[
          MangaScriptLine(
            page: 1,
            blocks: const <int>[0],
            speaker: kTtsNarrator,
            kind: CastLineKind.narration,
            source: TtsCastSource.user,
            say: '手で書いた',
          ),
        ],
      );
      final _FakeAi failing = _FakeAi(
        roster: '{"characters":[]}',
        pageReplies: <int, Object>{1: 'garbage'},
      );
      await _runner(
        failing,
        script: script,
        ledger: ledger,
      ).run(pages: <int>[1], withRoster: false, withReview: false);
      final MangaAnnotateFailure failure = ledger.failureOf(
        MangaAnnotateStage.page,
        1,
      )!;
      expect(failure.nextRetryProvider(<String>['prov-a', 'prov-b']), 'prov-b');

      final _FakeAi other = _FakeAi(
        roster: '{"characters":[]}',
        pageReplies: <int, Object>{
          1: _pageReply(<Map<String, Object?>>[
            <String, Object?>{
              'b': <int>[0, 1],
              's': 'UNKNOWN',
              'k': 'spoken',
            },
          ]),
        },
      );
      final MangaAnnotateRunSummary s = await _runner(
        other,
        script: script,
        ledger: ledger,
        providerId: 'prov-b',
      ).retry(failure);
      expect(s.annotatedPages, <int>[1]);
      expect(ledger.failedPages, isEmpty);
      // 与用户行共用块的 AI 新行让位给用户行。
      expect(script.linesOnPage(1).single.say, '手で書いた');
    },
  );

  test('stale OCR signature wipes anchors but keeps roster and voices', () {
    final MangaAudioScript script = MangaAudioScript(
      engineSignature: 'old',
      roster: <String, TtsCastCharacter>{
        '宮城': const TtsCastCharacter(name: '宮城'),
      },
      lines: <MangaScriptLine>[
        MangaScriptLine(
          page: 0,
          blocks: const <int>[0],
          speaker: '宮城',
          kind: CastLineKind.spoken,
        ),
      ],
      annotatedPages: <int>{0},
    );
    script.voices.byCharacter['宮城'] = 'voice-1';
    final MangaAnnotationLedger ledger = MangaAnnotationLedger()
      ..recordFailure(
        stage: MangaAnnotateStage.page,
        page: 2,
        providerId: 'a',
        model: 'm',
        code: 'network',
      );
    expect(resetStaleMangaScript(script, ledger, 'new'), isTrue);
    expect(script.lines, isEmpty);
    expect(script.annotatedPages, isEmpty);
    expect(script.engineSignature, 'new');
    expect(script.roster.keys, <String>['宮城']);
    expect(script.voices.byCharacter['宮城'], 'voice-1');
    expect(ledger.isEmpty, isTrue);
    expect(resetStaleMangaScript(script, ledger, 'new'), isFalse);
  });
}

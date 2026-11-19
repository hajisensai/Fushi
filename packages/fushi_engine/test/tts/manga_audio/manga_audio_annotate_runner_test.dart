import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_ledger.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_prompt_roster.dart';
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
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
  Set<int> unreadableImages = const <int>{},
  List<String>? log,
}) => MangaAnnotateRunner(
  payload: payload ?? _payload(),
  script: script ?? MangaAudioScript(),
  ledger: ledger ?? MangaAnnotationLedger(),
  seriesRoster: series,
  substitutions: substitutions,
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
  test('三遍角色字段和上下文人名替换，旧角色声音和档案身份保留', () async {
    const TtsCastCharacter character = TtsCastCharacter(
      name: '旧名',
      aliases: <String>['旧名さん'],
      description: '旧名の旧服',
    );
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution(source: '旧名', replacement: '新名'),
      CastTextSubstitution(source: '旧服', replacement: '制服'),
    ];
    final MangaAudioScript script = MangaAudioScript();
    script.voices.byCharacter['旧名'] = 'voice-old';
    final _FakeAi ai = _FakeAi(
      roster: '{"characters":[{"name":"新名","aliases":["新名さん"]}]}',
      pageReplies: <int, Object>{
        0: _pageReply(<Map<String, Object?>>[
          <String, Object?>{
            'b': <int>[0],
            's': '新名',
            'k': 'spoken',
          },
        ]),
        1: _pageReply(<Map<String, Object?>>[
          <String, Object?>{
            'b': <int>[0],
            's': '新名さん',
            'k': 'spoken',
          },
        ]),
      },
      review: '{"edits":[{"id":"p1b0","s":"新名"}]}',
    );
    final MangaAnnotateRunner runner = _runner(
      ai,
      script: script,
      series: <String, TtsCastCharacter>{'旧名': character},
      substitutions: table,
    );
    await runner.run(pages: <int>[0, 1]);
    for (final List<AiChatMessage> call in ai.calls) {
      expect(call.last.content, isNot(contains('旧名')));
      expect(call.last.content, isNot(contains('旧服')));
      expect(call.last.content, contains('新名さん'));
      expect(call.last.content, contains('新名の制服'));
    }
    expect(
      script.lines.map((MangaScriptLine l) => l.speaker),
      everyElement('旧名'),
    );
    expect(script.lines.map(script.voiceFor), everyElement('voice-old'));
    expect(script.roster.keys, <String>['旧名']);
    expect(script.roster['旧名']!.aliases, <String>['旧名さん']);
    expect(script.roster['旧名']!.description, '旧名の旧服');
    expect(character.name, '旧名');
  });

  test('名字替换碰撞时逐页与复核用临时ID恢复各自声音', () async {
    const Map<String, TtsCastCharacter> series = <String, TtsCastCharacter>{
      '甲': TtsCastCharacter(name: '甲'),
      '乙': TtsCastCharacter(name: '乙'),
    };
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution(source: '甲', replacement: '同名'),
      CastTextSubstitution(source: '乙', replacement: '同名'),
    ];
    final CastPromptRoster view = CastPromptRoster(
      roster: series.values,
      substitutions: table,
    );
    final MangaAudioScript script = MangaAudioScript();
    script.voices.byCharacter.addAll(<String, String>{'甲': 'a', '乙': 'b'});
    final _FakeAi ai = _FakeAi(
      roster: '{"characters":[]}',
      pageReplies: <int, Object>{
        1: _pageReply(<Map<String, Object?>>[
          <String, Object?>{
            'b': <int>[0],
            's': view.speakerFor('甲'),
            'k': 'spoken',
          },
          <String, Object?>{
            'b': <int>[1],
            's': view.speakerFor('乙'),
            'k': 'spoken',
          },
        ]),
      },
      review:
          '{"edits":[{"id":"p1b0","s":"${view.speakerFor('甲')}"},{"id":"p1b1","s":"${view.speakerFor('乙')}"}]}',
    );
    final MangaAnnotateRunner runner = _runner(
      ai,
      script: script,
      series: series,
      substitutions: table,
    );
    await runner.run(pages: <int>[1], withRoster: false);
    expect(script.lines.map((MangaScriptLine l) => l.speaker), <String>[
      '甲',
      '乙',
    ]);
    expect(script.lines.map(script.voiceFor), <String>['a', 'b']);
    expect(script.roster.keys, <String>['甲', '乙']);
    for (final List<AiChatMessage> call in ai.calls) {
      expect(call.last.content, isNot(contains('甲')));
      expect(call.last.content, isNot(contains('乙')));
      expect(call.last.content, contains(view.speakerFor('甲')));
      expect(call.last.content, contains(view.speakerFor('乙')));
    }
  });

  test('三遍请求的 OCR、前页与复核过表一次，手填念法保留', () async {
    const List<CastTextSubstitution> table = <CastTextSubstitution>[
      CastTextSubstitution(source: 'セーラー服', replacement: '制服'),
      CastTextSubstitution(source: '服', replacement: 'ふく'),
    ];
    final MokuroPayload payload = MokuroPayload(
      images: <MokuroImage>[
        for (int i = 0; i < 2; i++)
          MokuroImage(
            url: 'p$i.jpg',
            size: const MokuroSize(100, 100),
            blocks: <MokuroBlock>[
              MokuroBlock(
                rectangle: const MokuroRect.fromLTRB(0, 0, 10, 10),
                isVertical: true,
                fontSize: 12,
                zIndex: 0,
                lines: <String>['セーラー', '服の子'],
              ),
            ],
          ),
      ],
    );
    final MangaScriptLine manual = MangaScriptLine(
      page: 0,
      blocks: <int>[0],
      speaker: kTtsNarrator,
      kind: CastLineKind.narration,
      source: TtsCastSource.user,
      say: 'セーラー服の手填念法',
    );
    final MangaAudioScript script = MangaAudioScript(
      lines: <MangaScriptLine>[manual],
    );
    final String reply = _pageReply(<Map<String, Object?>>[
      <String, Object?>{
        'b': <int>[0],
        's': 'NARRATOR',
        'k': 'narration',
      },
    ]);
    final _FakeAi ai = _FakeAi(
      roster: '{"characters":[]}',
      pageReplies: <int, Object>{0: reply, 1: reply},
    );
    final MangaAnnotateRunner runner = _runner(
      ai,
      payload: payload,
      script: script,
      substitutions: table,
    );
    await runner.run(pages: <int>[0, 1]);
    expect(ai.calls.length, greaterThanOrEqualTo(4));
    for (final List<AiChatMessage> call in ai.calls) {
      final String prompt = call.last.content;
      expect(prompt, isNot(contains('セーラー服の子')));
      expect(prompt, isNot(contains('制ふく')));
      expect(prompt, contains('制服の子'));
    }
    final String pagePrompt = ai.calls
        .firstWhere(
          (List<AiChatMessage> c) => c.last.content.startsWith('[page 2 of'),
        )
        .last
        .content;
    expect(pagePrompt, contains('セーラー服の手填念法'));
    final String review = ai.calls.last.last.content;
    expect(review, contains('セーラー服の手填念法'));
    expect(payload.images[0].blocks.single.lines.join(), 'セーラー服の子');
    expect(script.lines.first.say, manual.say);
  });
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

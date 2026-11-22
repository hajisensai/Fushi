import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_series_run.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_unvoiced_backfill.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:test/test.dart';

/// 小说有声书挂系列：声音写入层、改名、角色表学回；未配音补回的计划。

TtsPlanSentence _s(int section, int start, String text) => TtsPlanSentence(
  section: section,
  href: 'c$section.xhtml',
  text: text,
  spokenText: '$text。',
  matchStart: start,
  matchEnd: start + text.length,
  studyStart: start,
  studyEnd: start + text.length,
);

TtsCastLine _line(String speaker, {String? voice, String? say}) => TtsCastLine(
  speaker: speaker,
  source: TtsCastSource.user,
  voice: voice,
  say: say,
);

void main() {
  group('ttsPlanWithSubstitutions', () {
    test('显示文字与念法都过表；行键不变；空表原样返回', () {
      final TtsBookPlan plan = TtsBookPlan(<TtsPlanSentence>[
        _s(0, 0, 'セーラー服の子'),
        TtsPlanSentence(
          section: 0,
          href: 'c0.xhtml',
          text: '服を着た',
          spokenText: '服を着た',
          matchStart: 10,
          matchEnd: 14,
          studyStart: 10,
          studyEnd: 14,
          endsParagraph: true,
        ),
      ]);
      expect(
        identical(
          ttsPlanWithSubstitutions(plan, const <CastTextSubstitution>[]),
          plan,
        ),
        isTrue,
      );
      final TtsBookPlan out =
          ttsPlanWithSubstitutions(plan, const <CastTextSubstitution>[
            CastTextSubstitution(source: 'セーラー服', replacement: '制服'),
            CastTextSubstitution(source: '服', replacement: 'ふく'),
            CastTextSubstitution(source: '子', replacement: 'こ', enabled: false),
          ]);
      // 长的优先，一次扫描不重复替换；停用的不生效。
      expect(out.sentences[0].text, '制服の子');
      expect(out.sentences[0].spokenText, '制服の子。');
      expect(out.sentences[1].text, 'ふくを着た');
      expect(out.sentences[1].spokenText, 'ふくを着た');
      expect(out.sentences[1].matchStart, 10);
      expect(out.sentences[1].endsParagraph, isTrue);
    });

    test('人名读法只改念法，显示文字（cue / 制卡）不变（TW9ete_FHX）', () {
      final TtsBookPlan out = ttsPlanWithSubstitutions(
        TtsBookPlan(<TtsPlanSentence>[_s(0, 0, '祥子ちゃん、祥ちゃん')]),
        const <CastTextSubstitution>[
          CastTextSubstitution.name(written: '祥子', reading: 'さきこ'),
          CastTextSubstitution.name(written: '祥', reading: 'さき'),
        ],
      );
      expect(out.sentences.single.text, '祥子ちゃん、祥ちゃん');
      expect(out.sentences.single.spokenText, 'さきこちゃん、さきちゃん。');
    });
  });

  group('setTtsCastVoice', () {
    test('series scope writes the profile and clears the book override', () {
      final TtsCast cast = TtsCast(voices: <String, String>{'アリス': 'book'});
      final SeriesCastProfile series = SeriesCastProfile(seriesKey: 's');
      final bool changed = setTtsCastVoice(
        cast: cast,
        series: series,
        speaker: 'アリス',
        presetId: 'v-series',
        scope: TtsVoiceScope.series,
      );
      expect(changed, isTrue);
      expect(series.voices.byCharacter['アリス'], 'v-series');
      expect(cast.voices.containsKey('アリス'), isFalse);
      expect(cast.voiceOf('アリス'), 'v-series');
      expect(cast.voiceInherited('アリス'), isTrue);
    });

    test('narrator goes to the series narration slot', () {
      final TtsCast cast = TtsCast();
      final SeriesCastProfile series = SeriesCastProfile(seriesKey: 's');
      setTtsCastVoice(
        cast: cast,
        series: series,
        speaker: kTtsNarrator,
        presetId: 'vn',
        scope: TtsVoiceScope.series,
      );
      expect(series.voices.narrationVoice, 'vn');
      expect(cast.voiceOf(kTtsNarrator), 'vn');
    });

    test('book scope (or no series) only touches the book', () {
      final TtsCast cast = TtsCast();
      final SeriesCastProfile series = SeriesCastProfile(
        seriesKey: 's',
        voices: CastVoiceAssignment(
          byCharacter: <String, String>{'ボブ': 'v-series'},
        ),
      );
      cast.series = series.voices;
      expect(
        setTtsCastVoice(
          cast: cast,
          series: series,
          speaker: 'ボブ',
          presetId: 'v-book',
          scope: TtsVoiceScope.book,
        ),
        isFalse,
      );
      expect(series.voices.byCharacter['ボブ'], 'v-series');
      expect(cast.voiceOf('ボブ'), 'v-book');
      expect(cast.voiceInherited('ボブ'), isFalse);
      // 清掉本书这一层：回落到系列。
      setTtsCastVoice(
        cast: cast,
        series: series,
        speaker: 'ボブ',
        presetId: null,
        scope: TtsVoiceScope.book,
      );
      expect(cast.voiceOf('ボブ'), 'v-series');

      final TtsCast solo = TtsCast();
      setTtsCastVoice(
        cast: solo,
        series: null,
        speaker: 'ボブ',
        presetId: 'v',
        scope: TtsVoiceScope.series,
      );
      expect(solo.voices['ボブ'], 'v');
    });
  });

  test('rename applies to the book and the series', () {
    final TtsCast cast = TtsCast(
      lines: <String, TtsCastLine>{'0:0': _line('昴')},
      roster: <String, TtsCastCharacter>{
        '昴': const TtsCastCharacter(name: '昴'),
      },
    );
    final SeriesCastProfile series = SeriesCastProfile(
      seriesKey: 's',
      roster: <String, TtsCastCharacter>{
        '昴': const TtsCastCharacter(name: '昴', gender: 'male'),
      },
      voices: CastVoiceAssignment(byCharacter: <String, String>{'昴': 'v1'}),
    );
    renameTtsCastSpeaker(cast: cast, series: series, from: '昴', to: 'スバル');
    expect(cast.lines['0:0']!.speaker, 'スバル');
    expect(series.roster.keys, <String>['スバル']);
    expect(series.roster['スバル']!.aliases, contains('昴'));
    expect(series.voices.byCharacter, <String, String>{'スバル': 'v1'});
  });

  test('roster seeds from the series and learns back new characters', () {
    final SeriesCastProfile series = SeriesCastProfile(
      seriesKey: 's',
      roster: <String, TtsCastCharacter>{
        'エミリア': const TtsCastCharacter(name: 'エミリア', gender: 'female'),
      },
    );
    final TtsCast cast = TtsCast();
    seedTtsRosterFromSeries(cast, series);
    expect(cast.roster.keys, <String>['エミリア']);
    // 本卷标注出新角色、并给老角色补了别名。
    cast.mergeRoster(<TtsCastCharacter>[
      const TtsCastCharacter(name: 'レム'),
      const TtsCastCharacter(name: 'エミリア', aliases: <String>['銀髪の少女']),
    ]);
    expect(learnTtsRosterIntoSeries(cast, series), isTrue);
    expect(series.roster.keys, unorderedEquals(<String>['エミリア', 'レム']));
    expect(series.roster['エミリア']!.aliases, <String>['銀髪の少女']);
    // 再学一次没有变化。
    expect(learnTtsRosterIntoSeries(cast, series), isFalse);
    expect(learnTtsRosterIntoSeries(cast, null), isFalse);
  });

  group('planTtsBackfill', () {
    final List<TtsPlanSentence> sentences = <TtsPlanSentence>[
      _s(1, 0, 'いち'),
      _s(1, 10, 'に'),
      _s(1, 20, 'さん'),
    ];

    CastVoicingLedger ledgerWith(Map<String, List<String?>> failedVoices) {
      final CastVoicingLedger ledger = CastVoicingLedger();
      failedVoices.forEach((String id, List<String?> voices) {
        for (final String? v in voices) {
          ledger.recordFailure(lineId: id, text: 'x', voice: v, code: 'net');
        }
      });
      return ledger;
    }

    test(
      'retry picks the first untried candidate (book first, then series)',
      () {
        final TtsCast cast = TtsCast(
          lines: <String, TtsCastLine>{'1:0': _line('アリス')},
          voices: <String, String>{'アリス': 'va'},
          retryVoices: <String>['r-book'],
        )..series = CastVoiceAssignment(retryVoices: <String>['r1', 'r2']);
        final TtsBackfillPlan plan = planTtsBackfill(
          cast: cast,
          ledger: ledgerWith(<String, List<String?>>{
            '1:0': <String?>['va', 'r-book'],
          }),
          sentences: sentences,
          requests: const <TtsBackfillRequest>[
            TtsBackfillRequest.retryNext('1:0'),
          ],
          defaultPresetId: 'd',
        );
        expect(plan.exhausted, isEmpty);
        final TtsBackfillAttempt a = plan.attempts.single;
        expect(a.presetId, 'r1');
        expect(a.voiceOverride, 'r1');
        expect(a.text, 'いち。');
        expect(a.sayOverride, isNull);
      },
    );

    test('retry with no untried candidate is reported as exhausted', () {
      final TtsCast cast = TtsCast(retryVoices: <String>['r1']);
      final TtsBackfillPlan plan = planTtsBackfill(
        cast: cast,
        ledger: ledgerWith(<String, List<String?>>{
          '1:10': <String?>['d', 'r1'],
        }),
        sentences: sentences,
        requests: const <TtsBackfillRequest>[
          TtsBackfillRequest.retryNext('1:10'),
        ],
        defaultPresetId: 'd',
      );
      expect(plan.attempts, isEmpty);
      expect(plan.exhausted, <String>['1:10']);
    });

    test('picked voice and typed text keep the other override', () {
      final TtsCast cast = TtsCast(
        lines: <String, TtsCastLine>{
          '1:0': _line('アリス', say: 'イチ'),
          '1:20': _line('アリス', voice: 'vx'),
        },
      );
      final TtsBackfillPlan plan = planTtsBackfill(
        cast: cast,
        ledger: ledgerWith(<String, List<String?>>{
          '1:0': <String?>['d'],
          '1:20': <String?>['vx'],
        }),
        sentences: sentences,
        requests: const <TtsBackfillRequest>[
          TtsBackfillRequest.voice('1:0', 'vp'),
          TtsBackfillRequest.say('1:20', '  サン  '),
        ],
        defaultPresetId: 'd',
      );
      final TtsBackfillAttempt voice = plan.attempts[0];
      expect(voice.presetId, 'vp');
      expect(voice.voiceOverride, 'vp');
      // 已经手动填写过的念法照用。
      expect(voice.text, 'イチ');
      expect(voice.sayOverride, 'イチ');
      final TtsBackfillAttempt say = plan.attempts[1];
      expect(say.presetId, 'vx');
      expect(say.voiceOverride, 'vx');
      expect(say.text, 'サン');
      expect(say.sayOverride, 'サン');
    });

    test('lines not in the ledger or no longer in the plan are ignored', () {
      final TtsBackfillPlan plan = planTtsBackfill(
        cast: TtsCast(),
        ledger: ledgerWith(<String, List<String?>>{
          '9:0': <String?>['d'],
        }),
        sentences: sentences,
        requests: const <TtsBackfillRequest>[
          TtsBackfillRequest.voice('9:0', 'v'),
          TtsBackfillRequest.voice('1:0', 'v'),
          TtsBackfillRequest.say('1:0', '   '),
        ],
        defaultPresetId: 'd',
      );
      expect(plan.attempts, isEmpty);
      expect(plan.exhausted, isEmpty);
    });
  });

  test('series run stops only on run-wide annotation failures', () {
    expect(ttsSeriesRunStopsOn('no_ai_provider'), isTrue);
    expect(ttsSeriesRunStopsOn('cancelled'), isTrue);
    expect(ttsSeriesRunStopsOn('bad_output'), isFalse);
    expect(
      TtsSeriesRunMode.both.annotates && TtsSeriesRunMode.both.renders,
      isTrue,
    );
    expect(TtsSeriesRunMode.annotate.renders, isFalse);
    expect(TtsSeriesRunMode.render.annotates, isFalse);
  });
}

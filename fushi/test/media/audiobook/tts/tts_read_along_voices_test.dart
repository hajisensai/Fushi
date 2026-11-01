import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along_voices.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 多声优朗读的声音分派与提前生成范围（纯函数）。

class _Descriptor extends TtsProviderDescriptor {
  const _Descriptor();

  @override
  String get id => 'fake';

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: false,
    needsCredential: false,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      throw UnimplementedError();
}

TtsResolvedVoice _voice(String id) => (
  preset: TtsVoicePreset(id: id, providerId: 'fake', name: id),
  descriptor: const _Descriptor(),
);

TtsPlanSentence _s(
  int section,
  int matchStart, {
  String spoken = 'あ',
  bool endsParagraph = false,
}) => TtsPlanSentence(
  section: section,
  href: 'c$section.xhtml',
  text: spoken,
  spokenText: spoken,
  matchStart: matchStart,
  matchEnd: matchStart + spoken.length,
  studyStart: matchStart,
  studyEnd: matchStart + spoken.length,
  endsParagraph: endsParagraph,
);

TtsCastLine _line(String speaker) =>
    TtsCastLine(speaker: speaker, source: TtsCastSource.user);

void main() {
  final TtsCast cast = TtsCast(
    lines: <String, TtsCastLine>{
      ttsLineKey(0, 0): _line('alice'),
      ttsLineKey(0, 10): _line('bob'),
      ttsLineKey(0, 20): _line(kTtsNarrator),
      ttsLineKey(0, 30): _line('carol'),
    },
    // carol 没配声音、bob 的声音为空串（制作台里清掉了）→ 都归默认槽。
    voices: <String, String>{'alice': 'va', 'bob': ''},
  );

  group('ttsVoiceSlotOf', () {
    test('only speakers with an assigned voice get their own slot', () {
      expect(ttsVoiceSlotOf(cast, _s(0, 0)), 'alice');
      expect(ttsVoiceSlotOf(cast, _s(0, 10)), kTtsDefaultVoiceSlot);
      expect(ttsVoiceSlotOf(cast, _s(0, 20)), kTtsDefaultVoiceSlot);
      expect(ttsVoiceSlotOf(cast, _s(0, 30)), kTtsDefaultVoiceSlot);
      // 没标注的句子 = 旁白。
      expect(ttsVoiceSlotOf(cast, _s(0, 40)), kTtsDefaultVoiceSlot);
      expect(ttsVoiceSlotOf(null, _s(0, 0)), kTtsDefaultVoiceSlot);
    });

    test('narrator with its own voice gets the narrator slot', () {
      final TtsCast withNarrator = TtsCast(
        voices: <String, String>{kTtsNarrator: 'vn'},
      );
      expect(ttsVoiceSlotOf(withNarrator, _s(0, 99)), kTtsNarrator);
    });
  });

  group('assignTtsVoices', () {
    test('default voice is index 0; voices are deduplicated by preset id', () {
      final ({List<TtsResolvedVoice> voices, List<int> voiceOf}) r =
          assignTtsVoices(
            slots: const <String>['', 'alice', 'bob', '', 'carol', 'alice'],
            defaultVoice: _voice('d'),
            slotVoices: <String, TtsResolvedVoice>{
              'alice': _voice('va'),
              // bob 与默认声音同一份预设：共用下标 0（同一个引擎实例 / 并发上限）。
              'bob': _voice('d'),
              'carol': _voice('vc'),
            },
          );
      expect(
        <String>[for (final v in r.voices) v.preset.id],
        <String>['d', 'va', 'vc'],
      );
      expect(r.voiceOf, <int>[0, 1, 0, 0, 2, 1]);
    });
  });

  group('ttsPrerenderEnd', () {
    final List<TtsPlanSentence> sentences = <TtsPlanSentence>[
      _s(0, 0),
      _s(0, 1),
      _s(1, 0),
      _s(1, 1),
      _s(1, 2),
      _s(2, 0),
      _s(3, 0),
    ];

    test('covers the rest of the current chapter plus the next one', () {
      expect(ttsPrerenderEnd(sentences, 0), 4);
      expect(ttsPrerenderEnd(sentences, 1), 4);
      expect(ttsPrerenderEnd(sentences, 3), 5);
      expect(ttsPrerenderEnd(sentences, 5), 6);
    });

    test('stops at the end of the book', () {
      expect(ttsPrerenderEnd(sentences, 6), 6);
      expect(ttsPrerenderEnd(const <TtsPlanSentence>[], 0), -1);
    });
  });

  group('mergeShortTtsSentences with voice slots', () {
    test('never merges sentences from different voice slots', () {
      final TtsBookPlan plan = TtsBookPlan(<TtsPlanSentence>[
        _s(0, 0, spoken: 'あい'),
        _s(0, 10, spoken: 'うえ'),
        _s(0, 20, spoken: 'おか'),
        _s(0, 30, spoken: 'きく'),
      ]);
      final TtsBookPlan merged = mergeShortTtsSentences(
        plan,
        maxLength: 100,
        voiceSlotOf: (TtsPlanSentence s) => ttsVoiceSlotOf(cast, s),
      );
      // alice | 默认槽（bob 无声音 + 旁白 + carol 无声音，三句并成一句）。
      expect(
        <String>[for (final s in merged.sentences) s.spokenText],
        <String>['あい', 'うえおかきく'],
      );
      // 不传槽时照旧全部并在一起。
      expect(mergeShortTtsSentences(plan, maxLength: 100).length, 1);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue mkCue(int idx, {String frag = ''}) {
  return AudioCue()
    ..bookKey = 'test'
    ..chapterHref = 'srt://default'
    ..sentenceIndex = idx
    ..textFragmentId = frag.isEmpty ? 'srt://$idx' : frag
    ..text = 'cue $idx'
    ..startMs = idx * 1000
    ..endMs = idx * 1000 + 900
    ..audioFileIndex = 0;
}

void main() {
  group('SasayakiMatchCodec.encode/tryDecode', () {
    test('编码后解码回相同值', () {
      final String raw = SasayakiMatchCodec.encodeHit(
        sectionIndex: 2,
        normCharStart: 15,
        normCharEnd: 42,
      );
      expect(raw, 'sasayaki://s=2&ns=15&ne=42');

      final SasayakiFragment? f = SasayakiMatchCodec.tryDecode(raw);
      expect(f, isNotNull);
      expect(f!.sectionIndex, 2);
      expect(f.normCharStart, 15);
      expect(f.normCharEnd, 42);
    });

    test('srt:// 前缀不被识别为 sasayaki', () {
      expect(SasayakiMatchCodec.tryDecode('srt://5'), isNull);
    });

    test('参数缺失返回 null', () {
      expect(SasayakiMatchCodec.tryDecode('sasayaki://s=1'), isNull);
      expect(SasayakiMatchCodec.tryDecode('sasayaki://s=1&ns=2'), isNull);
    });

    test('参数乱序仍能解码', () {
      final SasayakiFragment? f =
          SasayakiMatchCodec.tryDecode('sasayaki://ne=9&s=0&ns=4');
      expect(f, isNotNull);
      expect(f!.sectionIndex, 0);
      expect(f.normCharStart, 4);
      expect(f.normCharEnd, 9);
    });
  });

  group('SasayakiMatchCodec.applyToCues', () {
    const MatchResult fixture = MatchResult(
      matches: <CueMatch>[
        CueMatch(
          cueSentenceIndex: 0,
          sectionIndex: 0,
          normCharStart: 0,
          normCharEnd: 8,
          score: 0.95,
        ),
        CueMatch.unmatched,
        CueMatch(
          cueSentenceIndex: 2,
          sectionIndex: 1,
          normCharStart: 20,
          normCharEnd: 35,
          score: 0.80,
        ),
      ],
      totalCues: 3,
      matchedCues: 2,
    );

    test('默认清除未命中 cue 的 textFragmentId，避免死 fallback 选择器', () {
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0),
        mkCue(1, frag: '[data-cue-id="1"]'),
        mkCue(2),
      ];

      final int applied =
          SasayakiMatchCodec.applyToCues(cues: cues, result: fixture);

      expect(applied, 2);
      expect(cues[0].textFragmentId, 'sasayaki://s=0&ns=0&ne=8');
      expect(cues[1].textFragmentId, '');
      expect(cues[2].textFragmentId, 'sasayaki://s=1&ns=20&ne=35');
    });

    test('clearUnmatched=false 时未命中保留原值（字幕合成书路径）', () {
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0),
        mkCue(1, frag: 'srt://1'),
        mkCue(2),
      ];

      final int applied = SasayakiMatchCodec.applyToCues(
        cues: cues,
        result: fixture,
        clearUnmatched: false,
      );

      expect(applied, 2);
      expect(cues[0].textFragmentId, 'sasayaki://s=0&ns=0&ne=8');
      expect(cues[1].textFragmentId, 'srt://1');
      expect(cues[2].textFragmentId, 'sasayaki://s=1&ns=20&ne=35');
    });

    test('长度不一致抛 ArgumentError', () {
      final List<AudioCue> cues = <AudioCue>[mkCue(0)];
      const MatchResult result = MatchResult(
        matches: <CueMatch>[],
        totalCues: 0,
        matchedCues: 0,
      );
      expect(
        () => SasayakiMatchCodec.applyToCues(cues: cues, result: result),
        throwsArgumentError,
      );
    });
  });

  group('SasayakiMatchCodec.computeMatchRate', () {
    test('全 sasayaki fragment → 1.0', () {
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, frag: 'sasayaki://s=0&ns=0&ne=5'),
        mkCue(1, frag: 'sasayaki://s=0&ns=5&ne=10'),
      ];
      expect(SasayakiMatchCodec.computeMatchRate(cues), 1.0);
    });

    test('混合 → 正确比例', () {
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, frag: 'sasayaki://s=0&ns=0&ne=5'),
        mkCue(1, frag: 'srt://1'),
        mkCue(2, frag: 'sasayaki://s=0&ns=10&ne=15'),
        mkCue(3, frag: 'srt://3'),
      ];
      expect(SasayakiMatchCodec.computeMatchRate(cues), 0.5);
    });

    test('空 list → 0', () {
      expect(SasayakiMatchCodec.computeMatchRate(<AudioCue>[]), 0.0);
    });
  });
}

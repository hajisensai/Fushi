import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/lyrics_position_jump.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int index, {int section = 0, int? ns, int? ne, String? raw}) =>
    AudioCue()
      ..bookKey = 'book'
      ..chapterHref = 'ch.xhtml'
      ..sentenceIndex = index
      ..textFragmentId =
          raw ??
          SubtitleRematchCodec.encodeHit(
            sectionIndex: section,
            normCharStart: ns!,
            normCharEnd: ne!,
          )
      ..text = 's$index'
      ..startMs = index * 1000
      ..endMs = index * 1000 + 900
      ..audioFileIndex = 0;

/// 学习单位比 matchable 坐标「拉长一倍」：模拟章内大量标点 / 空白 / ruby 让两套坐标
/// 逐渐偏离（越往后差得越多）。
({int offset, int length})? _doubled(SubtitleRematchFragment f) => (
  offset: f.normCharStart * 2,
  length: (f.normCharEnd - f.normCharStart) * 2,
);

void main() {
  // matchable：A [0,10) · B [10,20) · C [20,30)
  // study   ：A [0,20) · B [20,40) · C [40,60)
  final List<AudioCue> cues = <AudioCue>[
    _cue(0, ns: 0, ne: 10),
    _cue(1, ns: 10, ne: 20),
    _cue(2, ns: 20, ne: 30),
  ];

  AudioCue? near(int offset, {CueStudyRangeOf studyRangeOf = _doubled}) =>
      audioCueNearStudyOffset(
        cues,
        section: 0,
        studyOffset: offset,
        studyRangeOf: studyRangeOf,
      );

  test('按学习单位区间比较，不拿学习偏移直接比 matchable 坐标', () {
    // 学习偏移 25 落在 B 的学习区间 [20,40)；直接比 matchable 会错落到 C [20,30)。
    expect(near(25)?.sentenceIndex, 1);
    expect(near(45)?.sentenceIndex, 2);
    expect(near(0)?.sentenceIndex, 0);
    expect(near(19)?.sentenceIndex, 0);
  });

  test('落在两句之间取其后第一句，章尾之后取最后一句', () {
    final List<AudioCue> gapped = <AudioCue>[
      _cue(0, ns: 0, ne: 5),
      _cue(1, ns: 10, ne: 20),
    ];
    // study：[0,10) · [20,40)；15 在两句之间。
    expect(
      audioCueNearStudyOffset(
        gapped,
        section: 0,
        studyOffset: 15,
        studyRangeOf: _doubled,
      )?.sentenceIndex,
      1,
    );
    expect(near(999)?.sentenceIndex, 2);
  });

  test('换算不出学习区间的 cue 退回 matchable 区间（与 sectionCueFrom 同口径）', () {
    expect(near(25, studyRangeOf: (_) => null)?.sentenceIndex, 2);
  });

  test('只认本章的 fushi-cue:// 家族；没有可比的 cue 返回 null', () {
    final List<AudioCue> mixed = <AudioCue>[
      _cue(0, raw: '#s1'),
      _cue(1, section: 3, ns: 0, ne: 100),
    ];
    expect(
      audioCueNearStudyOffset(
        mixed,
        section: 0,
        studyOffset: 10,
        studyRangeOf: _doubled,
      ),
      isNull,
    );
  });
}

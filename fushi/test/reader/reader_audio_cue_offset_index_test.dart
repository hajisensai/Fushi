import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_audio_cue_offset_index.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 旧 `_findCueForOffset` 的原样参照：先按章过滤（= `sentenceAudioCuesForSection`），
/// 再对过滤结果顺序找第一个 `start <= offset < end`。
AudioCue? _legacyFindCueForOffset(
  List<AudioCue> chapterCues,
  int section,
  int offset,
) {
  final List<AudioCue> filtered = <AudioCue>[
    for (final AudioCue cue in chapterCues)
      if (SubtitleRematchCodec.tryDecode(cue.textFragmentId)?.sectionIndex ==
          section)
        cue,
  ];
  for (final AudioCue cue in filtered) {
    final SubtitleRematchFragment? frag = SubtitleRematchCodec.tryDecode(
      cue.textFragmentId,
    );
    if (frag == null) continue;
    if (frag.normCharStart <= offset && frag.normCharEnd > offset) return cue;
  }
  return null;
}

AudioCue _cue(int i, String fragment) => AudioCue()
  ..bookKey = 'book'
  ..chapterHref = 'c.xhtml'
  ..sentenceIndex = i
  ..textFragmentId = fragment
  ..text = 'cue $i'
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

void main() {
  test('index answers exactly like the legacy per-lookup decode scan', () {
    final math.Random random = math.Random(20261020);
    for (int round = 0; round < 40; round++) {
      final List<AudioCue> cues = <AudioCue>[];
      for (int i = 0; i < 120; i++) {
        final int kind = random.nextInt(10);
        if (kind == 0) {
          cues.add(_cue(i, '')); // unmatched cue
        } else if (kind == 1) {
          cues.add(_cue(i, '#s$i')); // SMIL / non-sasayaki id
        } else {
          final int start = random.nextInt(400);
          // Overlaps and empty spans included on purpose: order must decide.
          final int end = start + random.nextInt(25);
          cues.add(
            _cue(
              i,
              SubtitleRematchCodec.encodeHit(
                sectionIndex: random.nextInt(3),
                normCharStart: start,
                normCharEnd: end,
              ),
            ),
          );
        }
      }
      for (int section = 0; section < 3; section++) {
        final AudioCueOffsetIndex index = AudioCueOffsetIndex.build(
          cues,
          section,
        );
        for (int offset = -2; offset < 430; offset++) {
          expect(
            identical(
              index.cueAt(offset),
              _legacyFindCueForOffset(cues, section, offset),
            ),
            isTrue,
            reason: 'round $round section $section offset $offset',
          );
        }
      }
    }
  });

  test('index invalidates on a new cue list or another chapter', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue(
        0,
        SubtitleRematchCodec.encodeHit(
          sectionIndex: 1,
          normCharStart: 0,
          normCharEnd: 5,
        ),
      ),
    ];
    final AudioCueOffsetIndex index = AudioCueOffsetIndex.build(cues, 1);
    expect(index.matches(cues, 1), isTrue);
    expect(index.matches(cues, 2), isFalse);
    expect(index.matches(List<AudioCue>.of(cues), 1), isFalse);
    expect(index.cueAt(4), same(cues.first));
    expect(index.cueAt(5), isNull);
  });
}

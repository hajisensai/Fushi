// 整本书时间轴上的字幕 cue 切回各音轨的本地时间。
import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

AudioCue _cue(int index, int startMs, int endMs, {String text = 'x'}) =>
    AudioCue()
      ..bookKey = 'srtbook_1'
      ..chapterHref = 'srt://default'
      ..sentenceIndex = index
      ..textFragmentId = '#s$index'
      ..text = text
      ..startMs = startMs
      ..endMs = endMs
      ..audioFileIndex = 0;

// 三条轨：[0,1000) [1000,3000) [3000,3500)
const List<AudioTrackSpan> _tracks = <AudioTrackSpan>[
  (startOffsetMs: 0, durationMs: 1000),
  (startOffsetMs: 1000, durationMs: 2000),
  (startOffsetMs: 3000, durationMs: 500),
];

List<(int, int, int)> _placed(List<AudioCue> cues) => <(int, int, int)>[
  for (final AudioCue c in cues) (c.audioFileIndex, c.startMs, c.endMs),
];

void main() {
  test('按起点归属音轨，时间改成轨内本地时间', () {
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 100, 900),
      _cue(1, 1000, 1500),
      _cue(2, 2500, 2900),
      _cue(3, 3100, 3400),
    ], _tracks);
    expect(_placed(out), <(int, int, int)>[
      (0, 100, 900),
      (1, 0, 500),
      (1, 1500, 1900),
      (2, 100, 400),
    ]);
  });

  test('保留句序 / 文本 / 片段 id，且返回新对象、不改输入', () {
    final List<AudioCue> input = <AudioCue>[_cue(7, 1200, 1800, text: 'こんにちは')];
    final List<AudioCue> out = splitCuesAcrossTracks(input, _tracks);
    expect(out.single, isNot(same(input.single)));
    expect(out.single.sentenceIndex, 7);
    expect(out.single.text, 'こんにちは');
    expect(out.single.textFragmentId, '#s7');
    expect(out.single.bookKey, 'srtbook_1');
    expect(out.single.chapterHref, 'srt://default');
    expect(input.single.audioFileIndex, 0, reason: '输入不被改写');
    expect(input.single.startMs, 1200);
  });

  test('横跨音轨边界：归起点那条轨，终点钳到轨末', () {
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 900, 1200),
    ], _tracks);
    expect(_placed(out), <(int, int, int)>[(0, 900, 1000)]);
  });

  test('恰好在边界上起头的句子归后一条轨', () {
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 3000, 3200),
    ], _tracks);
    expect(_placed(out), <(int, int, int)>[(2, 0, 200)]);
  });

  test('字幕比音频长：句子保留，钳在最后一条轨的末尾', () {
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 9000, 9500),
    ], _tracks);
    expect(_placed(out), <(int, int, int)>[(2, 500, 500)]);
  });

  test('起点落在两条轨之间的空隙里：归前一条轨，钳到轨末', () {
    const List<AudioTrackSpan> gappy = <AudioTrackSpan>[
      (startOffsetMs: 0, durationMs: 1000),
      (startOffsetMs: 1500, durationMs: 1000),
    ];
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 1200, 1400),
    ], gappy);
    expect(_placed(out), <(int, int, int)>[(0, 1000, 1000)]);
  });

  test('零长度轨与后一条轨同起点：句子归有内容的那条', () {
    const List<AudioTrackSpan> withEmpty = <AudioTrackSpan>[
      (startOffsetMs: 0, durationMs: 1000),
      (startOffsetMs: 1000, durationMs: 0),
      (startOffsetMs: 1000, durationMs: 1000),
    ];
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 1100, 1500),
    ], withEmpty);
    expect(_placed(out), <(int, int, int)>[(2, 100, 500)]);
  });

  test('终点早于起点的畸形 cue 不产生负时长', () {
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      _cue(0, 1500, 1400),
    ], _tracks);
    expect(out.single.endMs, greaterThanOrEqualTo(out.single.startMs));
  });

  test('只有一条轨或没有轨：原样返回同一份列表', () {
    final List<AudioCue> input = <AudioCue>[_cue(0, 100, 200)];
    expect(splitCuesAcrossTracks(input, const <AudioTrackSpan>[]), same(input));
    expect(
      splitCuesAcrossTracks(input, const <AudioTrackSpan>[
        (startOffsetMs: 0, durationMs: 5000),
      ]),
      same(input),
    );
  });

  test('空 cue 表 → 空表', () {
    expect(splitCuesAcrossTracks(<AudioCue>[], _tracks), isEmpty);
  });

  test('切完之后各文件时长由 cue 推出的口径仍成立（每个文件内 cue 不越过轨长）', () {
    final List<AudioCue> out = splitCuesAcrossTracks(<AudioCue>[
      for (int i = 0; i < 35; i++) _cue(i, i * 100, i * 100 + 90),
    ], _tracks);
    final List<int> durations = audiobookFileDurationsFromCues(out);
    expect(durations, hasLength(3));
    for (int i = 0; i < durations.length; i++) {
      expect(durations[i], lessThanOrEqualTo(_tracks[i].durationMs));
    }
  });

  test('RemoteAudioBinding.spans 与音轨表一一对应', () {
    final RemoteAudioBinding binding = RemoteAudioBinding(
      srtBookUid: 'u',
      provider: RemoteAudioBinding.providerAudiobookshelf,
      serverConfigId: 's',
      itemId: 'i',
      tracks: const <RemoteAudioTrack>[
        RemoteAudioTrack(ino: '1', startOffsetMs: 0, durationMs: 10),
        RemoteAudioTrack(ino: '2', startOffsetMs: 10, durationMs: 20),
      ],
      createdAt: 0,
      updatedAt: 0,
    );
    expect(binding.spans, <AudioTrackSpan>[
      (startOffsetMs: 0, durationMs: 10),
      (startOffsetMs: 10, durationMs: 20),
    ]);
  });
}

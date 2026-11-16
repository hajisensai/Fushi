import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_burned_in_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_fusion.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence_loader.dart';
import 'package:path/path.dart' as p;

/// 画面下方居中的一行字幕。
SubtitleFrameTextLine _sub(String text, {double top = 0.85}) =>
    SubtitleFrameTextLine(
      text: text,
      left: 0.3,
      top: top,
      right: 0.7,
      bottom: top + 0.06,
    );

/// 假识别器：按帧字节的第一个字节（= 取帧时刻 / 1000）查表回字幕行。
class _FakeReader implements SubtitleFrameTextReader {
  _FakeReader(this.byFrame, {this.id = 'model-a'});

  final Map<int, List<SubtitleFrameTextLine>> byFrame;
  final String? id;
  int reads = 0;

  @override
  Future<String?> identity() async => id;

  @override
  Future<List<SubtitleFrameTextLine>> read(Uint8List frame) async {
    reads++;
    return byFrame[frame.first] ?? const <SubtitleFrameTextLine>[];
  }
}

/// 假取帧：帧字节 = [atMs ~/ 1000]。
Future<Uint8List?> _frames(String videoPath, int atMs) async =>
    Uint8List.fromList(<int>[atMs ~/ 1000]);

/// 第 i 行在 [i*4000+1000, i*4000+3000]，中点 = (i*4 + 2) 秒。
List<SubtitleDraftCue> _drafts(List<String> texts) => <SubtitleDraftCue>[
  for (int i = 0; i < texts.length; i++)
    SubtitleDraftCue(
      startMs: i * 4000 + 1000,
      endMs: i * 4000 + 3000,
      text: texts[i],
    ),
];

int _second(int index) => index * 4 + 2;

const List<String> _asr = <String>[
  '島に行こう',
  '今日はいい天気だね',
  'お茶にしようか',
  'そうだね本当に',
  '先生が来たよ',
];

void main() {
  test('字幕行挑选：只要画面下方居中的行，上方 / 角落的不要，多行从上到下拼', () {
    expect(
      burnedInSubtitleText(<SubtitleFrameTextLine>[
        _sub('二行目だよ', top: 0.9),
        _sub('一行目と', top: 0.8),
        // 画面上方的招牌。
        _sub('喫茶店', top: 0.1),
        // 右下角台标。
        const SubtitleFrameTextLine(
          text: 'TOKYO MX',
          left: 0.85,
          top: 0.9,
          right: 0.98,
          bottom: 0.95,
        ),
      ]),
      '一行目と二行目だよ',
    );
    expect(burnedInSubtitleText(const <SubtitleFrameTextLine>[]), '');
  });

  test('探测抽样：有字的行里均匀取，首尾都在', () {
    final List<SubtitleDraftCue> d = _drafts(<String>[
      for (int i = 0; i < 30; i++) i == 3 ? '' : 'line$i',
    ]);
    final List<int> plan = planBurnedInProbe(d, count: 5);
    expect(plan.length, 5);
    expect(plan.first, 0);
    expect(plan.last, 29);
    expect(plan, isNot(contains(3)));
    expect(planBurnedInProbe(_drafts(<String>['a', '', 'b'])), <int>[0, 2]);
  });

  test('探测判定：日文硬字幕对得上才收；中文压制字幕 / 没字幕 / 对不上都不收', () {
    expect(
      burnedInProbeAccepts(<(String, String)>[
        ('堂に行こう', '島に行こう'),
        ('今日はいい天気だね', '今日はいい天気だね'),
        ('お茶にしようか', 'お茶にしようか'),
        ('', 'そうだね本当に'),
      ], targetLanguage: 'ja'),
      isTrue,
    );
    expect(
      burnedInProbeAccepts(<(String, String)>[
        ('今天天气很好呢', '今日はいい天気だね'),
        ('我们去喝茶吧', 'お茶にしようか'),
        ('老师来了', '先生が来たよ'),
      ], targetLanguage: 'ja'),
      isFalse,
    );
    expect(
      burnedInProbeAccepts(<(String, String)>[
        ('', '島に行こう'),
        ('', '今日はいい天気だね'),
        ('', 'お茶にしようか'),
      ], targetLanguage: 'ja'),
      isFalse,
    );
    expect(
      burnedInProbeAccepts(<(String, String)>[
        ('まったく違う文章です', '島に行こう'),
        ('別のセリフが出ている', '今日はいい天気だね'),
        ('全然関係ない字幕', 'お茶にしようか'),
      ], targetLanguage: 'ja'),
      isFalse,
    );
  });

  test('读硬字幕：探测通过后整集逐行读，证据行与识别行同时间轴', () async {
    final _FakeReader reader = _FakeReader(<int, List<SubtitleFrameTextLine>>{
      _second(0): <SubtitleFrameTextLine>[_sub('堂に行こう')],
      _second(1): <SubtitleFrameTextLine>[_sub('今日はいい天気だね')],
      _second(2): <SubtitleFrameTextLine>[_sub('お茶にしようか')],
      _second(3): <SubtitleFrameTextLine>[_sub('そうだね本当に')],
      _second(4): const <SubtitleFrameTextLine>[],
    });
    final List<(int, int)> progress = <(int, int)>[];
    final SubtitleEvidenceTrack? track =
        await SubtitleBurnedInReader(frames: _frames, reader: reader).read(
          videoPath: 'ep01.mkv',
          drafts: _drafts(_asr),
          targetLanguage: 'ja',
          onProgress: (int done, int total) => progress.add((done, total)),
        );
    expect(track, isNotNull);
    expect(track!.kind, SubtitleEvidenceKind.ocr);
    expect(track.language, 'ja');
    expect(track.label, kSubtitleBurnedInTrackLabel);
    expect(
      track.cues.map((SubtitleEvidenceCue c) => (c.startMs, c.endMs, c.text)),
      <(int, int, String)>[
        (1000, 3000, '堂に行こう'),
        (5000, 7000, '今日はいい天気だね'),
        (9000, 11000, 'お茶にしようか'),
        (13000, 15000, 'そうだね本当に'),
      ],
    );
    // 5 行全在探测样本里：每帧只读一次。
    expect(reader.reads, 5);
    expect(progress.last, (5, 5));
  });

  test('没有硬字幕：探测不过就停，只花探测那几帧', () async {
    final _FakeReader reader = _FakeReader(
      const <int, List<SubtitleFrameTextLine>>{},
    );
    final SubtitleEvidenceTrack? track =
        await SubtitleBurnedInReader(frames: _frames, reader: reader).read(
          videoPath: 'ep01.mkv',
          drafts: _drafts(<String>[for (int i = 0; i < 60; i++) 'せりふ$i']),
          targetLanguage: 'ja',
        );
    expect(track, isNull);
    expect(reader.reads, kSubtitleBurnedInProbeFrames);
  });

  test('识别器不可用（模型没下载）：不取帧、不读', () async {
    int frameCalls = 0;
    final _FakeReader reader = _FakeReader(
      const <int, List<SubtitleFrameTextLine>>{},
      id: null,
    );
    final SubtitleEvidenceTrack? track = await SubtitleBurnedInReader(
      frames: (String v, int at) async {
        frameCalls++;
        return Uint8List(1);
      },
      reader: reader,
    ).read(videoPath: 'ep01.mkv', drafts: _drafts(_asr), targetLanguage: 'ja');
    expect(track, isNull);
    expect(frameCalls, 0);
    expect(reader.reads, 0);
  });

  test('收集器：硬字幕识别器身份进缓存键；本机视频读出硬字幕轨', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('burned_in_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final String video = p.join(tmp.path, 'ep01.mkv');
    File(video).writeAsBytesSync(List<int>.filled(16, 1));
    final _FakeReader reader = _FakeReader(<int, List<SubtitleFrameTextLine>>{
      for (int i = 0; i < _asr.length; i++)
        _second(i): <SubtitleFrameTextLine>[_sub(_asr[i])],
    });
    bool own(String path) => false;

    final String plain = await const SubtitleEvidenceCollector().sourceKey(
      video,
      isOwnOutput: own,
    );
    final SubtitleEvidenceCollector collector = SubtitleEvidenceCollector(
      burnedIn: SubtitleBurnedInReader(frames: _frames, reader: reader),
    );
    final String withOcr = await collector.sourceKey(video, isOwnOutput: own);
    expect(withOcr, isNot(plain));
    expect(withOcr, contains('burned-in:model-a'));

    final List<SubtitleEvidenceTrack> tracks = await collector.load(
      SubtitleEvidenceLoadRequest(
        videoPath: video,
        drafts: _drafts(_asr),
        isOwnOutput: own,
        targetLanguage: 'ja',
      ),
    );
    expect(
      tracks.map((SubtitleEvidenceTrack t) => t.label),
      contains(kSubtitleBurnedInTrackLabel),
    );
  });

  group('OCR 证据确定性纠错', () {
    SubtitleEvidenceIndex index(
      List<SubtitleEvidenceCue> cues, {
      SubtitleEvidenceKind kind = SubtitleEvidenceKind.ocr,
    }) => SubtitleEvidenceIndex(<SubtitleEvidenceTrack>[
      SubtitleEvidenceTrack(
        label: 'burned-in',
        kind: kind,
        language: 'ja',
        cues: cues,
      ),
    ], targetLanguage: 'ja');

    test('同音字错误换成画面写法，词级时间与候选一并丢掉；别的句子不换', () {
      final List<SubtitleDraftCue> drafts = <SubtitleDraftCue>[
        const SubtitleDraftCue(
          startMs: 1000,
          endMs: 3000,
          text: '島に行こう',
          speaker: 'A',
          alternatives: <String>['島に行こう？'],
        ),
        const SubtitleDraftCue(startMs: 5000, endMs: 7000, text: 'ありがとう'),
      ];
      final List<SubtitleDraftCue> out = correctSubtitleDraftsFromOcrEvidence(
        drafts,
        index(const <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '堂に行こう'),
          SubtitleEvidenceCue(startMs: 5000, endMs: 7000, text: 'さようなら'),
        ]),
      );
      expect(out[0].text, '堂に行こう');
      expect(out[0].speaker, 'A');
      expect(out[0].alternatives, isEmpty);
      expect(out[0].tokenTiming, isNull);
      expect(out[1].text, 'ありがとう');
    });

    test('人工文字字幕不走确定性替换；补齐插入的行不动；一行压两句的不换', () {
      const List<SubtitleDraftCue> drafts = <SubtitleDraftCue>[
        SubtitleDraftCue(startMs: 1000, endMs: 3000, text: '島に行こう'),
        SubtitleDraftCue(
          startMs: 4000,
          endMs: 5000,
          text: '先生待って',
          origin: 'ep01.ja.srt',
        ),
        SubtitleDraftCue(startMs: 6000, endMs: 7000, text: 'お茶に'),
        SubtitleDraftCue(startMs: 7000, endMs: 8000, text: 'しようか'),
      ];
      expect(
        correctSubtitleDraftsFromOcrEvidence(
          drafts,
          index(const <SubtitleEvidenceCue>[
            SubtitleEvidenceCue(startMs: 1000, endMs: 3000, text: '堂に行こう'),
          ], kind: SubtitleEvidenceKind.text),
        ).first.text,
        '島に行こう',
      );
      final List<SubtitleDraftCue> out = correctSubtitleDraftsFromOcrEvidence(
        drafts,
        index(const <SubtitleEvidenceCue>[
          SubtitleEvidenceCue(startMs: 4000, endMs: 5000, text: '先生、待て'),
          SubtitleEvidenceCue(startMs: 6000, endMs: 8000, text: 'お茶にしようか'),
        ]),
      );
      expect(out[1].text, '先生待って');
      expect(out[2].text, 'お茶に');
      expect(out[3].text, 'しようか');
    });
  });
}

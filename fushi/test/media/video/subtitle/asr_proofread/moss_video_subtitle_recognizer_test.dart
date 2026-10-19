import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_asr_subtitles/asr_subtitles.dart' show SubtitleCue;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/fake_asr_transcription.dart';

/// 4 秒的低电平噪声（16 kHz）：短于 MOSS 的 300 s 目标块长，整段一块。
Float32List _noise(int seconds) {
  final math.Random r = math.Random(7);
  return Float32List.fromList(<double>[
    for (int i = 0; i < seconds * asr.kAsrSampleRate; i++)
      (r.nextDouble() - 0.5) * 0.02,
  ]);
}

asr.MossCue _moss(int s, int e, String text, String speaker) =>
    asr.MossCue(startMs: s, endMs: e, text: text, speaker: speaker);

SubtitleCue _pk(int s, int e, String text) =>
    SubtitleCue(index: 1, startMs: s, endMs: e, text: text);

void main() {
  group('decodePcm16MonoWav', () {
    test('与 encodePcm16Wav 互逆（s16 → float → s16 不失真）', () {
      final Float32List samples = Float32List.fromList(<double>[
        0,
        0.5,
        -0.5,
        -1,
        32767 / 32768,
      ]);
      final Float32List back = decodePcm16MonoWav(asr.encodePcm16Wav(samples));
      expect(back, samples);
    });

    test('跳过 ffmpeg 写的 LIST 块；格式不对抛 FormatException', () {
      final Uint8List plain = asr.encodePcm16Wav(
        Float32List.fromList(<double>[0.25, -0.25]),
      );
      // 在 fmt 之后插一个 6 字节的 LIST 块。
      final BytesBuilder b = BytesBuilder()
        ..add(plain.sublist(0, 36))
        ..add(ascii.encode('LIST'))
        ..add(<int>[6, 0, 0, 0])
        ..add(ascii.encode('INFOab'))
        ..add(plain.sublist(36));
      expect(decodePcm16MonoWav(b.toBytes()), <double>[0.25, -0.25]);

      final Uint8List stereo = Uint8List.fromList(plain);
      ByteData.sublistView(stereo).setUint16(22, 2, Endian.little);
      expect(() => decodePcm16MonoWav(stereo), throwsFormatException);
      expect(
        () => decodePcm16MonoWav(Uint8List.fromList(<int>[1, 2, 3])),
        throwsFormatException,
      );
    });
  });

  group('pairParakeetCuesWithMoss', () {
    test(
      '按区间认领：主稿 = Parakeet、候选 = MOSS、说话人 = MOSS；空稿丢弃、它的 MOSS 正文挂到重叠最多的那条',
      () {
        final List<SubtitleDraftCue> out = pairParakeetCuesWithMoss(
          moss: <asr.MossCue>[
            _moss(100, 1500, 'こんにちは', '1:S01'),
            _moss(2000, 3000, '元気', '1:S02'),
            _moss(2500, 2900, 'うん', '1:S01'),
            _moss(5000, 6000, 'BGM', '1:S03'),
          ],
          parakeet: <SubtitleCue>[
            _pk(100, 1500, '今日は'),
            _pk(2000, 3000, '元気？'),
          ],
          timings: <asr.AsrCueTokenTiming>[
            asr.AsrCueTokenTiming(
              tokens: const <String>['今'],
              offsetsMs: const <int>[0],
            ),
            asr.AsrCueTokenTiming(
              tokens: const <String>['元'],
              offsetsMs: const <int>[10],
            ),
          ],
        );
        expect(out.map((SubtitleDraftCue c) => c.text), <String>['今日は', '元気？']);
        expect(out.map((SubtitleDraftCue c) => c.speaker), <String>[
          '1:S01',
          '1:S02',
        ]);
        expect(out[0].alternatives, <String>['こんにちは']);
        expect(out[1].alternatives, <String>['元気 うん']);
        expect(out[1].tokenTiming!.offsetsMs, <int>[10]);
        expect(out[1].startMs, 2000);
        expect(out[1].endMs, 3000);
      },
    );

    test('区间相同的两段按顺序认领；配不上任何 MOSS 段即报错（上游契约被破坏）', () {
      final List<SubtitleDraftCue> twins = pairParakeetCuesWithMoss(
        moss: <asr.MossCue>[
          _moss(0, 1000, 'a', '1:S01'),
          _moss(0, 1000, 'b', '1:S02'),
        ],
        parakeet: <SubtitleCue>[_pk(0, 1000, 'x'), _pk(0, 1000, 'y')],
      );
      expect(twins.map((SubtitleDraftCue c) => c.speaker), <String>[
        '1:S01',
        '1:S02',
      ]);
      expect(
        () => pairParakeetCuesWithMoss(
          moss: <asr.MossCue>[_moss(0, 1000, 'a', '1:S01')],
          parakeet: <SubtitleCue>[_pk(0, 999, 'x')],
        ),
        throwsA(isA<VideoSubtitleRecognizeFailure>()),
      );
    });
  });

  group('MossVideoSubtitleRecognizer', () {
    late Directory tmp;
    late Directory work;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('mossrec_');
      work = Directory(p.join(tmp.path, 'job'))..createSync();
      // 已抽好的音轨：识别器不再跑 ffmpeg。
      File(
        p.join(work.path, videoSubtitleAudioFileName(work)),
      ).writeAsBytesSync(asr.encodePcm16Wav(_noise(4)));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    const String raw =
        '[0.10][S01]こんにちは[1.50][2.00][S02]元気[3.00][2.50][S01]うん[2.90]';

    FakeAsrTranscriptionService service({bool hold = false}) =>
        FakeAsrTranscriptionService(
          jobDir: Directory(p.join(tmp.path, 'asr_job')),
          holdUntilPaused: hold,
          text: (asr.AsrSegmentSpan s) => switch (s.startMs) {
            100 => '今日は',
            2000 => '元気？',
            _ => null,
          },
        );

    MossVideoSubtitleRecognizer recognizer(
      FakeAsrTranscriptionService asrService,
      FakeProcessStarter starter,
    ) => MossVideoSubtitleRecognizer(
      serviceFactory: (asr.AsrAudioProfile profile) {
        asrService.profiles.add(profile);
        return asrService;
      },
      moss: asr.MossRunner(
        cliPath: 'audiocpp_cli',
        modelPath: p.join(tmp.path, 'moss.gguf'),
        // 显式钉后端与设备：不传时后端随平台清单变（Linux = vulkan），CUDA 不给
        // device 还会先跑一次 `--list-devices` 选卡——都与本组要测的管线无关。
        backend: asr.AudioCppBackend.cuda,
        device: 0,
        startProcess: starter.call,
      ),
    );

    test('MOSS 分段 → Parakeet 按分段识别 → 对回；时间轴落盘，续跑不再起 MOSS', () async {
      final FakeProcessStarter starter = FakeProcessStarter(
        fakeAudioCppCli(raw),
      );
      final FakeAsrTranscriptionService asrService = service();
      final List<double> progress = <double>[];
      final List<String> messages = <String>[];
      final List<SubtitleDraftCue> cues = await recognizer(asrService, starter)
          .recognize(
            videoPath: p.join(tmp.path, 'ep.mkv'),
            workDir: work,
            onProgress: (double f, String m) {
              progress.add(f);
              messages.add(m);
            },
            cancel: const SubtitleNeverCancel(),
          );

      expect(starter.calls, hasLength(1));
      expect(
        starter.calls.single,
        containsAllInOrder(<String>[
          '--family',
          'moss_transcribe_diarize',
          '--backend',
          'cuda',
        ]),
      );
      expect(asrService.profiles, <asr.AsrAudioProfile>[
        asr.AsrAudioProfile.mixedAudio,
      ]);
      expect(asrService.startedWith.single, const <asr.AsrSegmentSpan>[
        asr.AsrSegmentSpan(startMs: 100, endMs: 1500),
        asr.AsrSegmentSpan(startMs: 2000, endMs: 3000),
        asr.AsrSegmentSpan(startMs: 2500, endMs: 2900),
      ]);
      expect(cues.map((SubtitleDraftCue c) => c.text), <String>['今日は', '元気？']);
      expect(cues[0].speaker, '1:S01');
      expect(cues[1].alternatives, <String>['元気 うん']);
      // tokens.jsonl 的终点（e）一路带到稿上。
      expect(cues[1].tokenTiming!.endOffsetsMs, <int>[80, 180, 280]);
      expect(progress.first, 0);
      expect(progress.reduce(math.max), lessThanOrEqualTo(1));
      // MOSS 一块跑完 = 抽音轨份额 + MOSS 份额；之后才是 Parakeet。
      expect(
        progress,
        contains(kMossProgressExtractShare + kMossProgressMossShare),
      );
      expect(messages, contains('segmenting (MOSS) 1 chunks'));
      expect(
        messages.indexOf('segmenting (MOSS) 1 chunks'),
        lessThan(messages.indexOf('transcribing')),
      );

      final File segments = File(p.join(work.path, kMossSegmentsFileName));
      expect(segments.existsSync(), isTrue);
      expect(readMossSegmentsFile(segments), hasLength(3));

      // 续跑：segments.moss.json 在，不再起 audiocpp_cli。
      final FakeProcessStarter again = FakeProcessStarter(fakeAudioCppCli(''));
      await recognizer(service(), again).recognize(
        videoPath: p.join(tmp.path, 'ep.mkv'),
        workDir: work,
        onProgress: (double f, String m) {},
        cancel: const SubtitleNeverCancel(),
      );
      expect(again.calls, isEmpty);
    });

    test('Parakeet 模型没下载：跑 MOSS 之前就报错', () async {
      final FakeProcessStarter starter = FakeProcessStarter(
        fakeAudioCppCli(raw),
      );
      await expectLater(
        recognizer(
          FakeAsrTranscriptionService(
            jobDir: Directory(p.join(tmp.path, 'asr_job')),
            text: (asr.AsrSegmentSpan s) => 'x',
            modelReady: false,
          ),
          starter,
        ).recognize(
          videoPath: p.join(tmp.path, 'ep.mkv'),
          workDir: work,
          onProgress: (double f, String m) {},
          cancel: const SubtitleNeverCancel(),
        ),
        throwsA(isA<VideoSubtitleRecognizeFailure>()),
      );
      expect(starter.calls, isEmpty);
    });

    test('MOSS 阶段取消：当场杀掉 audiocpp_cli、抛 SubtitlePipelineCancelled', () async {
      final FakeProcessStarter starter = FakeProcessStarter(
        (String exe, List<String> args, FakeProcess proc) {},
      );
      final SubtitleCancelSource cancel = SubtitleCancelSource();
      final Future<List<SubtitleDraftCue>> run = recognizer(service(), starter)
          .recognize(
            videoPath: p.join(tmp.path, 'ep.mkv'),
            workDir: work,
            onProgress: (double f, String m) {},
            cancel: cancel,
          );
      while (starter.processes.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      cancel.cancel();
      await expectLater(run, throwsA(isA<SubtitlePipelineCancelled>()));
      expect(starter.processes.single.killed, isTrue);
      expect(
        File(p.join(work.path, kMossSegmentsFileName)).existsSync(),
        isFalse,
      );
    });

    test('Parakeet 阶段取消：请求转录暂停、抛 SubtitlePipelineCancelled', () async {
      final FakeProcessStarter starter = FakeProcessStarter(
        fakeAudioCppCli(raw),
      );
      final FakeAsrTranscriptionService asrService = service(hold: true);
      final SubtitleCancelSource cancel = SubtitleCancelSource();
      final Future<List<SubtitleDraftCue>> run = recognizer(asrService, starter)
          .recognize(
            videoPath: p.join(tmp.path, 'ep.mkv'),
            workDir: work,
            onProgress: (double f, String m) {
              if (m == 'transcribing') cancel.cancel();
            },
            cancel: cancel,
          );
      await expectLater(run, throwsA(isA<SubtitlePipelineCancelled>()));
      expect(asrService.pauses, 1);
    });

    test('MOSS 一句都没有：不起 Parakeet，返回空稿', () async {
      final FakeProcessStarter starter = FakeProcessStarter(
        fakeAudioCppCli(''),
      );
      final FakeAsrTranscriptionService asrService = service();
      final List<SubtitleDraftCue> cues = await recognizer(asrService, starter)
          .recognize(
            videoPath: p.join(tmp.path, 'ep.mkv'),
            workDir: work,
            onProgress: (double f, String m) {},
            cancel: const SubtitleNeverCancel(),
          );
      expect(cues, isEmpty);
      expect(asrService.startedWith, isEmpty);
    });

    test('id 与后端无关', () {
      expect(
        recognizer(service(), FakeProcessStarter(fakeAudioCppCli(''))).id,
        kMossVideoSubtitleRecognizerId,
      );
    });
  });
}

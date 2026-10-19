import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:path/path.dart' as p;

/// ffmpeg 替身：ffprobe 报两条音轨（英 / 日），ffmpeg 往输出路径写一段假 WAV。
class _FakeFfmpeg implements FfmpegBackend {
  final List<List<String>> runs = <List<String>>[];

  @override
  Future<FfmpegRunResult> runProbe(List<String> args, Duration timeout) async =>
      FfmpegRunResult(
        returnCode: 0,
        output: jsonEncode(<String, Object?>{
          'format': <String, Object?>{'duration': '1440.0'},
          'streams': <Object?>[
            <String, Object?>{'index': 0, 'codec_type': 'video'},
            <String, Object?>{
              'index': 1,
              'codec_type': 'audio',
              'tags': <String, Object?>{'language': 'eng'},
            },
            <String, Object?>{
              'index': 2,
              'codec_type': 'audio',
              'tags': <String, Object?>{'language': 'jpn'},
            },
          ],
        }),
      );

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    runs.add(args);
    File(args.last).writeAsBytesSync(List<int>.filled(1000, 0));
    return const FfmpegRunResult(returnCode: 0, output: '');
  }

  @override
  Future<FfmpegRunResult> runQuery(List<String> args, Duration timeout) async =>
      const FfmpegRunResult(returnCode: 0, output: '');
}

void main() {
  test('多音轨挑 jpn / ja 标签那条（全局流序号），否则第一条；没有音轨为 null', () {
    expect(
      pickJapaneseAudioStream(const <AudioTrackFacts>[
        AudioTrackFacts(index: 1, language: 'eng'),
        AudioTrackFacts(index: 2, language: 'jpn'),
      ]),
      2,
    );
    expect(
      pickJapaneseAudioStream(const <AudioTrackFacts>[
        AudioTrackFacts(index: 3, language: 'eng'),
        AudioTrackFacts(index: 4, language: 'JA'),
      ]),
      4,
    );
    expect(
      pickJapaneseAudioStream(const <AudioTrackFacts>[
        AudioTrackFacts(index: 5),
        AudioTrackFacts(index: 6, language: 'eng'),
      ]),
      5,
    );
    expect(pickJapaneseAudioStream(const <AudioTrackFacts>[]), isNull);
  });

  test('抽音轨参数同基准 extract_audio（16 kHz 单声道 s16 + aresample）', () {
    expect(
      videoSubtitleAudioExtractArgs(
        videoPath: 'v.mkv',
        streamIndex: 2,
        outputPath: 'o.wav',
      ),
      <String>[
        '-y',
        '-v',
        'error',
        '-i',
        'v.mkv',
        '-map',
        '0:2',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-af',
        'aresample=async=1:first_pts=0',
        '-c:a',
        'pcm_s16le',
        '-f',
        'wav',
        'o.wav',
      ],
    );
  });

  group('extractVideoSubtitleAudio', () {
    late Directory tmp;
    late _FakeFfmpeg ffmpeg;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vsr_');
      ffmpeg = _FakeFfmpeg();
      setFfmpegBackendForTesting(ffmpeg);
    });
    tearDown(() {
      setFfmpegBackendForTesting(null);
      tmp.deleteSync(recursive: true);
    });

    test('走引擎 ffmpeg 后端、映射日语音轨；已抽过就不再跑', () async {
      final File videoFile = File(p.join(tmp.path, 'ep01.mkv'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final Directory dir = Directory(
        p.join(tmp.path, 'jobs', videoSubtitleJobId(videoFile.path)),
      );
      final File wav = await extractVideoSubtitleAudio(
        videoPath: videoFile.path,
        workDir: dir,
        cancel: const SubtitleNeverCancel(),
      );
      expect(wav.existsSync(), isTrue);
      expect(ffmpeg.runs.single, containsAllInOrder(<String>['-map', '0:2']));
      expect(File('${wav.path}.part').existsSync(), isFalse);

      await extractVideoSubtitleAudio(
        videoPath: videoFile.path,
        workDir: dir,
        cancel: const SubtitleNeverCancel(),
      );
      expect(ffmpeg.runs, hasLength(1));
    });

    test('音轨文件名因视频而异：等长的两个视频不会撞上同一个上游转录任务', () async {
      // 上游任务 id = 音频文件名 + 字节数；WAV 字节数只由时长决定。
      final Directory a = Directory(
        p.join(tmp.path, 'jobs', videoSubtitleJobId(p.join(tmp.path, 'a.mkv'))),
      );
      final Directory b = Directory(
        p.join(tmp.path, 'jobs', videoSubtitleJobId(p.join(tmp.path, 'b.mkv'))),
      );
      expect(
        videoSubtitleAudioFileName(a),
        isNot(videoSubtitleAudioFileName(b)),
      );
    });
  });
}

@Tags(<String>['realdata'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// 真跑系统 ffmpeg 的集成验证（TODO-1000）：确认「GIF 制卡」媒体链路端到端可产出真 GIF +
/// 音频 + 静图，而不只是引擎的假抽取器逻辑。无 ffmpeg（HIBIKI_FFMPEG 或 PATH 都没有）时整组
/// 跳过（CI 不带 ffmpeg 不误红）。桌面走系统 ffmpeg（`ffmpeg_backend` resolveFfmpegBackend）。
class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;
  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson, required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

String? _ffmpegExe() {
  final String? override = Platform.environment['HIBIKI_FFMPEG'];
  if (override != null && override.isNotEmpty) return override;
  try {
    final ProcessResult r = Process.runSync('ffmpeg', <String>['-version']);
    if (r.exitCode == 0) return 'ffmpeg';
  } catch (_) {}
  return null;
}

void main() {
  final String? ffmpeg = _ffmpegExe();

  group('ffmpeg mining media pipeline (real ffmpeg)', () {
    late Directory tmp;
    late String videoPath;

    setUpAll(() async {
      if (ffmpeg == null) return;
      tmp = await Directory.systemTemp.createTemp('immersion_ffmpeg');
      videoPath = '${tmp.path}/fixture.mp4';
      // testsrc 视频 + sine 音频，5s，320x240@15fps，H.264/AAC。
      final ProcessResult r = Process.runSync(ffmpeg, <String>[
        '-y',
        '-f', 'lavfi', '-i', 'testsrc=duration=5:size=320x240:rate=15',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=5',
        '-c:v', 'libx264', '-c:a', 'aac', '-pix_fmt', 'yuv420p', '-shortest',
        videoPath,
      ]);
      expect(r.exitCode, 0, reason: 'fixture encode failed: ${r.stderr}');
    });

    tearDownAll(() async {
      if (ffmpeg != null && tmp.existsSync()) {
        await tmp.delete(recursive: true);
      }
    });

    test('extractClipGifViaFfmpeg produces a real GIF', () async {
      final String? gif = await extractClipGifViaFfmpeg(
        inputPath: videoPath,
        startMs: 1000,
        endMs: 3000,
        outputPath: '${tmp.path}/clip.gif',
      );
      expect(gif, isNotNull);
      final List<int> bytes = File(gif!).readAsBytesSync();
      expect(bytes.length, greaterThan(100));
      // GIF87a / GIF89a magic.
      expect(String.fromCharCodes(bytes.take(3)), 'GIF');
    }, skip: ffmpeg == null ? 'ffmpeg unavailable' : false);

    test('extractAudioSegmentViaFfmpeg produces non-empty audio', () async {
      final String? audio = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: 1000,
        endMs: 3000,
        outputPath: '${tmp.path}/clip.aac',
      );
      expect(audio, isNotNull);
      expect(File(audio!).lengthSync(), greaterThan(100));
    }, skip: ffmpeg == null ? 'ffmpeg unavailable' : false);

    test('engine end-to-end: real GIF + audio -> mineEntry with cover+audio', () async {
      final _FakeRepo repo = _FakeRepo();
      final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: const <String, String>{'expression': '走る'},
          mediaSource: videoPath,
          clipStartMs: 1000,
          clipEndMs: 3000,
          sentence: '走り出した。',
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
      );
      expect(res.aborted, isFalse);
      expect(repo.minedContext, isNotNull);
      expect(repo.minedContext!.coverPath, endsWith('.gif'));
      expect(File(repo.minedContext!.coverPath!).lengthSync(), greaterThan(100));
      expect(repo.minedContext!.sasayakiAudioPath, isNotNull);
      expect(File(repo.minedContext!.sasayakiAudioPath!).lengthSync(),
          greaterThan(100));
    }, skip: ffmpeg == null ? 'ffmpeg unavailable' : false);
  });
}

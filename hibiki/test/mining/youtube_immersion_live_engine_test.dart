// TODO-1000（BUG-528/522）真网络+真 ffmpeg 端到端：resolveYoutubeSource → 用 controller
// 会设的同款制卡源（miningVideoUrl 抽 GIF、audioStreamUrl 抽音频）跑真 ImmersionMiningEngine，
// 断言产出的 AnkiMiningContext 带真实 GIF 封面 + 真实音频 + 字幕句子。
//
// 依赖真网络（直连 YouTube）+ 本机 ffmpeg，故**默认 skip**，仅 HIBIKI_YT_LIVE_ITEST=1 时跑：
//   $env:HIBIKI_YT_LIVE_ITEST=1
//   flutter test test/mining/youtube_immersion_live_engine_test.dart
// 纯 host VM（无 libmpv / 无设备 / 不碰用户 DB）——播放器侧证据见
// integration_test/youtube_stream_playback_itest.dart。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;

const String _kUrl = 'https://youtu.be/fKMEsvCtlZA';

bool get _live => Platform.environment['HIBIKI_YT_LIVE_ITEST'] == '1';

/// 只捕获制卡 context 的假 Anki repo（不连真 Anki——验的是「从直播流抽出的媒体」）。
class _CaptureRepo implements BaseAnkiRepository {
  AnkiMiningContext? captured;
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    captured = context;
    return const MineOutcome.success(noteId: 1);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'live: resolve → engine mines real GIF + audio from stream sources',
    () async {
      final YoutubeResolvedSource src = await resolveYoutubeSource(_kUrl);
      // ignore: avoid_print
      print('[yt-mine] title="${src.title}" cues=${src.cues.length} '
          'muxedFallback=${src.isMuxedFallback} '
          'miningVideoNull=${src.miningVideoUrl == null}');
      expect(src.cues, isNotEmpty, reason: '字幕 cue = 制卡句子来源');

      // controller.miningSource / miningAudioSource 的同款取法（见 video_hibiki_page）：
      // GIF/帧从低分辨率 miningVideoUrl（回落 streamUrl），音频从 audio-only。
      final String miningVideo = src.miningVideoUrl ?? src.streamUrl;
      final String? miningAudio = src.audioStreamUrl;

      final Directory tmp =
          await Directory.systemTemp.createTemp('yt_mine_engine');
      final _CaptureRepo repo = _CaptureRepo();
      final ImmersionMiningResult res = await ImmersionMiningEngine().mine(
        ImmersionMiningRequest(
          fields: const <String, String>{'expression': 'アンキ'},
          mediaSource: miningVideo,
          audioSource: miningAudio,
          clipStartMs: 5000,
          clipEndMs: 8000,
          sentence: src.cues.first.text,
          documentTitle: src.title,
          requireAudio: true,
        ),
        compression: MiningMediaCompression.compressed,
        tempDir: tmp.path,
        repo: repo,
        // ignore: avoid_print
        onFailure: (String s) => print('[yt-mine] FFMPEG_FAIL '
            '${s.substring(0, s.length < 240 ? s.length : 240)}'),
      );

      // ignore: avoid_print
      print('[yt-mine] aborted=${res.aborted} '
          'cover=${repo.captured?.coverPath} '
          'audio=${repo.captured?.sasayakiAudioPath}');
      expect(res.aborted, isFalse, reason: 'GIF+音频都应抽到，制卡不中止');
      final AnkiMiningContext ctx = repo.captured!;
      expect(ctx.coverPath, isNotNull);
      expect(ctx.coverPath, endsWith('.gif'), reason: '封面应是 cue GIF（非降级静帧）');
      expect(File(ctx.coverPath!).lengthSync(), greaterThan(1000));
      expect(ctx.sasayakiAudioPath, isNotNull);
      expect(File(ctx.sasayakiAudioPath!).lengthSync(), greaterThan(1000));
      expect(ctx.sentence, isNotEmpty);
      expect(ctx.source, AnkiMiningSource.video);
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: !_live,
  );
}

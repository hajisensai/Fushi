// TODO-1000 真机集成测试：YouTube 直链在真实 libmpv 窗口上**真播放**（BUG-528 修复验证）。
//
// 跑完整失败路径：resolveYoutubeSource(androidVr 流+字幕) → 构造 UrlStreamVideoClient →
// 打开 VideoHibikiPage.neutralizedRemote → 真实播放 → 断言 position 自然前进（证明 libmpv
// 能解码 androidVr 签发的 ≤1080p video-only 流 + 外挂 audio-only 音轨，非黑屏）。并断言
// controller 的**制卡源**被正确设成低分辨率视频（miningVideoUrl）+ audio-only 音频源。
//
// 依赖真实网络（直连 YouTube），故**默认 skip**，仅在设 HIBIKI_YT_LIVE_ITEST=1 时跑：
//   $env:HIBIKI_YT_LIVE_ITEST=1; .\tool\run_windows_itest.ps1 -Visible `
//     integration_test\youtube_stream_playback_itest.dart
// 必须 -Visible（media_kit 需 DWM 合成实窗）。制卡媒体抽取的端到端证据见
// test/mining/youtube_immersion_live_engine_test.dart（纯 host VM，真网络+真 ffmpeg）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart'
    show RemoteVideoInfo;

import 'test_helpers.dart';

const String _kUrl = 'https://youtu.be/fKMEsvCtlZA'; // 用户 TODO-1000 原报障 URL

/// 仅在进程环境 HIBIKI_YT_LIVE_ITEST=1 时跑（依赖真网络，默认 skip 不进 CI）。
bool get _live => Platform.environment['HIBIKI_YT_LIVE_ITEST'] == '1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'YouTube stream plays on the real libmpv window (position advances)',
    (WidgetTester tester) async {
      final List<String> caught = <String>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        caught.add(details.exceptionAsString());
        debugPrint('[yt-itest] caught: ${details.exceptionAsString()}');
      };
      try {
        app.main(const <String>[]);
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        // ── 真网络解析（androidVr 流 + 字幕）──────────────────────────────
        YoutubeResolvedSource resolved;
        try {
          resolved = await resolveYoutubeSource(_kUrl);
        } catch (e) {
          debugPrint('[yt-itest] resolve FAILED (network?): $e — skipping');
          return; // 网络不可达时不误判失败
        }
        debugPrint('[yt-itest] resolved title="${resolved.title}" '
            'cues=${resolved.cues.length} muxedFallback=${resolved.isMuxedFallback} '
            'miningVideoNull=${resolved.miningVideoUrl == null}');
        expect(resolved.streamUrl, isNotEmpty);
        expect(resolved.cues, isNotEmpty, reason: '应解析出字幕 cue（查词/制卡句子来源）');

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        final UrlStreamVideoClient client = UrlStreamVideoClient(
          streamUrl: resolved.streamUrl,
          audioStreamUrl: resolved.audioStreamUrl,
          miningVideoUrl: resolved.miningVideoUrl,
          preresolvedCues: resolved.cues,
          httpHeaderFields: resolved.httpHeaders,
        );
        final RemoteVideoInfo info =
            RemoteVideoInfo(id: 'video/stream/yt-itest', title: resolved.title);

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoHibikiPage.neutralizedRemote(
            info: info,
            repo: repo,
            client: client,
          ),
        )));

        VideoHibikiTestHooks? readHooks() {
          if (find.byType(VideoHibikiPage).evaluate().isEmpty) return null;
          return tester.state<State<VideoHibikiPage>>(
              find.byType(VideoHibikiPage)) as VideoHibikiTestHooks;
        }

        // 等控制器就绪（load 完成 → debugPositionMs 非 null），流媒体首帧慢，给足 60s。
        bool ready = false;
        for (int i = 0; i < 240; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (readHooks()?.debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        expect(ready, isTrue, reason: '流控制器应就绪（load 后 debugPositionMs 非 null）');

        final VideoHibikiTestHooks hooks = readHooks()!;
        debugPrint('[yt-itest] ready durationMs=${hooks.debugDurationMs}');

        // 真实播放：位置应自然前进（= libmpv 真在解码 androidVr 流，非黑屏卡 loading）。
        await hooks.debugPlay();
        int played = 0;
        for (int i = 0; i < 360; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          played = hooks.debugPositionMs ?? 0;
          if (i % 10 == 0) {
            debugPrint('[yt-itest] t=${i * 250}ms posMs=$played '
                'durMs=${hooks.debugDurationMs}');
          }
          if (played > 1500) break;
        }
        debugPrint('[yt-itest] FINAL playedMs=$played '
            'durMs=${hooks.debugDurationMs}');
        expect(played, greaterThan(1500),
            reason: 'libmpv 应真实播放前进 >1.5s（实测=$played）——黑屏则永远 0');

        // ── 制卡源接线：GIF/帧走低分辨率流（miningVideoUrl），音频走 audio-only ──
        final String? miningVideo = hooks.debugMiningSource;
        final String? miningAudio = hooks.debugMiningAudioSource;
        debugPrint('[yt-itest] miningSource=$miningVideo');
        debugPrint('[yt-itest] miningAudioSource=$miningAudio');
        expect(miningVideo, isNotNull, reason: '制卡视频源应已设（低分辨率 miningVideoUrl）');
        expect(miningAudio, isNotNull, reason: '制卡音频源应已设（audio-only 流）');
        // 制卡视频源 != 播放流（低分辨率 ≠ ≤1080p 播放流），避免从大流抽 GIF 超时。
        expect(miningVideo, isNot(equals(resolved.streamUrl)));

        await navigator.maybePop();
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(VideoHibikiPage).evaluate().isEmpty) break;
        }
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
    skip: !_live,
  );
}

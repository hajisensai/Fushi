import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/mining/immersion_mining_engine.dart';
import 'package:hibiki/src/mining/immersion_mining_request.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

import '../helpers/source_guard.dart';

/// TODO-2519(2a)：远端制卡的 **YouTube** 路径过去只透传了动图**格式**偏好
/// （`videoMiningAnimatedFormat`，BUG-1330），却没透传「动图 vs 静态帧」偏好
/// （`videoMiningImageMode`）——用户在 Anki 设置里选「字幕开头截图 / 制卡时截图」，
/// 从浏览器扩展制的 YouTube 卡照样是动图。
///
/// 本文件钉死两件事：
/// 1. `mineImmersion` 的 YouTube 段真的把 `_appModel.videoMiningImageMode` 下发给
///    `ImmersionMiningRequest`（源码扫描守卫——`mineImmersion` 内部 `new` 引擎、读
///    真 `AppModel`，没有可注入的缝，这是能落地的最强层）；
/// 2. 这一处透传**单独就有效**，不依赖任何后续改动：服务端 YouTube 请求没有
///    `stillFallback`（拿不到当前解码帧）也没有 `providedCoverBytes`（不走引擎
///    :213 的短路），两种静态模式都落到引擎的起点单帧，且**完全不进**
///    `extractAnimatedClipWithFallback`。
///
/// 后一条同时是 BUG-1039 的反向确认：静态帧路径压根不吃 `gifFps`/`gifWidth`，
/// 不存在「参数与实际编码路径不匹配」——它把大体积动图编码整个跳过了。

class _FakeRepo implements BaseAnkiRepository {
  AnkiMiningContext? minedContext;

  @override
  Future<MineOutcome> mineEntry(
      {required String rawPayloadJson,
      required AnkiMiningContext context}) async {
    minedContext = context;
    return const MineOutcome.success(noteId: 42);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 计数用假动图抽取器：本组用例的核心断言是「静态模式下它一次都没被调用」。
class _CountingGifExtractor {
  int calls = 0;

  Future<String?> call({
    required String inputPath,
    required int startMs,
    required int endMs,
    required String outputPath,
    int fps = 8,
    int width = 320,
    MiningAnimatedFormat format = MiningAnimatedFormat.gif,
    bool diagnosticOnly = false,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
  }) async {
    calls += 1;
    return outputPath;
  }
}

Future<String?> _okAudio({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  int? audioStreamCount,
  FfmpegFailureReporter? onFailure,
  int audioChannels = 1,
  String audioBitrate = '64k',
  String? tlsPinSha256,
}) async =>
    outputPath;

/// YouTube 的分离音频轨是远端 http(s)，引擎会先走 range 物化（TODO-1314）。默认物化器
/// 是真下载——测试里注入「物化未命中」，让音频落到下面的假抽取器，全程不碰网络。
Future<String?> _noMaterialize({
  required String audioUrl,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
}) async =>
    null;

Future<String?> _okFrame({
  required String inputPath,
  required String outputPath,
  double atSeconds = 10.0,
  FfmpegFailureReporter? onFailure,
  String? tlsPinSha256,
}) async =>
    outputPath;

/// 服务端 YouTube 制卡请求的形状：有分离的视频/音频流 URL 与真实时间窗，
/// **无** `stillFallback`（无前台播放器可截当前帧）、**无** `providedCoverBytes`。
ImmersionMiningRequest _youtubeRequest(VideoMiningImageMode mode) =>
    ImmersionMiningRequest(
      fields: const <String, String>{'expression': 'x'},
      mediaSource: 'https://example.invalid/video.mp4',
      audioSource: 'https://example.invalid/audio.m4a',
      clipStartMs: 1000,
      clipEndMs: 3000,
      sentence: 's',
      documentTitle: 'YouTube',
      source: AnkiMiningSource.video,
      requireAudio: true,
      animatedFormat: MiningAnimatedFormat.avif,
      imageMode: mode,
    );

void main() {
  group('YouTube 服务端形状：imageMode 单独透传即生效（不依赖 Netflix 侧改动）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('todo2519_image_mode');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<({_FakeRepo repo, int gifCalls})> mine(
        VideoMiningImageMode mode) async {
      final _CountingGifExtractor gif = _CountingGifExtractor();
      final _FakeRepo repo = _FakeRepo();
      final ImmersionMiningResult res = await ImmersionMiningEngine(
        gifExtractor: gif.call,
        audioExtractor: _okAudio,
        frameExtractor: _okFrame,
        audioMaterializer: _noMaterialize,
      ).mine(
        _youtubeRequest(mode),
        // 顶格档 + AVIF：若静态模式误走动图路径，抽取器会收到 24fps/1440px。
        compression: MiningMediaCompression.resolve(
          imageTier: 3,
          audioTier: 0,
          format: MiningAnimatedFormat.avif,
        ),
        tempDir: tmp.path,
        repo: repo,
      );
      expect(res.aborted, isFalse);
      return (repo: repo, gifCalls: gif.calls);
    }

    test('subtitleStart → 起点单帧，动图抽取器一次都不调', () async {
      final ({_FakeRepo repo, int gifCalls}) out =
          await mine(VideoMiningImageMode.subtitleStart);
      expect(out.repo.minedContext!.coverPath, endsWith('immersion_frame.jpg'),
          reason: '用户选「字幕开头截图」，YouTube 卡的封面必须是起点单帧。TODO-2519。');
      expect(out.gifCalls, 0,
          reason: '静态模式不该进 extractAnimatedClipWithFallback —— 既是行为正确性，'
              '也是不触发 BUG-1039 那类大体积编码的原因（静态帧不吃 gifFps/gifWidth）。');
    });

    test('currentFrame 无 stillFallback → 退起点单帧，同样不编动图', () async {
      final ({_FakeRepo repo, int gifCalls}) out =
          await mine(VideoMiningImageMode.currentFrame);
      expect(out.repo.minedContext!.coverPath, endsWith('immersion_frame.jpg'),
          reason: '服务端路径没有当前解码帧可截（stillFallback==null），'
              '「制卡时截图」按引擎排列退到起点单帧，而不是回落成动图。TODO-2519。');
      expect(out.gifCalls, 0);
    });

    test('gif（默认档）仍走动图 —— 老行为逐字等价', () async {
      final ({_FakeRepo repo, int gifCalls}) out =
          await mine(VideoMiningImageMode.gif);
      expect(out.gifCalls, 1);
      expect(out.repo.minedContext!.coverPath, endsWith('.avif'),
          reason: '默认动图档不受本改动影响，仍按 animatedFormat 出 AVIF。');
    });
  });

  group('源码扫描守卫：mineImmersion 的 YouTube 段必须下发 imageMode', () {
    /// 剥掉注释再扫。散文里为解释这条断链必然写出同样的符号名，让文档把守卫喂绿是
    /// 假阳性；判据只应落在真实代码上。
    String codeOnly(String src) => maskComments(src);

    test('ImmersionMiningRequest 收 _appModel.videoMiningImageMode', () {
      final String src =
          File('lib/src/models/app_model.dart').readAsStringSync();
      final int start = src.indexOf('Future<RemoteMineResult> mineImmersion(');
      expect(start, greaterThan(0), reason: 'mineImmersion 改名了？守卫锚点失效，请同步更新。');
      final int end = src.indexOf('void recordHistory(', start);
      expect(end, greaterThan(start));
      final String body = codeOnly(src.substring(start, end));

      // 只看 YouTube 段：Netflix 段走 buildImmersionRequest（TODO-2519 的 ②③，
      // 另有短路问题未解），不该被这条守卫误判。
      final int netflix = body.indexOf('ImmersionCaptureResult cap =');
      expect(netflix, greaterThan(0),
          reason: 'YouTube 段与 Netflix 段的分界锚点失效，请同步更新守卫。');
      final String youtube = body.substring(0, netflix);

      expect(youtube, contains('imageMode: _appModel.videoMiningImageMode'),
          reason: 'YouTube 的 ImmersionMiningRequest 必须收 imageMode，否则值对象默认 '
              'gif → 用户选的「字幕开头截图 / 制卡时截图」在扩展这条链路上恒被吞成'
              '动图。TODO-2519(2a)。');
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

import '../helpers/source_guard.dart';

/// BUG-2625：在线视频源扩展（Aniyomi）的剧集制卡恒失败——
/// `required audio missing (… stderr=Server returned 403 Forbidden (access denied))`。
///
/// 根因不是 ffmpeg 参数写错，而是**制卡与播放用的不是同一组请求头**：扩展解析出的
/// hoster 直链几乎都校验 Referer/User-Agent，播放器一直在带（`Media(httpHeaders:)` +
/// libmpv `http-header-fields`），而制卡的 ffmpeg 对同一条 URL 裸请求。
///
/// 参数层的不变量由 `ffmpeg_stream_http_headers_args_test.dart` 钉；本文件钉**接线**
/// ——头真的从请求一路到达三个抽取器，以及视频页真的把当前流的头填进请求。少了任何
/// 一段，参数层做得再对也永远收不到头。
class _FakeRepo implements BaseAnkiRepository {
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome.success(noteId: 1);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// 记录各抽取器收到的头。null = 那条链一次都没被调用（与「收到空 map」是两件事）。
class _HeaderSpy {
  Map<String, String>? gif;
  Map<String, String>? audio;
  Map<String, String>? frame;

  Future<String?> takeGif({
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
    Map<String, String> httpHeaders = const {},
  }) async {
    gif = httpHeaders;
    return outputPath;
  }

  Future<String?> takeAudio({
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
    Map<String, String> httpHeaders = const {},
  }) async {
    audio = httpHeaders;
    return outputPath;
  }

  Future<String?> takeFrame({
    required String inputPath,
    required String outputPath,
    double atSeconds = 10.0,
    FfmpegFailureReporter? onFailure,
    String? tlsPinSha256,
    Map<String, String> httpHeaders = const {},
    bool diagnosticOnly = false,
  }) async {
    frame = httpHeaders;
    return outputPath;
  }
}

/// 远端音频轨要先走 range 物化（TODO-1314，只认 googlevideo）。注入「未命中」让音频
/// 落到假抽取器上，全程不碰网络。
Future<String?> _noMaterialize({
  required String audioUrl,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
}) async =>
    null;

const Map<String, String> _extensionHeaders = <String, String>{
  'Referer': 'https://anime-site.example/watch/1',
  'User-Agent': 'Mozilla/5.0 (extension)',
};

ImmersionMiningRequest _request({
  required Map<String, String> headers,
  VideoMiningImageMode imageMode = VideoMiningImageMode.gif,
}) =>
    ImmersionMiningRequest(
      fields: const <String, String>{'expression': 'x'},
      // 在线源的制卡源就是 hoster 直链（`setMiningSourceOverride(mediaUri)`），
      // 视频与音频同一条 muxed 流、无单独 audioSource。
      mediaSource: 'https://cdn.example-hoster.net/hls/master.m3u8',
      clipStartMs: 1000,
      clipEndMs: 3000,
      sentence: 's',
      documentTitle: 'Episode 1',
      source: AnkiMiningSource.video,
      requireAudio: true,
      imageMode: imageMode,
      mediaSourceHttpHeaders: headers,
    );

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mining_stream_headers');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> mine(_HeaderSpy spy, ImmersionMiningRequest req) =>
      ImmersionMiningEngine(
        gifExtractor: spy.takeGif,
        audioExtractor: spy.takeAudio,
        frameExtractor: spy.takeFrame,
        audioMaterializer: _noMaterialize,
      ).mine(
        req,
        compression: MiningMediaCompression.resolve(
          imageTier: 1,
          audioTier: 0,
          format: MiningAnimatedFormat.gif,
        ),
        tempDir: tmp.path,
        repo: _FakeRepo(),
      );

  group('引擎接线：请求里的流请求头必须到达抽取器（BUG-2625）', () {
    test('动图 + 句子音频两条链都收到头', () async {
      final _HeaderSpy spy = _HeaderSpy();
      await mine(spy, _request(headers: _extensionHeaders));
      expect(spy.audio, _extensionHeaders,
          reason: '句子音频抽不出来就是用户看到的 `required audio missing` 那条中止');
      expect(spy.gif, _extensionHeaders, reason: '封面动图与音频同源同头，漏了会静默降级成静态帧');
    });

    test('静态帧链（字幕开头帧）也收到头', () async {
      final _HeaderSpy spy = _HeaderSpy();
      await mine(
        spy,
        _request(
          headers: _extensionHeaders,
          imageMode: VideoMiningImageMode.subtitleStart,
        ),
      );
      expect(spy.frame, _extensionHeaders);
    });

    test('不给头 → 抽取器收到空 map（本地/无防盗链源行为不变）', () async {
      final _HeaderSpy spy = _HeaderSpy();
      await mine(spy, _request(headers: const <String, String>{}));
      expect(spy.audio, isEmpty);
      expect(spy.gif, isEmpty);
    });

    test('frozen() 保留头：入队后换集也用点击那一刻的头', () {
      final ImmersionMiningRequest frozen =
          _request(headers: _extensionHeaders).frozen();
      expect(frozen.mediaSourceHttpHeaders, _extensionHeaders);
      expect(() => frozen.mediaSourceHttpHeaders['Referer'] = 'x',
          throwsUnsupportedError,
          reason: '冻结后不可变——否则换集时的头改动会反向污染队列里的旧卡');
    });
  });

  group('源码扫描守卫：视频页必须把当前流的头填进制卡请求', () {
    // `_mineVideoCard` 是页面 State 的私有方法（`part of video_fushi_page.dart`），
    // 没有可注入的缝；源码扫描是这一段能落地的最强层，与
    // `remote_mining_image_mode_test.dart` 的 imageMode 守卫同形。
    test('ImmersionMiningRequest 收 _streamHttpHeaderFields', () {
      final String src = File(
        'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
      ).readAsStringSync();
      final String body =
          methodBody(maskComments(src), 'ImmersionMiningRequest(');
      expect(
        body,
        contains('mediaSourceHttpHeaders: _streamHttpHeaderFields'),
        reason: '制卡请求必须带上播放器取流用的同一组头，否则在线视频源扩展的剧集'
            '恒 403（BUG-2625）。头的来源必须是 `_streamHttpHeaderFields`（当前已解析'
            '流的头），不是某个常量。',
      );
    });
  });
}

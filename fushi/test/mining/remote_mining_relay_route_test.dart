import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression, FfmpegFailureReporter;

import '../helpers/source_guard.dart';

/// BUG-2642 残留：在线视频源的制卡输入改走本机中继。
///
/// 制卡请求必须在点击当下**同步**入队（连续点击按序、换集前冻结输入），而「经中继」
/// 的登记是异步的（读播放器识别的容器、确认中继端点、探 ffmpeg 能力）。所以视频页
/// 当场改写地址、把登记作为 [ImmersionMiningRequest.mediaSourceRouteReady] 挂上，引擎
/// 轮到本任务时先等它再调抽取器。本文件钉这条接线；参数层见
/// `test/media/video/ffmpeg_remote_input_route_args_test.dart`，真 ffmpeg + 真中继见
/// `test/utils/net/ffmpeg_relay_route_e2e_test.dart`。
class _FakeRepo implements BaseAnkiRepository {
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success(noteId: 1);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Spy {
  final List<String> calls = <String>[];

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
    calls.add('gif');
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
    calls.add('audio');
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
    calls.add('frame');
    return outputPath;
  }
}

Future<String?> _noMaterialize({
  required String audioUrl,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
}) async => null;

ImmersionMiningRequest _request(Future<void>? ready) => ImmersionMiningRequest(
  fields: const <String, String>{'expression': 'x'},
  mediaSource: 'http://cdn.example-hoster.net:443/hls/index',
  clipStartMs: 1000,
  clipEndMs: 3000,
  sentence: 's',
  documentTitle: 'Episode 1',
  source: AnkiMiningSource.video,
  requireAudio: true,
  mediaSourceRouteReady: ready,
);

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mining_relay_route');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('路由登记完成前，任何抽取器都不启动', () async {
    final _Spy spy = _Spy();
    final Completer<void> gate = Completer<void>();
    final Future<ImmersionMiningResult> mining =
        ImmersionMiningEngine(
          gifExtractor: spy.takeGif,
          audioExtractor: spy.takeAudio,
          frameExtractor: spy.takeFrame,
          audioMaterializer: _noMaterialize,
        ).mine(
          _request(gate.future),
          compression: MiningMediaCompression.resolve(
            imageTier: 1,
            audioTier: 0,
            format: MiningAnimatedFormat.gif,
          ),
          tempDir: tmp.path,
          repo: _FakeRepo(),
        );
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(spy.calls, isEmpty, reason: '没等登记就构造 ffmpeg 参数 = 直连原始地址');

    gate.complete();
    await mining;
    expect(spy.calls, contains('audio'));
  });

  test('frozen() 保留登记信号：入队后换集也等点击那一刻的登记', () {
    final Future<void> ready = Future<void>.value();
    expect(_request(ready).frozen().mediaSourceRouteReady, same(ready));
  });

  test('宿主装配：installEngineHostBindings 把登记表接到引擎装配点', () {
    // 没接线时视频页照样改写地址、照样登记，引擎却永远查不到——ffmpeg 拿着中继形式的
    // 明文地址直连，静默失败。
    final String bindings = maskComments(
      File('lib/src/engine_bindings.dart').readAsStringSync(),
    );
    expect(
      containsCodeLine(
        methodBody(bindings, 'void installEngineHostBindings('),
        'ffmpegRemoteInputRouteResolver = ffmpegRelayRouteFor;',
      ),
      isTrue,
    );
  });

  group('源码扫描守卫：视频页只对在线流改道，并把登记信号交给请求', () {
    // `_mineVideoCard` 是页面 State 的私有方法，没有可注入的缝；与
    // `remote_mining_stream_headers_test.dart` 的请求头守卫同形。
    late String src;
    setUpAll(() {
      src = maskComments(
        File(
          'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
        ).readAsStringSync(),
      );
    });

    test('ImmersionMiningRequest 收 mediaSourceRouteReady', () {
      expect(
        methodBody(src, 'ImmersionMiningRequest('),
        contains('mediaSourceRouteReady: mediaSourceRouteReady'),
      );
    });

    test('只对带请求头能力的在线流（扩展 hoster / 粘贴的流）、且是网络地址时改道', () {
      final int call = src.indexOf('relayFfmpegRemoteInput(');
      expect(call, greaterThanOrEqualTo(0));
      final String guard = src.substring(src.lastIndexOf('if (', call), call);
      expect(
        guard,
        contains('is RemoteVideoStreamHeaders'),
        reason: 'YouTube / 互联主机 / 媒体服务器各有自己的取流特例，不能一起改道',
      );
      expect(guard, contains('isNetworkStreamUri('));
      expect(
        src.substring(call, src.indexOf(';', call)),
        contains('controller.isHlsStream()'),
        reason: '判 HLS 以播放器识别的容器为准，在线源播放列表常不带 .m3u8',
      );
    });
  });
}

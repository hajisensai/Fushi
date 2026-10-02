// Apple 视频「发灰」的像素探针（BUG-2861；macOS 真机 / iOS 模拟器）。
//
// 背景：Flutter macOS 把外部 BGRA 纹理按原值合成进固定标记为 sRGB 的 IOSurface，而
// libmpv 在 `target-trc=auto` 下对 SDR 片源不换 gamma、吐 BT.1886（γ2.4）编码值——
// γ2.4 的数据被按 sRGB 解释，暗部被抬亮、画面发灰。修复把 macOS 的输出目标钉成
// `target-prim=bt.709` + `target-trc=srgb`（`resolveTextureColorTargetProperties`）。
//
// 本测试在测试内生成一段已知码值的灰阶 Y4M（有限范围 Y=16…235，U=V=128），经本地
// HTTP 交给真实 libmpv 播放，暂停后用 `toImage` 读回 Flutter 实际合成到的纹理像素，
// 同一帧下 A/B：
//   A = 当前生产配置（修复后应为 sRGB 目标）→ 每块应等于 srgb_encode(((Y-16)/219)^2.4)
//   B = 手动改回 `target-trc=auto`（修复前的行为）→ 每块应等于 (Y-16)/219 原值
//
// Mac：flutter test -d macos integration_test/video_mac_color_target_itest.dart
// iOS 模拟器：flutter test -d <sim-udid> 同一文件（模拟器上 media_kit 走 TextureSW）。
// HDR：加 --dart-define=FUSHI_COLOR_PROBE=hdr（同一段灰阶按 BT.2020 + PQ 解释）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

import 'test_helpers.dart';

const int _kW = 640;
const int _kH = 360;
const int _kFrames = 50; // 10 fps × 5 s

/// 灰阶色块的有限范围亮度码值（从左到右等宽排列）。
const List<int> _kLevels = <int>[
  16, 24, 32, 40, 52, 64, 80, 96, 112, 128, 150, 175, 200, 235,
];

Uint8List _buildGrayRampY4m() {
  final BytesBuilder out = BytesBuilder(copy: false);
  out.add('YUV4MPEG2 W$_kW H$_kH F10:1 Ip A1:1 C420jpeg\n'.codeUnits);
  final Uint8List y = Uint8List(_kW * _kH);
  final int band = _kW ~/ _kLevels.length;
  for (int row = 0; row < _kH; row++) {
    for (int col = 0; col < _kW; col++) {
      final int i = math.min(col ~/ band, _kLevels.length - 1);
      y[row * _kW + col] = _kLevels[i];
    }
  }
  final Uint8List chroma = Uint8List((_kW ~/ 2) * (_kH ~/ 2))
    ..fillRange(0, (_kW ~/ 2) * (_kH ~/ 2), 128);
  for (int f = 0; f < _kFrames; f++) {
    out.add('FRAME\n'.codeUnits);
    out.add(y);
    out.add(chroma);
    out.add(chroma);
  }
  return out.takeBytes();
}

/// `sdr`（默认）或 `hdr`：hdr 用 mpv `vf=format` 把同一段灰阶标成 BT.2020 + PQ，
/// 走真实色调映射链路。
const String _kProbeMode = String.fromEnvironment(
  'FUSHI_COLOR_PROBE',
  defaultValue: 'sdr',
);

double _srgbEncode(double linear) => linear <= 0.0031308
    ? 12.92 * linear
    : 1.055 * math.pow(linear, 1 / 2.4) - 0.055;

double _srgbDecode(double encoded) => encoded <= 0.04045
    ? encoded / 12.92
    : math.pow((encoded + 0.055) / 1.055, 2.4).toDouble();

/// 有限范围码值 → 8-bit 期望输出：[srgbTarget] 为修复后，否则为原值直通。
double _expected(int level, {required bool srgbTarget}) {
  final double v = ((level - 16) / 219).clamp(0.0, 1.0);
  return 255 * (srgbTarget ? _srgbEncode(math.pow(v, 2.4).toDouble()) : v);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS mpv output is sRGB-encoded for the sRGB Flutter surface',
      (WidgetTester tester) async {
    final Uint8List y4m = _buildGrayRampY4m();
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      req.response.headers.contentType = ContentType('video', 'x-yuv4mpeg');
      req.response.contentLength = y4m.length;
      req.response.add(y4m);
      await req.response.close();
    });
    try {
      app.main(const <String>[]);
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final UrlStreamVideoClient client = UrlStreamVideoClient(
        streamUrl: 'http://127.0.0.1:${server.port}/ramp.y4m',
      );
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/stream/color-target-itest',
        title: 'gray ramp',
      );
      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => VideoFushiPage.neutralizedRemote(
          info: info,
          repo: repo,
          client: client,
        ),
      )));

      VideoFushiTestHooks? readHooks() {
        if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
            as VideoFushiTestHooks;
      }

      for (int i = 0; i < 240; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (readHooks()?.debugPositionMs != null) break;
      }
      final VideoFushiTestHooks hooks = readHooks()!;
      await hooks.debugPlay();
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if ((hooks.debugPositionMs ?? 0) > 1200) break;
      }
      await hooks.debugPause();
      await tester.pump(const Duration(seconds: 1));

      final Video video = tester.widget<Video>(find.byType(Video).first);
      final NativePlayer mpv = video.controller.player.platform as NativePlayer;
      const bool hdr = _kProbeMode == 'hdr';
      debugPrint('[color-itest] platform=${Platform.operatingSystem} '
          'mode=$_kProbeMode');
      if (hdr) {
        // 同一段灰阶按 PQ 信号解释；关掉动态峰值检测，让 A/B 两次色调映射可比。
        await mpv.setProperty('hdr-compute-peak', 'no');
        await mpv.setProperty(
          'vf',
          'format=primaries=bt.2020:gamma=pq:colormatrix=bt.2020-ncl',
        );
        await tester.pump(const Duration(seconds: 1));
      }

      Future<void> dumpParams(String tag) async {
        final List<String> keys = <String>[
          'target-trc',
          'target-prim',
          'video-params/gamma',
          'video-params/primaries',
          'video-params/colorlevels',
          'video-target-params/gamma',
          'video-target-params/primaries',
        ];
        for (final String k in keys) {
          debugPrint('[color-itest] $tag $k=${await mpv.getProperty(k)}');
        }
      }

      Future<List<double>> sampleBands(String tag) async {
        // 暂停时改输出目标后 seek 回原位逼出一次重绘，再等纹理落到 Flutter。
        await hooks.debugSeekMs(hooks.debugPositionMs ?? 1200);
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.pump(const Duration(milliseconds: 500));
        final RenderBox texture = tester.renderObject(find.byType(Texture).first);
        RenderObject? node = texture;
        while (node != null && node is! RenderRepaintBoundary) {
          node = node.parent;
        }
        final RenderRepaintBoundary boundary = node! as RenderRepaintBoundary;
        final Rect rect = MatrixUtils.transformRect(
          texture.getTransformTo(boundary),
          Offset.zero & texture.size,
        );
        final ui.Image image = await tester.runAsync(
              () => boundary.toImage(pixelRatio: 1),
            ) ??
            (throw StateError('toImage returned null'));
        final ByteData bytes = (await tester.runAsync<ByteData?>(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final List<double> means = <double>[];
        final double bandW = rect.width / _kLevels.length;
        for (int b = 0; b < _kLevels.length; b++) {
          final double cx = rect.left + bandW * (b + 0.5);
          double sum = 0;
          int n = 0;
          for (double dy = 0.2; dy <= 0.35; dy += 0.05) {
            final int py = (rect.top + rect.height * dy).round();
            for (int dx = -3; dx <= 3; dx++) {
              final int px = (cx + dx * bandW / 12).round();
              if (px < 0 || py < 0 || px >= image.width || py >= image.height) {
                continue;
              }
              final int o = (py * image.width + px) * 4;
              sum += bytes.getUint8(o + 1); // G 通道（灰阶三通道相等）
              n++;
            }
          }
          means.add(n == 0 ? -1 : sum / n);
        }
        debugPrint('[color-itest] $tag rect=$rect image='
            '${image.width}x${image.height} bands=${means.map((double m) => m.toStringAsFixed(1)).join(',')}');
        return means;
      }

      await dumpParams('A(prod)');
      final List<double> prod = await sampleBands('A(prod)');

      await mpv.setProperty('target-trc', 'auto');
      await mpv.setProperty('target-prim', 'auto');
      await tester.pump(const Duration(milliseconds: 500));
      await dumpParams('B(auto)');
      final List<double> auto = await sampleBands('B(auto)');

      double maxErr(List<double> got, {required bool srgbTarget}) {
        double worst = 0;
        for (int i = 0; i < _kLevels.length; i++) {
          final double e = _expected(_kLevels[i], srgbTarget: srgbTarget);
          debugPrint('[color-itest] srgb=$srgbTarget Y=${_kLevels[i]} '
              'expect=${e.toStringAsFixed(1)} got=${got[i].toStringAsFixed(1)}');
          worst = math.max(worst, (got[i] - e).abs());
        }
        return worst;
      }

      if (hdr) {
        // 色调映射本身不该因输出编码而变：把 A（sRGB 编码）与 B（mpv 对 HDR 片源
        // 在 target-trc=auto 下选 gamma2.2）各自解回线性光，应当一致；A 还应单调、
        // 不被压成一片（暗部可辨、高光不过曝）。
        // B 的输出 TRC 取决于 mpv 对 HDR 片源 auto 的选择（gamma2.2 或 bt.1886），
        // 两种都算，取吻合的那个并打印出来。
        final Map<String, double> worstBy = <String, double>{};
        for (final MapEntry<String, double> trc in <String, double>{
          'gamma2.2': 2.2,
          'bt.1886': 2.4,
        }.entries) {
          double w = 0;
          for (int i = 0; i < _kLevels.length; i++) {
            final double linB = math.pow(auto[i] / 255, trc.value).toDouble();
            final double reenc = 255 * _srgbEncode(linB);
            debugPrint('[color-itest] hdr ${trc.key} Y=${_kLevels[i]} '
                'A=${prod[i]} B=${auto[i]} '
                'linA=${_srgbDecode(prod[i] / 255).toStringAsFixed(4)} '
                'linB=${linB.toStringAsFixed(4)} '
                'B->srgb=${reenc.toStringAsFixed(1)}');
            w = math.max(w, (reenc - prod[i]).abs());
          }
          worstBy[trc.key] = w;
        }
        debugPrint('[color-itest] hdr worstBy=$worstBy');
        final double worst = worstBy.values.reduce(math.min);
        bool monotonic = true;
        for (int i = 1; i < prod.length; i++) {
          if (prod[i] < prod[i - 1]) monotonic = false;
        }
        debugPrint('[color-itest] RESULT hdr maxErr(B->srgb vs A)=$worst '
            'monotonic=$monotonic span=${prod.first}..${prod.last}');
        expect(worst, lessThan(4),
            reason: '色调映射后的线性光应与输出编码无关，只差 sRGB 编码');
        expect(monotonic, isTrue, reason: 'HDR 灰阶色调映射后应保持单调');
        expect(prod.last - prod.first, greaterThan(150),
            reason: 'HDR 灰阶不应被压成一片');
      } else {
        final double errProd = maxErr(prod, srgbTarget: true);
        final double errAuto = maxErr(auto, srgbTarget: false);
        debugPrint('[color-itest] RESULT maxErr prod(srgb)=$errProd '
            'auto(raw)=$errAuto');
        expect(errAuto, lessThan(4),
            reason: 'B 组应是 BT.1886 原值直通（修复前行为），否则探针本身不可信');
        expect(errProd, lessThan(4),
            reason: '生产配置下 mpv 应把 BT.1886 换算成 sRGB 编码');
      }

      await navigator.maybePop();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
      }
    } finally {
      await server.close(force: true);
    }
  });
}

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';

import '../../helpers/source_guard.dart';

/// Windows HDR / 10-bit 输出（`video_hdr_output.dart`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoHdrOutputMode 持久化', () {
    test('storageValue 往返', () {
      for (final VideoHdrOutputMode m in VideoHdrOutputMode.values) {
        expect(VideoHdrOutputMode.fromStorage(m.storageValue), m);
      }
    });

    test('坏值 / null 退回 auto（旧偏好 / 手改 DB 不炸）', () {
      expect(VideoHdrOutputMode.fromStorage(null), VideoHdrOutputMode.auto);
      expect(VideoHdrOutputMode.fromStorage(''), VideoHdrOutputMode.auto);
      expect(VideoHdrOutputMode.fromStorage('hdr'), VideoHdrOutputMode.auto);
    });
  });

  group('isHdrVideoParams', () {
    test('bt.2020 + pq / hlg 才算 HDR', () {
      expect(isHdrVideoParams(primaries: 'bt.2020', gamma: 'pq'), isTrue);
      expect(isHdrVideoParams(primaries: 'bt.2020', gamma: 'hlg'), isTrue);
    });

    test('bt.2020 + bt.1886（宽色域 SDR）不是 HDR', () {
      expect(isHdrVideoParams(primaries: 'bt.2020', gamma: 'bt.1886'), isFalse);
    });

    test('bt.709 + pq（畸形）不算；null 不算', () {
      expect(isHdrVideoParams(primaries: 'bt.709', gamma: 'pq'), isFalse);
      expect(isHdrVideoParams(primaries: null, gamma: null), isFalse);
    });
  });

  group('shouldUseHdrOutput（唯一判据）', () {
    test('非 Windows 恒 false，哪怕 always', () {
      for (final VideoHdrOutputMode m in VideoHdrOutputMode.values) {
        expect(
          shouldUseHdrOutput(
            isWindows: false,
            mode: m,
            displayHdr: true,
            sourceHdr: true,
          ),
          isFalse,
          reason: m.name,
        );
      }
    });

    test('off 恒 false', () {
      expect(
        shouldUseHdrOutput(
          isWindows: true,
          mode: VideoHdrOutputMode.off,
          displayHdr: true,
          sourceHdr: true,
        ),
        isFalse,
      );
    });

    test('always 在 Windows 恒 true（SDR 片 / SDR 屏也出 10-bit）', () {
      expect(
        shouldUseHdrOutput(
          isWindows: true,
          mode: VideoHdrOutputMode.always,
          displayHdr: false,
          sourceHdr: false,
        ),
        isTrue,
      );
    });

    test('auto 真值表：只有 显示器 HDR ∧ 片源 HDR 才 true', () {
      for (final bool d in <bool>[false, true]) {
        for (final bool s in <bool>[false, true]) {
          expect(
            shouldUseHdrOutput(
              isWindows: true,
              mode: VideoHdrOutputMode.auto,
              displayHdr: d,
              sourceHdr: s,
            ),
            d && s,
            reason: 'display=$d source=$s',
          );
        }
      }
    });

    // 宿主窗删除后的契约：没有第二个输出窗口，DV 也不再让判据改道。控制器的重判
    // 里不得再出现切 VO / 拿 HWND 的路径，DV 也不得把合成器 HDR 排除在外（BUG-2691
    // 的修法从「DV 改走 gpu-next 宿主窗」换成了「纹理渲染器自己重整」）。
    test('控制器只走合成器 HDR：不切 vo、不建窗口、不按 DV 排除', () {
      final String src = maskComments(
        File(
          'lib/src/media/video/video_player_controller.dart',
        ).readAsStringSync(),
      );
      final int start = src.indexOf('Future<void> _evaluateHdrOutputNow()');
      expect(start, greaterThan(0));
      final int end = src.indexOf('Future<bool> _isCompositorHdrSupported()');
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('shouldUseHdrOutput('));
      expect(body, isNot(contains('_hdrSourceIsDolbyVision &&')));
      expect(body, isNot(contains('!_hdrSourceIsDolbyVision')));
      for (final String forbidden in <String>["'vo'", 'gpu-next', "'wid'"]) {
        expect(src, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });

  // BUG-2691 办法 4：纹理渲染器不会重整的平台提示用户，而不是让人以为片子坏了。
  group('dolbyVisionColorsUnsupported', () {
    test('非 DV 片源恒 false', () {
      for (final bool w in <bool>[false, true]) {
        expect(
          dolbyVisionColorsUnsupported(isWindows: w, sourceDolbyVision: false),
          isFalse,
          reason: 'windows=$w',
        );
      }
    });

    test('Linux（系统 libmpv，无补丁）：提示', () {
      expect(dolbyVisionColorsUnsupported(sourceDolbyVision: true), isTrue);
    });

    test('Windows / macOS / iOS / Android：随包 gl_video 自带重整，不提示', () {
      expect(
        dolbyVisionColorsUnsupported(isWindows: true, sourceDolbyVision: true),
        isFalse,
      );
      expect(
        dolbyVisionColorsUnsupported(isApple: true, sourceDolbyVision: true),
        isFalse,
      );
      expect(
        dolbyVisionColorsUnsupported(isAndroid: true, sourceDolbyVision: true),
        isFalse,
      );
    });

    test('Android DV P5 强制软解（mediacodec 不解析 RPU），其它平台 / 非 DV 不动', () {
      expect(
        shouldForceSoftwareDecodeForDolbyVision(
          isAndroid: true,
          sourceDolbyVision: true,
        ),
        isTrue,
      );
      expect(
        shouldForceSoftwareDecodeForDolbyVision(
          isAndroid: true,
          sourceDolbyVision: false,
        ),
        isFalse,
      );
      expect(
        shouldForceSoftwareDecodeForDolbyVision(
          isAndroid: false,
          sourceDolbyVision: true,
        ),
        isFalse,
      );
    });
  });

  // BUG-2691：远端播放（Emby / Jellyfin / 互联）的 _initRemote 提前返回，此前漏读
  // HDR 输出与画面 fit，用户设的「关闭」「始终」对远端片源全不生效。
  test('播放页远端初始化读取 HDR 输出与画面 fit 设置', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<void> _initRemote() async {');
    expect(start, greaterThan(0));
    final RegExpMatch? methodEnd = RegExp(
      r'\r?\n  }\r?\n',
    ).firstMatch(src.substring(start));
    expect(
      methodEnd,
      isNotNull,
      reason: '_initRemote closing brace must exist',
    );
    final int end = start + methodEnd!.start;
    final String body = src.substring(start, end);
    expect(body, contains('_videoHdrOutputMode = appModel.videoHdrOutputMode'));
    expect(body, contains('_videoFitMode = appModel.videoFitMode'));
  });

  group('requiresDolbyVisionReshape', () {
    test('只认 mpv colormatrix=dolbyvision（P5 IPTPQc2 / P8.1）', () {
      expect(requiresDolbyVisionReshape('dolbyvision'), isTrue);
    });

    test('bt.2020-ncl（HDR10 矩阵）、SDR、未知都不算', () {
      expect(requiresDolbyVisionReshape('bt.2020-ncl'), isFalse);
      expect(requiresDolbyVisionReshape('bt.709'), isFalse);
      expect(requiresDolbyVisionReshape(null), isFalse);
    });
  });

  group('HdrDisplayInfo', () {
    test('colorSpace 12（HDR10）才算 HDR；面板能力不算', () {
      const HdrDisplayInfo hdr = HdrDisplayInfo(
        colorSpace: kDxgiColorSpaceHdr10,
        maxLuminance: 1015,
        bitsPerColor: 10,
      );
      const HdrDisplayInfo sdr10bit = HdrDisplayInfo(
        colorSpace: kDxgiColorSpaceSdr,
        maxLuminance: 1015,
        bitsPerColor: 10,
      );
      expect(hdr.isHdr, isTrue);
      expect(sdr10bit.isHdr, isFalse);
      expect(HdrDisplayInfo.unknown.isHdr, isFalse);
    });
  });

  group('compositorHdrFallback（合成器 HDR 失败的记忆范围）', () {
    test('三步都成：不退', () {
      expect(
        compositorHdrFallback(
          engineOn: true,
          textureReady: true,
          textureOn: true,
        ),
        isNull,
      );
    });

    test('引擎没开成：进程级「不支持」', () {
      expect(
        compositorHdrFallback(
          engineOn: false,
          textureReady: true,
          textureOn: false,
        ),
        CompositorHdrFallback.engineUnsupported,
      );
    });

    test('纹理还没建好：等纹理，不记失败（不得被记成进程级不支持）', () {
      expect(
        compositorHdrFallback(
          engineOn: true,
          textureReady: false,
          textureOn: false,
        ),
        CompositorHdrFallback.awaitTexture,
      );
    });

    test('纹理拒绝：只退当前这一路', () {
      expect(
        compositorHdrFallback(
          engineOn: true,
          textureReady: true,
          textureOn: false,
        ),
        CompositorHdrFallback.textureRefused,
      );
    });

    test('控制器只在 engineUnsupported 分支写进程级缓存', () {
      final String src = File(
        'lib/src/media/video/video_player_controller.dart',
      ).readAsStringSync();
      expect('_compositorHdrSupported = false'.allMatches(src), hasLength(1));
      final int write = src.indexOf('_compositorHdrSupported = false');
      final String before = src.substring(write - 120, write);
      expect(before, contains('CompositorHdrFallback.engineUnsupported:'));
    });
  });

  group('compositorHdrTarget（合成器内 HDR 的唯一亮度换算）', () {
    test('HDR 显示器：界面白 = SDR 内容亮度，参考白按绝对亮度，峰值 = 面板峰值', () {
      expect(
        compositorHdrTarget(
          const HdrDisplayInfo(
            colorSpace: kDxgiColorSpaceHdr10,
            maxLuminance: 1015,
            bitsPerColor: 10,
            sdrWhiteNits: 280,
          ),
        ),
        const CompositorHdrTarget(
          engineSdrWhiteNits: 280,
          referenceWhiteNits: 280,
          targetPeakNits: 1015,
        ),
      );
    });

    test('HDR 显示器但 SDR 白未知：按 scRGB 基准 80 尼特', () {
      final CompositorHdrTarget target = compositorHdrTarget(
        const HdrDisplayInfo(
          colorSpace: kDxgiColorSpaceHdr10,
          maxLuminance: 0,
          bitsPerColor: 10,
        ),
      );
      expect(target.engineSdrWhiteNits, kScRgbWhiteNits);
      expect(target.referenceWhiteNits, kScRgbWhiteNits);
      // 峰值未知交给 mpv 推断（≤0）。
      expect(target.targetPeakNits, 0);
    });

    test('SDR 显示器（always 模式）：参考白对齐界面白、峰值压到参考白，'
        '不随面板峰值 / SDR 滑块变', () {
      const CompositorHdrTarget sdr = CompositorHdrTarget(
        engineSdrWhiteNits: kScRgbWhiteNits,
        referenceWhiteNits: kMpvReferenceWhiteNits,
        targetPeakNits: kMpvReferenceWhiteNits,
      );
      for (final HdrDisplayInfo display in <HdrDisplayInfo>[
        HdrDisplayInfo.unknown,
        const HdrDisplayInfo(
          colorSpace: kDxgiColorSpaceSdr,
          maxLuminance: 1015,
          bitsPerColor: 10,
          sdrWhiteNits: 280,
        ),
      ]) {
        expect(compositorHdrTarget(display), sdr, reason: '$display');
      }
    });

    test('值相等即相等（控制器靠它判断要不要重下发）', () {
      const HdrDisplayInfo display = HdrDisplayInfo(
        colorSpace: kDxgiColorSpaceHdr10,
        maxLuminance: 600,
        bitsPerColor: 10,
        sdrWhiteNits: 200,
      );
      expect(compositorHdrTarget(display), compositorHdrTarget(display));
      expect(
        compositorHdrTarget(display).hashCode,
        compositorHdrTarget(display).hashCode,
      );
    });
  });

  group('HDR 图形白归一（字幕 / 弹幕层）', () {
    const HdrDisplayInfo hdr280 = HdrDisplayInfo(
      colorSpace: kDxgiColorSpaceHdr10,
      maxLuminance: 1000,
      bitsPerColor: 10,
      sdrWhiteNits: 280,
    );

    test('HDR 输出 + HDR 显示器：压到 203 / SDR 白（用户机实测 280 尼特）', () {
      expect(
        hdrGraphicsWhiteScale(outputActive: true, display: hdr280),
        closeTo(203 / 280, 1e-9),
      );
    });

    test('SDR 输出 / SDR 显示器 / SDR 白未知：恒 1（视频与 Flutter 同在 SDR 基准）', () {
      expect(hdrGraphicsWhiteScale(outputActive: false, display: hdr280), 1);
      expect(
        hdrGraphicsWhiteScale(
          outputActive: true,
          display: const HdrDisplayInfo(
            colorSpace: kDxgiColorSpaceSdr,
            maxLuminance: 400,
            bitsPerColor: 8,
            sdrWhiteNits: 280,
          ),
        ),
        1,
      );
      expect(
        hdrGraphicsWhiteScale(
          outputActive: true,
          display: const HdrDisplayInfo(
            colorSpace: kDxgiColorSpaceHdr10,
            maxLuminance: 1000,
            bitsPerColor: 10,
          ),
        ),
        1,
      );
    });

    test('SDR 白低于 203：界面无法更亮，取 1', () {
      expect(
        hdrGraphicsWhiteScale(
          outputActive: true,
          display: const HdrDisplayInfo(
            colorSpace: kDxgiColorSpaceHdr10,
            maxLuminance: 1000,
            bitsPerColor: 10,
            sdrWhiteNits: 120,
          ),
        ),
        1,
      );
    });

    test('编码域乘数 = sRGB OETF(线性系数)：白经 sRGB EOTF 解回恰为该系数', () {
      double eotf(double v) =>
          v <= 0.04045 ? v / 12.92 : _pow((v + 0.055) / 1.055, 2.4);
      for (final double k in <double>[0.725, 0.5, 0.2, 0.002]) {
        expect(eotf(hdrGraphicsEncodedGain(k)), closeTo(k, 1e-9), reason: '$k');
      }
      expect(hdrGraphicsEncodedGain(1), 1);
      expect(hdrGraphicsEncodedGain(1.4), 1);
    });

    testWidgets('系数 < 1 才套 ColorFiltered；进出 HDR 输出子树 State 不重建', (
      WidgetTester tester,
    ) async {
      Widget host(double scale) => Directionality(
        textDirection: TextDirection.ltr,
        child: HdrGraphicsWhiteLevel(
          linearScale: scale,
          child: const _StatefulProbe(),
        ),
      );
      await tester.pumpWidget(host(1));
      expect(find.byType(ColorFiltered), findsNothing);
      final State probe = tester.state(find.byType(_StatefulProbe));

      await tester.pumpWidget(host(203 / 280));
      expect(find.byType(ColorFiltered), findsOneWidget);
      expect(tester.state(find.byType(_StatefulProbe)), same(probe));

      await tester.pumpWidget(host(1));
      expect(find.byType(ColorFiltered), findsNothing);
      expect(tester.state(find.byType(_StatefulProbe)), same(probe));
    });
  });

  group('HdrOutputChannel', () {
    const MethodChannel channel = MethodChannel('test/hdr_output');
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'compositorHdrSupported':
                return true;
              case 'setCompositorHdrOutput':
                return (call.arguments as Map<Object?, Object?>)['enabled'];
              case 'displayInfo':
                return <String, Object?>{
                  'valid': true,
                  'colorSpace': 12,
                  'maxLuminance': 1015.0,
                  'bitsPerColor': 10,
                  'sdrWhiteNits': 280.0,
                };
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('displayInfo 解出色彩空间 / 峰值 / 位深 / SDR 白', () async {
      final HdrOutputChannel host = HdrOutputChannel(
        channel: channel,
        isWindows: true,
      );
      final HdrDisplayInfo info = await host.displayInfo();
      expect(info.isHdr, isTrue);
      expect(info.maxLuminance, 1015.0);
      expect(info.bitsPerColor, 10);
      expect(info.sdrWhiteNits, 280.0);
      expect(calls.map((MethodCall c) => c.method).toList(), <String>[
        'displayInfo',
      ]);
    });

    test('合成器内 HDR：能力查询与开关透传参数、回传引擎结果', () async {
      final HdrOutputChannel host = HdrOutputChannel(
        channel: channel,
        isWindows: true,
      );
      expect(await host.compositorHdrSupported(), isTrue);
      expect(
        await host.setCompositorHdrOutput(enabled: true, sdrWhiteNits: 280),
        isTrue,
      );
      expect(
        await host.setCompositorHdrOutput(enabled: false, sdrWhiteNits: 80),
        isFalse,
      );
      expect(calls.map((MethodCall c) => c.method).toList(), <String>[
        'compositorHdrSupported',
        'setCompositorHdrOutput',
        'setCompositorHdrOutput',
      ]);
      expect(calls[1].arguments, <String, Object>{
        'enabled': true,
        'sdrWhiteNits': 280.0,
      });
    });

    test('原版引擎 / 旧 runner（无此方法）报不支持，不抛', () async {
      const MethodChannel bare = MethodChannel('test/hdr_output_bare');
      final HdrOutputChannel host = HdrOutputChannel(
        channel: bare,
        isWindows: true,
      );
      expect(await host.compositorHdrSupported(), isFalse);
      expect(
        await host.setCompositorHdrOutput(enabled: true, sdrWhiteNits: 280),
        isFalse,
      );
    });

    test('非 Windows 全部 no-op：不碰通道', () async {
      final HdrOutputChannel host = HdrOutputChannel(
        channel: channel,
        isWindows: false,
      );
      expect((await host.displayInfo()).isHdr, isFalse);
      expect(await host.compositorHdrSupported(), isFalse);
      expect(
        await host.setCompositorHdrOutput(enabled: true, sdrWhiteNits: 280),
        isFalse,
      );
      expect(calls, isEmpty);
    });

    test('runner 推 onDisplayChanged 触发回调', () async {
      final HdrOutputChannel host = HdrOutputChannel(
        channel: channel,
        isWindows: true,
      );
      int fired = 0;
      host.onDisplayChanged = () => fired++;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              const MethodCall('onDisplayChanged'),
            ),
            (_) {},
          );
      expect(fired, 1);
    });
  });
}

double _pow(double base, double exponent) =>
    math.pow(base, exponent).toDouble();

class _StatefulProbe extends StatefulWidget {
  const _StatefulProbe();

  @override
  State<_StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<_StatefulProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';
import 'package:fushi/src/models/preferences_repository.dart' show VideoFitMode;

/// Windows HDR 直通 / 10-bit 输出（`video_hdr_output.dart`）。
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

  group('shouldUseHdrHostWindow（唯一判据）', () {
    test('非 Windows 恒 false，哪怕 always', () {
      for (final VideoHdrOutputMode m in VideoHdrOutputMode.values) {
        expect(
          shouldUseHdrHostWindow(
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
        shouldUseHdrHostWindow(
          isWindows: true,
          mode: VideoHdrOutputMode.off,
          displayHdr: true,
          sourceHdr: true,
        ),
        isFalse,
      );
    });

    test('always 在 Windows 恒 true（SDR 片 / SDR 屏也走 10-bit 宿主窗）', () {
      expect(
        shouldUseHdrHostWindow(
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
            shouldUseHdrHostWindow(
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

    // BUG-2691：DV Profile 5（IPTPQc2）只有 gpu-next 会做 RPU 重整，纹理路径出紫绿
    // 反色；auto 下不论显示器是否 HDR 都得进宿主窗。
    test('auto + Dolby Vision P5：SDR 屏也进宿主窗', () {
      for (final bool d in <bool>[false, true]) {
        expect(
          shouldUseHdrHostWindow(
            isWindows: true,
            mode: VideoHdrOutputMode.auto,
            displayHdr: d,
            sourceHdr: true,
            sourceDolbyVision: true,
          ),
          isTrue,
          reason: 'display=$d',
        );
      }
    });

    test('Dolby Vision P5：off 仍尊重用户、非 Windows 仍不进', () {
      expect(
        shouldUseHdrHostWindow(
          isWindows: true,
          mode: VideoHdrOutputMode.off,
          displayHdr: false,
          sourceHdr: true,
          sourceDolbyVision: true,
        ),
        isFalse,
      );
      expect(
        shouldUseHdrHostWindow(
          isWindows: false,
          mode: VideoHdrOutputMode.auto,
          displayHdr: false,
          sourceHdr: true,
          sourceDolbyVision: true,
        ),
        isFalse,
      );
    });
  });

  // BUG-2691 办法 4：没有 gpu-next 可切时提示用户，而不是让人以为片子坏了。
  group('dolbyVisionColorsUnsupported', () {
    test('非 DV 片源恒 false', () {
      for (final bool w in <bool>[false, true]) {
        for (final VideoHdrOutputMode m in VideoHdrOutputMode.values) {
          expect(
            dolbyVisionColorsUnsupported(
              isWindows: w,
              mode: m,
              sourceDolbyVision: false,
            ),
            isFalse,
            reason: 'windows=$w mode=${m.name}',
          );
        }
      }
    });

    test('Linux（系统 libmpv，无补丁）：任何模式都提示', () {
      for (final VideoHdrOutputMode m in VideoHdrOutputMode.values) {
        expect(
          dolbyVisionColorsUnsupported(
            isWindows: false,
            mode: m,
            sourceDolbyVision: true,
          ),
          isTrue,
          reason: m.name,
        );
      }
    });

    test('macOS / iOS / Android：随包 gl_video 自带重整，任何模式都不提示', () {
      for (final VideoHdrOutputMode m in VideoHdrOutputMode.values) {
        expect(
          dolbyVisionColorsUnsupported(
            isWindows: false,
            isApple: true,
            mode: m,
            sourceDolbyVision: true,
          ),
          isFalse,
          reason: 'apple ${m.name}',
        );
        expect(
          dolbyVisionColorsUnsupported(
            isWindows: false,
            isAndroid: true,
            mode: m,
            sourceDolbyVision: true,
          ),
          isFalse,
          reason: 'android ${m.name}',
        );
      }
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

    test('Windows：只有用户关了 HDR 输出才提示', () {
      expect(
        dolbyVisionColorsUnsupported(
          isWindows: true,
          mode: VideoHdrOutputMode.off,
          sourceDolbyVision: true,
        ),
        isTrue,
      );
      for (final VideoHdrOutputMode m in <VideoHdrOutputMode>[
        VideoHdrOutputMode.auto,
        VideoHdrOutputMode.always,
      ]) {
        expect(
          dolbyVisionColorsUnsupported(
            isWindows: true,
            mode: m,
            sourceDolbyVision: true,
          ),
          isFalse,
          reason: m.name,
        );
      }
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
    final int end = src.indexOf('\n  }\n', start);
    final String body = src.substring(start, end);
    expect(body, contains('_videoHdrOutputMode = appModel.videoHdrOutputMode'));
    expect(body, contains('_videoFitMode = appModel.videoFitMode'));
  });

  group('requiresDolbyVisionReshape', () {
    test('只认 mpv colormatrix=dolbyvision（P5 IPTPQc2）', () {
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

  group('mpv 属性', () {
    test('宿主窗属性：wid / gpu-context / 输出格式先下发，vo 恒最后', () {
      final Map<String, String> props = hdrHostMpvProperties(0x1234);
      expect(props.keys.last, 'vo');
      expect(props['vo'], 'gpu-next');
      expect(props['gpu-context'], 'd3d11');
      expect(props['wid'], '4660');
      expect(props['d3d11-output-format'], 'rgb10_a2');
      expect(props['target-colorspace-hint'], 'auto');
    });

    test('退回纹理路径只切 vo=libmpv', () {
      expect(kTextureMpvProperties, <String, String>{'vo': 'libmpv'});
    });

    test('fit 三态映射到 keepaspect / panscan', () {
      expect(hdrHostFitProperties(VideoFitMode.contain), <String, String>{
        'keepaspect': 'yes',
        'panscan': '0',
      });
      expect(hdrHostFitProperties(VideoFitMode.cover), <String, String>{
        'keepaspect': 'yes',
        'panscan': '1',
      });
      expect(hdrHostFitProperties(VideoFitMode.fill), <String, String>{
        'keepaspect': 'no',
        'panscan': '0',
      });
    });
  });

  group('HdrVideoHostChannel', () {
    const MethodChannel channel = MethodChannel('test/hdr_video_host');
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'create':
                return 0xABCD;
              case 'displayInfo':
                return <String, Object?>{
                  'valid': true,
                  'colorSpace': 12,
                  'maxLuminance': 1015.0,
                  'bitsPerColor': 10,
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

    test('create / setRect（四舍五入成整数像素）/ destroy / displayInfo', () async {
      final HdrVideoHostChannel host = HdrVideoHostChannel(
        channel: channel,
        isWindows: true,
      );
      expect(await host.create(), 0xABCD);
      await host.setRect(const Rect.fromLTWH(10.4, 20.6, 300.2, 199.5));
      final HdrDisplayInfo info = await host.displayInfo();
      expect(info.isHdr, isTrue);
      expect(info.maxLuminance, 1015.0);
      expect(info.bitsPerColor, 10);
      await host.destroy();
      expect(calls.map((MethodCall c) => c.method).toList(), <String>[
        'create',
        'setRect',
        'displayInfo',
        'destroy',
      ]);
      expect(calls[1].arguments, <String, int>{
        'x': 10,
        'y': 21,
        'width': 300,
        'height': 200,
      });
    });

    test('非 Windows 全部 no-op：不碰通道，create 返回 0', () async {
      final HdrVideoHostChannel host = HdrVideoHostChannel(
        channel: channel,
        isWindows: false,
      );
      expect(await host.create(), 0);
      await host.setRect(Rect.zero);
      await host.destroy();
      expect((await host.displayInfo()).isHdr, isFalse);
      expect(calls, isEmpty);
    });

    test('runner 推 onDisplayChanged 触发回调', () async {
      final HdrVideoHostChannel host = HdrVideoHostChannel(
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

  group('HdrHostRectReporter', () {
    testWidgets('按 devicePixelRatio 回报物理像素矩形，只在变化时回调', (tester) async {
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      final List<Rect> reported = <Rect>[];
      Widget build(double left) => Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: left,
              top: 30,
              width: 200,
              height: 100,
              child: HdrHostRectReporter(
                onRect: reported.add,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(build(10));
      await tester.pump();
      expect(reported, <Rect>[const Rect.fromLTWH(20, 60, 400, 200)]);
      // 同一矩形再画一次：不重复回调。
      await tester.pumpWidget(build(10));
      await tester.pump();
      expect(reported.length, 1);
      // 位置变了：回报一次新矩形。
      await tester.pumpWidget(build(50));
      await tester.pump();
      expect(reported.last, const Rect.fromLTWH(100, 60, 400, 200));
      expect(reported.length, 2);
    });
  });
}

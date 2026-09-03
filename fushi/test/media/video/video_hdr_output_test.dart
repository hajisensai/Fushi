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

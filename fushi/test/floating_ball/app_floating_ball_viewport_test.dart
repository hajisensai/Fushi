import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';

/// iPhone 17 Pro 模拟器横屏实测：左右安全区对称，各是灵动岛的深度。
const Size _iosLandscape = Size(869, 399.7);
const EdgeInsets _iosLandscapeInsets = EdgeInsets.fromLTRB(61.6, 0, 61.6, 19.9);

ReaderFloatingBallLayout _layout(Rect viewport, ReaderFloatingBallDock dock) =>
    ReaderFloatingBallLayout(
      viewport: viewport,
      dock: dock,
      verticalFraction: 0.5,
      actionCount: 3,
    );

/// 去掉 `//` 注释后的 Swift 源码：结构断言不能被注释里的同名字样骗过。
String _swiftCode(String path) => File(path)
    .readAsLinesSync()
    .map((String line) => line.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BUG-2911 appFloatingBallViewport', () {
    test('iOS 横屏：灵动岛在左时，右停靠的收起球外缩贴住屏幕右缘', () {
      final Rect viewport = appFloatingBallViewport(
        _iosLandscape,
        _iosLandscapeInsets,
        sensorHousingEdge: AxisDirection.left,
      );
      expect(viewport.left, 61.6);
      expect(viewport.right, _iosLandscape.width);
      final ReaderFloatingBallLayout layout = _layout(
        viewport,
        ReaderFloatingBallDock.right,
      );
      // 收起态球有一截缩在屏幕外 = 贴边；修复前停在离右缘 61.6 的黑边中间。
      expect(
        layout.collapsedBallLeft + layout.ballSize,
        greaterThan(_iosLandscape.width),
      );
    });

    test('iOS 横屏：灵动岛在右时只避让右侧', () {
      final Rect viewport = appFloatingBallViewport(
        _iosLandscape,
        _iosLandscapeInsets,
        sensorHousingEdge: AxisDirection.right,
      );
      expect(viewport.left, 0);
      expect(viewport.right, _iosLandscape.width - 61.6);
      expect(
        _layout(viewport, ReaderFloatingBallDock.left).collapsedBallLeft,
        lessThan(0),
      );
    });

    test('外壳方向未知（非 iOS / 原生没回话）：两侧照旧都避让', () {
      expect(
        appFloatingBallViewport(_iosLandscape, _iosLandscapeInsets),
        const Rect.fromLTRB(61.6, 0, 869 - 61.6, 399.7 - 19.9),
      );
    });

    test('竖 → 横那一帧外壳边还是旧的 up：两侧照旧都避让，不会错贴', () {
      expect(
        appFloatingBallViewport(
          _iosLandscape,
          _iosLandscapeInsets,
          sensorHousingEdge: AxisDirection.up,
        ),
        const Rect.fromLTRB(61.6, 0, 869 - 61.6, 399.7 - 19.9),
      );
    });
  });

  group('BUG-2911 FloatingBallChannel 外壳边', () {
    final List<MethodCall> calls = <MethodCall>[];
    Object? reply;

    setUp(() {
      calls.clear();
      reply = null;
      debugSensorHousingEdgePlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FloatingBallChannel.channel, (
            MethodCall call,
          ) async {
            calls.add(call);
            return call.method == 'sensorHousingEdge' ? reply : null;
          });
    });

    tearDown(() {
      debugSensorHousingEdgePlatformOverride = null;
      FloatingBallChannel.debugResetHandler();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FloatingBallChannel.channel, null);
    });

    test('查询：原生字符串 → AxisDirection，未知值与 null 都当不知道', () async {
      const Map<Object?, AxisDirection?> cases = <Object?, AxisDirection?>{
        'left': AxisDirection.left,
        'right': AxisDirection.right,
        'top': AxisDirection.up,
        'bottom': AxisDirection.down,
        null: null,
        'diagonal': null,
        42: null,
      };
      for (final MapEntry<Object?, AxisDirection?> c in cases.entries) {
        reply = c.key;
        expect(
          await FloatingBallChannel.sensorHousingEdge(),
          c.value,
          reason: 'wire=${c.key}',
        );
      }
      expect(calls.map((MethodCall c) => c.method).toSet(), <String>{
        'sensorHousingEdge',
      });
    });

    test('不上报外壳边的平台不打扰原生，直接 null', () async {
      debugSensorHousingEdgePlatformOverride = false;
      reply = 'left';
      expect(await FloatingBallChannel.sensorHousingEdge(), isNull);
      expect(calls, isEmpty);
    });

    test('推送 sensorHousingEdgeChanged 经 installHandler 回调，参数同一套映射', () async {
      final List<AxisDirection?> pushed = <AxisDirection?>[];
      await FloatingBallChannel.installHandler(
        onLookup: (_) {},
        onScreenOcrFinished: () {},
        onSensorHousingEdgeChanged: pushed.add,
      );
      for (final Object? wire in <Object?>['right', 'left', null, 'bogus']) {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              FloatingBallChannel.channel.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('sensorHousingEdgeChanged', wire),
              ),
              (_) {},
            );
      }
      expect(pushed, <AxisDirection?>[
        AxisDirection.right,
        AxisDirection.left,
        null,
        null,
      ]);
    });
  });

  test('iOS 原生在界面方向变化时主动推外壳边，并按界面方向换算', () {
    // 横屏左 ↔ 右翻转不改窗口尺寸与对称安全区，Dart 侧没有可靠的重查时机：
    // 必须由 scene 的界面方向回调推给 Dart。钉住这条链的结构，而不是某行写法。
    final String scene = _swiftCode('ios/Runner/SceneDelegate.swift');
    final RegExpMatch? callback = RegExp(
      r'override func windowScene\(\s*_ windowScene: UIWindowScene,\s*'
      r'didUpdate previousCoordinateSpace: UICoordinateSpace,\s*'
      r'interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,'
      r'[\s\S]*?\n  \}',
    ).firstMatch(scene);
    expect(callback, isNotNull, reason: 'SceneDelegate 必须实现界面方向回调');
    expect(
      callback![0],
      contains(
        'FushiFloatingBall.interfaceOrientationDidChange('
        'windowScene.interfaceOrientation)',
      ),
    );
    // FlutterSceneDelegate 只声明遵守 UIWindowSceneDelegate，并没有实现这条可选
    // 回调；调 super 是向不存在的实现发消息，建 scene 时 unrecognized selector
    // 直接 abort（2.9.0 TestFlight 打开即闪退）。编译器不拦，只能在这里钉死。
    expect(callback[0], isNot(contains('super.')));

    final String ball = _swiftCode('ios/Runner/FushiFloatingBall.swift');
    final RegExpMatch? push = RegExp(
      r'static func interfaceOrientationDidChange\([\s\S]*?\n  \}',
    ).firstMatch(ball);
    expect(push, isNotNull);
    expect(push![0], contains('"sensorHousingEdgeChanged"'));
    expect(push[0], contains('sensorHousingEdge(for: orientation)'));
    // 查询与推送走同一个换算。
    expect(
      ball,
      contains('return sensorHousingEdge(for: scene.interfaceOrientation)'),
    );
    expect(ball, contains('case .landscapeRight: return "left"'));
    expect(ball, contains('case .landscapeLeft: return "right"'));
  });
}

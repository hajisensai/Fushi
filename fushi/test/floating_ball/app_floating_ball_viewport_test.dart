import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
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

void main() {
  group('BUG-2894 appFloatingBallViewport', () {
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

    test('竖屏外壳在顶：上下 inset 不动，左右本就为 0', () {
      const EdgeInsets portrait = EdgeInsets.fromLTRB(0, 62, 0, 34);
      expect(
        appFloatingBallViewport(
          const Size(402, 874),
          portrait,
          sensorHousingEdge: AxisDirection.up,
        ),
        const Rect.fromLTRB(0, 62, 402, 874 - 34),
      );
    });

    test('Android shortEdges 的单侧 inset 原样保留', () {
      const EdgeInsets cutoutLeft = EdgeInsets.fromLTRB(32, 0, 0, 0);
      expect(
        appFloatingBallViewport(const Size(800, 360), cutoutLeft),
        const Rect.fromLTRB(32, 0, 800, 360),
      );
    });

    test('iOS 原生按界面方向换算外壳所在边', () {
      final String swift = File(
        'ios/Runner/FushiFloatingBall.swift',
      ).readAsStringSync();
      expect(swift, contains('case "sensorHousingEdge":'));
      expect(swift, contains('case .landscapeRight: return "left"'));
      expect(swift, contains('case .landscapeLeft: return "right"'));
    });
  });
}

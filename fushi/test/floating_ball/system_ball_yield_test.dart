import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';

/// 生命周期 → 应用外球让不让位（隐藏）。群反馈：Fushi 在前台时应用内、应用外
/// 两颗球并排出现。
void main() {
  bool yields({
    bool inApp = true,
    AppLifecycleState lifecycle = AppLifecycleState.resumed,
    bool mobileForeground = true,
    bool desktop = false,
    bool pip = false,
  }) => floatingBallSystemBallYieldsToInApp(
    inAppBallEnabled: inApp,
    lifecycle: lifecycle,
    mobileForeground: mobileForeground,
    desktop: desktop,
    inPictureInPicture: pip,
  );

  group('桌面：只认 resumed', () {
    test('resumed 让位，其余（失焦 inactive / 最小化 hidden / paused）露面', () {
      for (final AppLifecycleState state in AppLifecycleState.values) {
        expect(
          yields(desktop: true, lifecycle: state),
          state == AppLifecycleState.resumed,
          reason: '$state',
        );
      }
    });

    test('Android 的「在前台」判定不参与桌面', () {
      expect(
        yields(
          desktop: true,
          lifecycle: AppLifecycleState.inactive,
          mobileForeground: true,
        ),
        isFalse,
      );
    });
  });

  group('Android：按宿主维持的「在前台」', () {
    test('在前台让位、在后台露面', () {
      expect(yields(), isTrue);
      expect(yields(mobileForeground: false), isFalse);
    });

    test('inactive（通知栏 / 系统对话框 / 分屏）沿用原判，不闪', () {
      expect(
        yields(lifecycle: AppLifecycleState.inactive, mobileForeground: true),
        isTrue,
      );
      expect(
        yields(lifecycle: AppLifecycleState.inactive, mobileForeground: false),
        isFalse,
      );
    });

    test('画中画：Fushi 只剩小窗，露面', () {
      expect(yields(pip: true), isFalse);
      expect(yields(pip: true, lifecycle: AppLifecycleState.inactive), isFalse);
    });
  });

  test('应用内球关着：任何平台、任何状态都不让位', () {
    for (final bool desktop in <bool>[false, true]) {
      for (final AppLifecycleState state in AppLifecycleState.values) {
        expect(
          yields(inApp: false, desktop: desktop, lifecycle: state),
          isFalse,
          reason: 'desktop=$desktop $state',
        );
      }
    }
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_mode.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

ReaderHeaderAction _action(String label, {IconData icon = Icons.add}) =>
    ReaderHeaderAction(icon: icon, label: label, onPressed: () {});

void main() {
  group('FloatingBallMode', () {
    test('未知 / 空值回退到关闭', () {
      expect(FloatingBallMode.fromStorage(''), FloatingBallMode.off);
      expect(FloatingBallMode.fromStorage('bogus'), FloatingBallMode.off);
      expect(FloatingBallMode.fromStorage('system'), FloatingBallMode.system);
    });

    test('系统常驻只在 Android 可选，别处按应用内处理', () {
      expect(FloatingBallMode.availableOn(isAndroid: false), <FloatingBallMode>[
        FloatingBallMode.off,
        FloatingBallMode.inApp,
      ]);
      expect(
        FloatingBallMode.availableOn(isAndroid: true),
        FloatingBallMode.values,
      );
      expect(
        FloatingBallMode.system.effectiveOn(isAndroid: false),
        FloatingBallMode.inApp,
      );
      expect(
        FloatingBallMode.system.effectiveOn(isAndroid: true),
        FloatingBallMode.system,
      );
      expect(FloatingBallMode.off.showsInAppBall, isFalse);
      expect(FloatingBallMode.system.showsInAppBall, isTrue);
    });
  });

  group('FloatingBallGlobalAction 列表编解码', () {
    test('从没设过 = 全开；全关存成 - 且读回为空', () {
      expect(
        FloatingBallGlobalAction.decodeList(''),
        FloatingBallGlobalAction.values,
      );
      final String none = FloatingBallGlobalAction.encodeList(
        const <FloatingBallGlobalAction>[],
      );
      expect(none, '-');
      expect(FloatingBallGlobalAction.decodeList(none), isEmpty);
    });

    test('保持枚举顺序、丢掉未知值', () {
      expect(
        FloatingBallGlobalAction.decodeList('screen_ocr, nope ,lookup'),
        <FloatingBallGlobalAction>[
          FloatingBallGlobalAction.lookup,
          FloatingBallGlobalAction.screenOcr,
        ],
      );
      expect(
        FloatingBallGlobalAction.encodeList(<FloatingBallGlobalAction>[
          FloatingBallGlobalAction.screenOcr,
          FloatingBallGlobalAction.lookup,
        ]),
        'lookup,screen_ocr',
      );
    });

    test('截屏识字只在 Android / iOS 提供', () {
      const FloatingBallGlobalAction ocr = FloatingBallGlobalAction.screenOcr;
      expect(ocr.availableOn(isAndroid: true, isIOS: false), isTrue);
      expect(ocr.availableOn(isAndroid: false, isIOS: true), isTrue);
      expect(ocr.availableOn(isAndroid: false, isIOS: false), isFalse);
      expect(
        FloatingBallGlobalAction.lookup.availableOn(
          isAndroid: false,
          isIOS: false,
        ),
        isTrue,
      );
    });
  });

  group('screenOcrHitTest', () {
    const SystemOcrTextLine horizontal = SystemOcrTextLine(
      text: '今日は晴れ',
      rect: Rect.fromLTWH(100, 200, 500, 100),
      isVertical: false,
    );
    const SystemOcrTextLine vertical = SystemOcrTextLine(
      text: '吾輩は猫',
      rect: Rect.fromLTWH(800, 100, 100, 400),
      isVertical: true,
    );

    test('横排按宽度等分定位到字，并换算到逻辑像素', () {
      // scale 0.5：截图是 2x 物理像素。行在逻辑坐标 (50,100)-(300,150)，每字 50。
      final ScreenOcrHit? hit = screenOcrHitTest(
        lines: const <SystemOcrTextLine>[horizontal, vertical],
        point: const Offset(180, 120),
        scale: 0.5,
      );
      expect(hit, isNotNull);
      expect(hit!.line, same(horizontal));
      expect(hit.charIndex, 2); // は
      expect(hit.charRect, const Rect.fromLTWH(150, 100, 50, 50));
      expect(hit.lineRect, const Rect.fromLTWH(50, 100, 250, 50));
    });

    test('竖排按高度等分', () {
      final ScreenOcrHit? hit = screenOcrHitTest(
        lines: const <SystemOcrTextLine>[horizontal, vertical],
        point: const Offset(420, 240),
        scale: 0.5,
      );
      expect(hit!.line, same(vertical));
      // 竖排逻辑高 200、4 字各 50：y=240 落在第 4 个字（index 3）。
      expect(hit.charIndex, 3);
    });

    test('代理对按字素计数，返回的是 UTF-16 下标', () {
      const SystemOcrTextLine emoji = SystemOcrTextLine(
        text: '𠮷野家',
        rect: Rect.fromLTWH(0, 0, 300, 100),
        isVertical: false,
      );
      final ScreenOcrHit? hit = screenOcrHitTest(
        lines: const <SystemOcrTextLine>[emoji],
        point: const Offset(150, 50),
        scale: 1,
      );
      // 第二个字素「野」，前面的「𠮷」占两个码元。
      expect(hit!.charIndex, 2);
    });

    test('点在所有行外返回 null', () {
      expect(
        screenOcrHitTest(
          lines: const <SystemOcrTextLine>[horizontal],
          point: const Offset(5, 5),
          scale: 0.5,
        ),
        isNull,
      );
    });
  });

  group('FloatingBallSceneRegistry', () {
    setUp(FloatingBallSceneRegistry.instance.debugReset);

    testWidgets('只取当前路由上的场景，被盖住的页面不出按钮', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      final FloatingBallSceneRegistry registry =
          FloatingBallSceneRegistry.instance;
      int notifications = 0;
      void listener() => notifications++;
      registry.addListener(listener);
      addTearDown(() => registry.removeListener(listener));

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: <NavigatorObserver>[floatingBallRouteObserver],
          home: FloatingBallScene(actions: <ReaderHeaderAction>[_action('a')]),
        ),
      );
      await tester.pump();
      expect(registry.current.actions.map((a) => a.label), <String>['a']);
      expect(notifications, greaterThan(0));

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox()),
      );
      await tester.pumpAndSettle();
      // 新页没有场景：底下那页还挂着，但不是当前路由。
      expect(registry.current.actions, isEmpty);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(registry.current.actions.map((a) => a.label), <String>['a']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(registry.current.actions, isEmpty);
    });

    test('sameFloatingBallActions 只比外观不比闭包', () {
      expect(
        sameFloatingBallActions(
          <ReaderHeaderAction>[_action('a')],
          <ReaderHeaderAction>[_action('a')],
        ),
        isTrue,
      );
      expect(
        sameFloatingBallActions(
          <ReaderHeaderAction>[_action('a', icon: Icons.play_arrow)],
          <ReaderHeaderAction>[_action('a', icon: Icons.pause)],
        ),
        isFalse,
      );
      expect(
        sameFloatingBallActions(
          <ReaderHeaderAction>[_action('a')],
          const <ReaderHeaderAction>[
            ReaderHeaderAction(icon: Icons.add, label: 'a', onPressed: null),
          ],
        ),
        isFalse,
      );
    });
  });
}

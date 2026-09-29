import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi_core/fushi_core.dart';

ReaderHeaderAction _action(String label, {IconData icon = Icons.add}) =>
    ReaderHeaderAction(icon: icon, label: label, onPressed: () {});

const List<String> _globals = <String>['lookup', 'clipboard', 'screen_ocr'];

void main() {
  group('FloatingBallScope', () {
    test('应用外只在 Android 可配', () {
      expect(
        FloatingBallScope.availableOn(isAndroid: false),
        isNot(contains(FloatingBallScope.system)),
      );
      expect(
        FloatingBallScope.availableOn(isAndroid: true),
        FloatingBallScope.values,
      );
    });

    test('出厂按钮：阅读器三颗有声书传输键，漫画 / 视频全部专属按钮，都带全局按钮', () {
      expect(FloatingBallScope.reader.defaultButtons, <String>[
        ReaderControlItem.audiobookPrev.storageValue,
        ReaderControlItem.audiobookPlayPause.storageValue,
        ReaderControlItem.audiobookNext.storageValue,
        ..._globals,
      ]);
      expect(FloatingBallScope.video.defaultButtons, <String>[
        ...kVideoFloatingBallButtons,
        ..._globals,
      ]);
      expect(FloatingBallScope.manga.defaultButtons, <String>[
        ...kMangaFloatingBallButtons,
        ..._globals,
      ]);
      expect(FloatingBallScope.general.defaultButtons, _globals);
      expect(FloatingBallScope.system.defaultButtons, _globals);
    });

    test('阅读器目录是按钮布局里除书名外的全部按钮', () {
      expect(
        FloatingBallScope.reader.sceneButtonIds,
        isNot(contains(ReaderControlItem.title.storageValue)),
      );
      expect(
        FloatingBallScope.reader.sceneButtonIds,
        hasLength(ReaderControlItem.values.length - 1),
      );
    });

    test('目录里的 id 在同一场景内不重复', () {
      for (final FloatingBallScope scope in FloatingBallScope.values) {
        expect(scope.catalog.toSet(), hasLength(scope.catalog.length));
      }
    });

    test('从没设过 = 出厂；全关存成 - 且读回为空', () {
      const FloatingBallScope scope = FloatingBallScope.video;
      expect(scope.decodeButtons(''), scope.defaultButtons);
      final String none = scope.encodeButtons(const <String>[]);
      expect(none, '-');
      expect(scope.decodeButtons(none), isEmpty);
    });

    test('保持目录顺序、丢掉未知值与别的场景的 id', () {
      const FloatingBallScope scope = FloatingBallScope.video;
      expect(scope.decodeButtons('lookup, nope ,favorite,chapters'), <String>[
        'favorite',
        'lookup',
      ]);
      expect(
        scope.encodeButtons(<String>['screen_ocr', 'play_pause']),
        'play_pause,screen_ocr',
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

  group('悬浮球偏好', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() => db.close());

    test('出厂：应用内开、应用外关', () {
      expect(prefs.floatingBallInApp, isTrue);
      expect(prefs.floatingBallSystem, isFalse);
    });

    test('开关与按钮勾选读写往返', () async {
      await prefs.setFloatingBallInApp(false);
      await prefs.setFloatingBallSystem(true);
      await prefs.setFloatingBallButtons(FloatingBallScope.reader, <String>[
        'lookup',
        ReaderControlItem.navigation.storageValue,
      ]);
      expect(prefs.floatingBallInApp, isFalse);
      expect(prefs.floatingBallSystem, isTrue);
      expect(prefs.floatingBallButtons(FloatingBallScope.reader), <String>[
        ReaderControlItem.navigation.storageValue,
        'lookup',
      ]);
      // 别的场景不受影响。
      expect(
        prefs.floatingBallButtons(FloatingBallScope.video),
        FloatingBallScope.video.defaultButtons,
      );
    });

    test('旧版三态模式迁移：显式关 → 应用内关；系统常驻 → 两个都开', () async {
      await prefs.setPref('floating_ball.mode', 'off');
      expect(prefs.floatingBallInApp, isFalse);
      expect(prefs.floatingBallSystem, isFalse);
      await prefs.setPref('floating_ball.mode', 'system');
      expect(prefs.floatingBallInApp, isTrue);
      expect(prefs.floatingBallSystem, isTrue);
      // 新开关一旦写过就以新开关为准。
      await prefs.setFloatingBallSystem(false);
      expect(prefs.floatingBallSystem, isFalse);
    });

    test('旧版全局按钮勾选迁移到没单独设过的场景', () async {
      await prefs.setPref('floating_ball.actions', 'clipboard');
      expect(prefs.floatingBallButtons(FloatingBallScope.video), <String>[
        ...kVideoFloatingBallButtons,
        'clipboard',
      ]);
      await prefs.setPref('floating_ball.actions', '-');
      expect(prefs.floatingBallButtons(FloatingBallScope.general), isEmpty);
      // 单独设过的场景以自己的为准。
      await prefs.setFloatingBallButtons(FloatingBallScope.general, <String>[
        'lookup',
      ]);
      expect(prefs.floatingBallButtons(FloatingBallScope.general), <String>[
        'lookup',
      ]);
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
          home: FloatingBallScene(
            scope: FloatingBallScope.video,
            actions: <String, ReaderHeaderAction>{'a': _action('a')},
          ),
        ),
      );
      await tester.pump();
      expect(registry.current.actions.keys, <String>['a']);
      expect(registry.current.scope, FloatingBallScope.video);
      expect(notifications, greaterThan(0));

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const SizedBox()),
      );
      await tester.pumpAndSettle();
      // 新页没有场景：底下那页还挂着，但不是当前路由；按「其它页面」配置。
      expect(registry.current.actions, isEmpty);
      expect(registry.current.scope, FloatingBallScope.general);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(registry.current.actions.keys, <String>['a']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(registry.current.actions, isEmpty);
    });

    test('sameFloatingBallActions 只比外观不比闭包', () {
      expect(
        sameFloatingBallActions(
          <String, ReaderHeaderAction>{'a': _action('a')},
          <String, ReaderHeaderAction>{'a': _action('a')},
        ),
        isTrue,
      );
      expect(
        sameFloatingBallActions(
          <String, ReaderHeaderAction>{
            'a': _action('a', icon: Icons.play_arrow),
          },
          <String, ReaderHeaderAction>{'a': _action('a', icon: Icons.pause)},
        ),
        isFalse,
      );
      expect(
        sameFloatingBallActions(
          <String, ReaderHeaderAction>{'a': _action('a')},
          const <String, ReaderHeaderAction>{
            'a': ReaderHeaderAction(
              icon: Icons.add,
              label: 'a',
              onPressed: null,
            ),
          },
        ),
        isFalse,
      );
      // 同一颗按钮换了 id（登记到别的槽位）也算变化。
      expect(
        sameFloatingBallActions(
          <String, ReaderHeaderAction>{'a': _action('a')},
          <String, ReaderHeaderAction>{'b': _action('a')},
        ),
        isFalse,
      );
    });
  });
}

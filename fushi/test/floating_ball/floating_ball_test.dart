import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/floating_ball_config.dart';
import 'package:fushi/src/floating_ball/floating_ball_scene.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi_core/fushi_core.dart';

ReaderHeaderAction _action(String label, {IconData icon = Icons.add}) =>
    ReaderHeaderAction(icon: icon, label: label, onPressed: () {});

/// 出厂勾上的全局按钮（「立即同步」可勾选但出厂不勾）。
const List<String> _globals = <String>[
  'lookup',
  'popup_lookup',
  'clipboard',
  'screen_ocr',
  'camera_ocr',
  // 反馈出厂勾上；应用外球虽在目录里，但按能力过滤掉（availableIn）。
  'feedback',
];

void main() {
  group('FloatingBallScope', () {
    test('应用外只在 Android 与桌面（Windows / macOS）可配', () {
      expect(
        FloatingBallScope.availableOn(isAndroid: false),
        isNot(contains(FloatingBallScope.system)),
      );
      expect(
        FloatingBallScope.availableOn(isAndroid: true),
        FloatingBallScope.values,
      );
      expect(
        FloatingBallScope.availableOn(isAndroid: false, isDesktop: true),
        FloatingBallScope.values,
      );
    });

    test('桌面应用外球：查词 / 应用外查词（查选区）/ 剪贴板 / 截屏识字 / 同步，没有拍照', () {
      Set<FloatingBallGlobalAction> onDesktop(
        FloatingBallScope scope, {
        bool lookupModuleEnabled = true,
      }) => <FloatingBallGlobalAction>{
        for (final FloatingBallGlobalAction a
            in FloatingBallGlobalAction.values)
          if (a.availableIn(
            scope,
            isAndroid: false,
            isIOS: false,
            isDesktop: true,
            lookupModuleEnabled: lookupModuleEnabled,
          ))
            a,
      };
      expect(onDesktop(FloatingBallScope.system), <FloatingBallGlobalAction>{
        FloatingBallGlobalAction.lookup,
        FloatingBallGlobalAction.popupLookup,
        FloatingBallGlobalAction.clipboard,
        FloatingBallGlobalAction.screenOcr,
        FloatingBallGlobalAction.sync,
      });
      // 查词模块关着：打开查词页与全局查词（含截屏识字的结果卡）都没有入口，只剩
      // 剪贴板（它在覆盖窗不可用时退回主窗查词弹窗）与同步（与查词无关）。
      expect(
        onDesktop(FloatingBallScope.system, lookupModuleEnabled: false),
        <FloatingBallGlobalAction>{
          FloatingBallGlobalAction.clipboard,
          FloatingBallGlobalAction.sync,
        },
      );
      // 应用内的球仍按平台能力（桌面没有独立查词窗），与查词模块无关。
      for (final bool enabled in <bool>[true, false]) {
        expect(
          onDesktop(FloatingBallScope.general, lookupModuleEnabled: enabled),
          <FloatingBallGlobalAction>{
            FloatingBallGlobalAction.lookup,
            FloatingBallGlobalAction.clipboard,
            FloatingBallGlobalAction.sync,
            FloatingBallGlobalAction.feedback,
          },
        );
      }
      // Android 的应用外球不受影响。
      expect(
        FloatingBallGlobalAction.screenOcr.availableIn(
          FloatingBallScope.system,
          isAndroid: true,
          isIOS: false,
          isDesktop: false,
          lookupModuleEnabled: false,
        ),
        isTrue,
      );
    });

    test('出厂按钮：阅读器计时开关 + 三颗有声书传输键，漫画 / 视频全部专属按钮，都带全局按钮', () {
      expect(FloatingBallScope.reader.defaultButtons, <String>[
        ReaderControlItem.studyTimer.storageValue,
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

    test('立即同步：每个场景都能勾选，出厂不勾，勾上后编解码往返不丢', () {
      const String sync = 'sync';
      expect(
        FloatingBallGlobalAction.fromStorage(sync),
        FloatingBallGlobalAction.sync,
      );
      expect(FloatingBallGlobalAction.sync.onByDefault, isFalse);
      for (final FloatingBallScope scope in FloatingBallScope.values) {
        expect(scope.catalog, contains(sync), reason: scope.storageValue);
        expect(scope.defaultButtons, isNot(contains(sync)));
        final List<String> withSync = <String>[...scope.defaultButtons, sync];
        // 编解码按目录顺序排（sync 在 feedback 之前）。
        expect(scope.decodeButtons(scope.encodeButtons(withSync)), <String>[
          for (final String id in scope.catalog)
            if (withSync.contains(id)) id,
        ]);
      }
      // 同步与平台无关：Android / iOS / 桌面都有。
      for (final (bool android, bool ios) in <(bool, bool)>[
        (true, false),
        (false, true),
        (false, false),
      ]) {
        expect(
          FloatingBallGlobalAction.sync.availableOn(
            isAndroid: android,
            isIOS: ios,
          ),
          isTrue,
        );
      }
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

    test('阅读计时开关可在阅读器场景勾选 / 取消（出厂勾上，按目录序落在传输键之前）', () {
      const FloatingBallScope scope = FloatingBallScope.reader;
      final String timer = ReaderControlItem.studyTimer.storageValue;
      expect(scope.catalog, contains(timer));
      expect(scope.decodeButtons(''), contains(timer));
      // 用户取消勾选后读回不再含它，其余按钮不受影响。
      final List<String> without = <String>[
        for (final String id in scope.defaultButtons)
          if (id != timer) id,
      ];
      expect(scope.decodeButtons(scope.encodeButtons(without)), without);
      // 出厂列表本身就按目录序排好（decode 按目录序重排不改变它）。
      expect(
        scope.decodeButtons(scope.encodeButtons(scope.defaultButtons)),
        scope.defaultButtons,
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

    test('拍照查词只在 Android / iOS 提供（桌面没有相机入口）', () {
      const FloatingBallGlobalAction camera =
          FloatingBallGlobalAction.cameraOcr;
      expect(FloatingBallGlobalAction.fromStorage('camera_ocr'), camera);
      expect(camera.availableOn(isAndroid: true, isIOS: false), isTrue);
      expect(camera.availableOn(isAndroid: false, isIOS: true), isTrue);
      expect(camera.availableOn(isAndroid: false, isIOS: false), isFalse);
    });

    test('应用外场景可勾的全局按钮，原生系统球都认（id 两侧同名）', () {
      // 系统球的目录 = 全部全局按钮；原生 CONFIGURABLE_ACTIONS 漏了某个 id，
      // 设置里勾上它系统球却静默不出这颗按钮。
      final String service = File(
        'android/app/src/main/java/app/fushi/reader/FloatingBallService.java',
      ).readAsStringSync();
      final String configurable = RegExp(
        r'CONFIGURABLE_ACTIONS\s*=\s*Arrays\.asList\(([^;]*)\);',
      ).firstMatch(service)!.group(1)!;
      final Map<String, String> constants = <String, String>{
        for (final RegExpMatch m in RegExp(
          r'static final String (ACTION_\w+) = "([a-z_]+)";',
        ).allMatches(service))
          m.group(1)!: m.group(2)!,
      };
      final Set<String> nativeIds = <String>{
        for (final RegExpMatch m in RegExp(
          r'ACTION_\w+',
        ).allMatches(configurable))
          constants[m.group(0)!]!,
      };
      expect(nativeIds, <String>{
        for (final FloatingBallGlobalAction action
            in FloatingBallGlobalAction.values)
          if (action.availableIn(
            FloatingBallScope.system,
            isAndroid: true,
            isIOS: false,
            isDesktop: false,
            lookupModuleEnabled: true,
          ))
            action.storageValue,
      });
    });

    test('反馈只在应用内球上（各平台都有），应用外球没有', () {
      const FloatingBallGlobalAction feedback =
          FloatingBallGlobalAction.feedback;
      expect(FloatingBallGlobalAction.fromStorage('feedback'), feedback);
      expect(feedback.onByDefault, isTrue);
      for (final (bool android, bool ios, bool desktop) in <(bool, bool, bool)>[
        (true, false, false),
        (false, true, false),
        (false, false, true),
      ]) {
        expect(feedback.availableOn(isAndroid: android, isIOS: ios), isTrue);
        for (final FloatingBallScope scope in FloatingBallScope.values) {
          expect(
            feedback.availableIn(
              scope,
              isAndroid: android,
              isIOS: ios,
              isDesktop: desktop,
              lookupModuleEnabled: true,
            ),
            scope != FloatingBallScope.system,
            reason: '$scope android=$android ios=$ios desktop=$desktop',
          );
        }
      }
    });

    test('应用外查词（独立查词窗）只在 Android 提供', () {
      const FloatingBallGlobalAction popup =
          FloatingBallGlobalAction.popupLookup;
      expect(popup.availableOn(isAndroid: true, isIOS: false), isTrue);
      expect(popup.availableOn(isAndroid: false, isIOS: true), isFalse);
      expect(popup.availableOn(isAndroid: false, isIOS: false), isFalse);
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

  group('ScreenOcrImageLayout', () {
    test('截屏：与窗口同形，贴宽顶对齐', () {
      final ScreenOcrImageLayout layout = ScreenOcrImageLayout.of(
        box: const Size(400, 800),
        imageWidth: 800,
        imageHeight: 1600,
        fit: ScreenOcrImageFit.window,
      );
      expect(layout.origin, Offset.zero);
      expect(layout.scale, 0.5);
    });

    test('照片：等比放进页面并居中，行框随之平移', () {
      // 横拍 4:3 照片放进竖屏 400x800：按宽缩到 400x300，上下各留 250。
      final ScreenOcrImageLayout layout = ScreenOcrImageLayout.of(
        box: const Size(400, 800),
        imageWidth: 2000,
        imageHeight: 1500,
        fit: ScreenOcrImageFit.contain,
      );
      expect(layout.scale, 0.2);
      expect(layout.origin, const Offset(0, 250));
      expect(
        layout.imageRect(2000, 1500),
        const Rect.fromLTWH(0, 250, 400, 300),
      );
      expect(
        layout.toPage(const Rect.fromLTWH(500, 500, 1000, 100)),
        const Rect.fromLTWH(100, 350, 200, 20),
      );

      // 竖拍照片放进横屏：按高缩，左右留边。
      final ScreenOcrImageLayout tall = ScreenOcrImageLayout.of(
        box: const Size(1000, 600),
        imageWidth: 1500,
        imageHeight: 2000,
        fit: ScreenOcrImageFit.contain,
      );
      expect(tall.scale, 0.3);
      expect(tall.origin, const Offset(275, 0));
    });

    testWidgets('照片选取页：点在留边后的行上查到对应的字，选区换算到页面坐标', (WidgetTester tester) async {
      FloatingLyricLookupNotifier.instance.debugReset();
      addTearDown(FloatingLyricLookupNotifier.instance.debugReset);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // 1x1 透明 PNG：选取页只拿它当底图，几何全看识别结果的图尺寸。
      final Uint8List png = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x01,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
        0x1F,
        0x15,
        0xC4,
        0x89,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x44,
        0x41,
        0x54,
        0x78,
        0x9C,
        0x63,
        0x00,
        0x01,
        0x00,
        0x00,
        0x05,
        0x00,
        0x01,
        0x0D,
        0x0A,
        0x2D,
        0xB4,
        0x00,
        0x00,
        0x00,
        0x00,
        0x49,
        0x45,
        0x4E,
        0x44,
        0xAE,
        0x42,
        0x60,
        0x82,
      ]);
      const SystemOcrPageResult result = SystemOcrPageResult(
        // 照片坐标 (500,500)-(1500,600)，5 字；页面上是 (100,350)-(300,370)，每字 40。
        lines: <SystemOcrTextLine>[
          SystemOcrTextLine(
            text: '今日は晴れ',
            rect: Rect.fromLTWH(500, 500, 1000, 100),
            isVertical: false,
          ),
        ],
        imageWidth: 2000,
        imageHeight: 1500,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ScreenOcrPickerPage(
            imageBytes: png,
            result: result,
            fit: ScreenOcrImageFit.contain,
          ),
        ),
      );
      await tester.tapAt(const Offset(190, 360));
      await tester.pump();
      final FloatingLyricLookupRequest? request =
          FloatingLyricLookupNotifier.instance.pending;
      expect(request, isNotNull);
      expect(request!.text, '今日は晴れ');
      expect(request.index, 2); // は
      expect(request.selectionRect, const Rect.fromLTWH(180, 350, 40, 20));
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

  group('悬浮球通道：原生 → Dart', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      FloatingBallChannel.debugResetHandler();
    });

    tearDown(FloatingBallChannel.debugResetHandler);

    Future<void> push(String method, [Object? arguments]) async {
      final ByteData message = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            FloatingBallChannel.channel.name,
            message,
            (_) {},
          );
    }

    test('系统球「查词」与「关闭」都送到 Dart 回调', () async {
      int openLookupPage = 0;
      int closedByUser = 0;
      await FloatingBallChannel.installHandler(
        onLookup: (_) {},
        onScreenOcrFinished: () {},
        onOpenLookupPage: () => openLookupPage++,
        onSystemBallClosedByUser: () => closedByUser++,
      );
      await push('openLookupPage');
      await push('systemBallClosedByUser');
      expect(openLookupPage, 1);
      expect(closedByUser, 1);
    });

    test('桌面系统球：动作带锚点矩形、吸附后报位置', () async {
      final List<String> actions = <String>[];
      Rect? anchor;
      String? dock;
      double? fraction;
      await FloatingBallChannel.installHandler(
        onLookup: (_) {},
        onScreenOcrFinished: () {},
        onSystemBallAction: (String id, Rect? a) {
          actions.add(id);
          anchor = a;
        },
        onSystemBallPositionChanged: (String d, double f) {
          dock = d;
          fraction = f;
        },
      );
      await push('systemBallAction', <String, Object?>{
        'id': 'clipboard',
        'anchor': <num>[10, 20, 106, 116],
      });
      await push('systemBallAction', <String, Object?>{'id': 'open_app'});
      await push('systemBallPositionChanged', <String, Object?>{
        'dock': 'left',
        'fraction': 0.25,
      });
      expect(actions, <String>['clipboard', 'open_app']);
      // 第二次没带锚点：null，不沿用上一次。
      expect(anchor, isNull);
      expect(dock, 'left');
      expect(fraction, 0.25);
    });

    test('桌面系统球：锚点形状不对就当没有', () async {
      final List<Rect?> anchors = <Rect?>[];
      await FloatingBallChannel.installHandler(
        onLookup: (_) {},
        onScreenOcrFinished: () {},
        onSystemBallAction: (String id, Rect? a) => anchors.add(a),
      );
      await push('systemBallAction', <String, Object?>{
        'id': 'lookup',
        'anchor': <num>[1, 2, 3, 4],
      });
      await push('systemBallAction', <String, Object?>{
        'id': 'lookup',
        'anchor': <Object>[1, 'x', 3, 4],
      });
      expect(anchors, <Rect?>[const Rect.fromLTRB(1, 2, 3, 4), null]);
    });
  });
}

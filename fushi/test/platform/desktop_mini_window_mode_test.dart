import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/platform/desktop/desktop_mini_window_mode.dart';
import 'package:fushi/src/startup/desktop_window_placement.dart';

void main() {
  setUp(() {
    // 两个被测对象都是**进程内静态状态**：上一个用例留下的所有者 / 闸门 / 「上次写过
    // 什么」缓存会把下一个用例的断言全部短路成 no-op（且症状是「什么都没发生」，
    // 最难定位）。每个用例前一并复位，prefs 也换一份空的。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    DesktopWindowPlacement.resetSaveCacheForTesting();
    DesktopMiniWindowMode.resetForTesting();
  });

  tearDown(() {
    DesktopMiniWindowMode.resetForTesting();
    DesktopWindowPlacement.resetSaveCacheForTesting();
  });

  group('resolveMiniWindowBounds', () {
    test('1080p 工作区：宽取 22%、高按 16:9、锚在右下角留边 24', () {
      final Rect bounds = resolveMiniWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
        aspectRatio: 16 / 9,
      );

      expect(bounds.width, closeTo(1920 * 0.22, 1e-9)); // 422.4
      expect(bounds.height, closeTo(1920 * 0.22 * 9 / 16, 1e-9)); // 237.6
      expect(bounds.right, closeTo(1920 - 24, 1e-9));
      expect(bounds.bottom, closeTo(1080 - 24, 1e-9));
    });

    test('窄工作区上宽度被 320 的下限顶住', () {
      // 1200 * 0.22 = 264 < 320：小于 320 宽的小窗里字幕已经读不清了。
      final Rect bounds = resolveMiniWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 1200, 800),
        aspectRatio: 16 / 9,
      );

      expect(bounds.width, closeTo(320, 1e-9));
      expect(bounds.height, closeTo(180, 1e-9));
    });

    test('4K 工作区上宽度被 560 的上限压住', () {
      // 3840 * 0.22 = 844.8 > 560：再大就不叫「小窗」了。
      final Rect bounds = resolveMiniWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 3840, 2160),
        aspectRatio: 16 / 9,
      );

      expect(bounds.width, closeTo(560, 1e-9));
      expect(bounds.height, closeTo(560 * 9 / 16, 1e-9));
    });

    test('高按传入的宽高比算，不是写死 16:9', () {
      final Rect wide = resolveMiniWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
        aspectRatio: 2.39,
      );
      final Rect tall = resolveMiniWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
        aspectRatio: 4 / 3,
      );

      expect(wide.width, closeTo(tall.width, 1e-9));
      expect(wide.height, closeTo(wide.width / 2.39, 1e-9));
      expect(tall.height, closeTo(tall.width * 3 / 4, 1e-9));
      expect(wide.height, lessThan(tall.height));
    });

    test('宽高比 <= 0 / 非有限时退回 16:9', () {
      // 播放器还没解出视频尺寸时给的就是 0。
      const Rect workArea = Rect.fromLTWH(0, 0, 1920, 1080);
      final Rect reference = resolveMiniWindowBounds(
        workArea: workArea,
        aspectRatio: 16 / 9,
      );

      for (final double bad in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          resolveMiniWindowBounds(workArea: workArea, aspectRatio: bad),
          reference,
          reason: '非法宽高比 $bad 必须退回 16/9',
        );
      }
    });

    test('副屏工作区：右下角是那块屏的右下角，不是主屏原点', () {
      const Rect workArea = Rect.fromLTWH(1920, 0, 1440, 900);
      final Rect bounds = resolveMiniWindowBounds(
        workArea: workArea,
        aspectRatio: 16 / 9,
      );

      // 1440 * 0.22 = 316.8 → 被 320 下限顶住。
      expect(bounds.width, closeTo(320, 1e-9));
      expect(bounds.right, closeTo(1920 + 1440 - 24, 1e-9));
      expect(bounds.bottom, closeTo(900 - 24, 1e-9));
      expect(workArea.contains(bounds.topLeft), isTrue);
    });

    test('比小窗还小的工作区：整体被 clamp 进工作区，且留白让位', () {
      const Rect workArea = Rect.fromLTWH(0, 0, 280, 160);
      final Rect bounds = resolveMiniWindowBounds(
        workArea: workArea,
        aspectRatio: 16 / 9,
      );

      expect(bounds.width, lessThanOrEqualTo(workArea.width));
      expect(bounds.height, lessThanOrEqualTo(workArea.height));
      expect(bounds.left, greaterThanOrEqualTo(workArea.left));
      expect(bounds.top, greaterThanOrEqualTo(workArea.top));
      expect(bounds.right, lessThanOrEqualTo(workArea.right + 1e-9));
      expect(bounds.bottom, lessThanOrEqualTo(workArea.bottom + 1e-9));
    });

    test('极矮工作区改由高度定尺寸，宽高比仍然保住', () {
      // 320 / (16/9) = 180 > 150：这时必须反过来按高度算宽度，而不是把宽裁了留个
      // 畸形矩形——比例锁一上就会跳一下。
      final Rect bounds = resolveMiniWindowBounds(
        workArea: const Rect.fromLTWH(0, 0, 1000, 150),
        aspectRatio: 16 / 9,
      );

      expect(bounds.height, closeTo(150, 1e-9));
      expect(bounds.width / bounds.height, closeTo(16 / 9, 1e-9));
    });

    test('小窗最小尺寸远低于常规窗口地板', () {
      expect(kMiniWindowMinimumSize, const Size(240, 135));
      expect(
        kMiniWindowMinimumSize.width,
        lessThan(DesktopWindowPlacement.minimumSize.width),
      );
      expect(
        kMiniWindowMinimumSize.height,
        lessThan(DesktopWindowPlacement.minimumSize.height),
      );
      // 小窗地板本身就是 16:9：不是随手取的两个数。
      expect(
        kMiniWindowMinimumSize.width / kMiniWindowMinimumSize.height,
        closeTo(16 / 9, 1e-9),
      );
    });
  });

  group('DesktopWindowPlacement 几何记忆闸门', () {
    const String maximizedKey = 'desktop_main_window_maximized';
    const List<String> boundsKeys = <String>[
      'desktop_main_window_x',
      'desktop_main_window_y',
      'desktop_main_window_width',
      'desktop_main_window_height',
    ];

    test('默认不暂停', () {
      expect(DesktopWindowPlacement.geometryMemorySuspended, isFalse);
    });

    test('暂停期间 rememberMaximized 一个字节都不写', () async {
      DesktopWindowPlacement.setGeometryMemorySuspended(true);
      await DesktopWindowPlacement.rememberMaximized(true);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(
        prefs.getBool(maximizedKey),
        isNull,
        reason: '进入小窗要先 unmaximize，那次事件不得改写主窗的最大化记忆。',
      );
    });

    test('闸门抬起后 rememberMaximized 恢复写盘（正向对照）', () async {
      // 没有这条对照，上一个用例的「没写」可能只是因为整条写路径本来就坏了。
      await DesktopWindowPlacement.rememberMaximized(true);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getBool(maximizedKey), isTrue);
    });

    test('暂停期间 saveCurrentBoundsNow 不写外框', () async {
      DesktopWindowPlacement.setGeometryMemorySuspended(true);
      await DesktopWindowPlacement.saveCurrentBoundsNow();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final String key in boundsKeys) {
        expect(prefs.get(key), isNull, reason: '$key 被小窗几何污染了');
      }
      expect(prefs.getBool(maximizedKey), isNull);
    });

    test('暂停期间 rememberCurrentBounds 连去抖都不排', () async {
      DesktopWindowPlacement.setGeometryMemorySuspended(true);
      DesktopWindowPlacement.rememberCurrentBounds(debounce: Duration.zero);
      // 去抖到点也只会调到 saveCurrentBoundsNow，同样被闸门挡住；多转几圈事件循环
      // 确保「真到点了」再断言。
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final String key in boundsKeys) {
        expect(prefs.get(key), isNull, reason: '$key 被小窗几何污染了');
      }
    });

    test('resetSaveCacheForTesting 一并复位闸门', () {
      DesktopWindowPlacement.setGeometryMemorySuspended(true);
      DesktopWindowPlacement.resetSaveCacheForTesting();
      expect(DesktopWindowPlacement.geometryMemorySuspended, isFalse);
    });
  });

  group('DesktopMiniWindowMode', () {
    test('非桌面平台下 enter 是 no-op', () async {
      final Object owner = Object();
      DesktopMiniWindowMode.debugDesktopOverride = false;

      await DesktopMiniWindowMode.enter(owner: owner, aspectRatio: 16 / 9);

      expect(DesktopMiniWindowMode.isActive, isFalse);
      expect(DesktopMiniWindowMode.activeListenable.value, isFalse);
      // 关键的一条：移动端不得留下一个抬不起来的几何记忆闸门。
      expect(DesktopWindowPlacement.geometryMemorySuspended, isFalse);
    });

    test('非桌面平台下 exit / updateAspectRatio 也是 no-op', () async {
      final Object owner = Object();
      DesktopMiniWindowMode.debugDesktopOverride = false;

      final bool exited = await DesktopMiniWindowMode.exit(
        owner: owner,
        restoreAspectRatioLock: false,
      );

      expect(exited, isFalse);
      await DesktopMiniWindowMode.updateAspectRatio(4 / 3);
      expect(DesktopMiniWindowMode.isActive, isFalse);
    });

    test('未进入小窗时 exit 返回 false（幂等）', () async {
      // 桌面宿主上也一样：页面 dispose 会无条件调一次 exit，它不能在没进过小窗时
      // 去动窗口。
      final bool exited = await DesktopMiniWindowMode.exit(
        owner: Object(),
        restoreAspectRatioLock: true,
      );

      expect(exited, isFalse);
      expect(DesktopMiniWindowMode.isActive, isFalse);
    });

    test('activeListenable 与 isActive 是同一个真相源', () {
      expect(
        DesktopMiniWindowMode.activeListenable.value,
        DesktopMiniWindowMode.isActive,
      );
    });
  });

  // 真正的桌面 enter / exit 主路径：mock 掉 window_manager 通道，记账每一次调用。
  // screen_retriever / 标题栏 / 全屏读写这些通道不 mock——它们在 `_step` / 各自的
  // try 里失败即回落，正好也验了「非致命通道失败不阻断小窗」。
  group('DesktopMiniWindowMode（mock window_manager 通道）', () {
    const MethodChannel channel = MethodChannel('window_manager');
    const Map<String, double> originalBounds = <String, double>{
      'x': 100,
      'y': 100,
      'width': 1280,
      'height': 720,
    };
    late Map<String, double> currentBounds;
    late List<MethodCall> calls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      DesktopMiniWindowMode.resetForTesting();
      DesktopMiniWindowMode.debugDesktopOverride = true;
      currentBounds = Map<String, double>.of(originalBounds);
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'getBounds':
                return Map<String, double>.of(currentBounds);
              case 'setBounds':
                // 与真宿主同语义：摆位之后再读外框读到的就是新框——并发 enter 的第二条
                // 链正是在这里读到小窗框并把它当成「原框」记下来。
                final Map<Object?, Object?> args =
                    call.arguments as Map<Object?, Object?>;
                currentBounds = <String, double>{
                  'x': (args['x'] as num).toDouble(),
                  'y': (args['y'] as num).toDouble(),
                  'width': (args['width'] as num).toDouble(),
                  'height': (args['height'] as num).toDouble(),
                };
                return null;
              case 'isMaximized':
              case 'isAlwaysOnTop':
              case 'isFullScreen':
                return false;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      DesktopMiniWindowMode.resetForTesting();
    });

    List<MethodCall> boundsWrites() =>
        calls.where((MethodCall c) => c.method == 'setBounds').toList();

    test('并发 enter 串行化：只摆位一次，退出时还原的是进入前的原框', () async {
      final Object owner = Object();
      // 不 await 第一条就发第二条 = 按住 W 的 key-repeat / 按钮双击。
      await Future.wait(<Future<void>>[
        DesktopMiniWindowMode.enter(owner: owner, aspectRatio: 16 / 9),
        DesktopMiniWindowMode.enter(owner: owner, aspectRatio: 16 / 9),
      ]);
      expect(DesktopMiniWindowMode.isActive, isTrue);
      expect(
        boundsWrites(),
        hasLength(1),
        reason: '第二条链必须排在第一条之后，看到已进入即 no-op，不再摆位',
      );

      final bool exited = await DesktopMiniWindowMode.exit(
        owner: owner,
        restoreAspectRatioLock: false,
      );
      expect(exited, isTrue);
      final Map<Object?, Object?> restored =
          boundsWrites().last.arguments as Map<Object?, Object?>;
      expect(restored['width'], 1280.0, reason: '还原框必须是进入前的主窗框，不是第二条链读到的小窗框');
      expect(restored['height'], 720.0);
      expect(restored['x'], 100.0);
      expect(DesktopWindowPlacement.geometryMemorySuspended, isFalse);
    });

    test('claim 接管所有权：旧 owner 的 exit 是 no-op，新 owner 才能退出', () async {
      final Object oldPage = Object();
      final Object newPage = Object();
      await DesktopMiniWindowMode.enter(owner: oldPage, aspectRatio: 16 / 9);
      expect(DesktopMiniWindowMode.isActive, isTrue);

      // 换集：新页 initState 认领，旧页 dispose 随后 exit。
      expect(DesktopMiniWindowMode.claim(owner: newPage), isTrue);
      final bool oldExit = await DesktopMiniWindowMode.exit(
        owner: oldPage,
        restoreAspectRatioLock: false,
      );
      expect(oldExit, isFalse, reason: '旧页已不是 owner，不得把小窗退掉');
      expect(DesktopMiniWindowMode.isActive, isTrue, reason: '换集后小窗保持');

      final bool newExit = await DesktopMiniWindowMode.exit(
        owner: newPage,
        restoreAspectRatioLock: false,
      );
      expect(newExit, isTrue);
      expect(DesktopMiniWindowMode.isActive, isFalse);
    });

    test('未进入小窗时 claim 返回 false（新页照常按普通窗口起）', () {
      expect(DesktopMiniWindowMode.claim(owner: Object()), isFalse);
      expect(DesktopMiniWindowMode.isActive, isFalse);
    });
  });
}

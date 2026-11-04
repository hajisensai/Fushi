import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kDoubleTapMinTime;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

import '../helpers/source_guard.dart';

/// BUG-4102：音乐歌词页、有声书歌词模式、小说阅读器（及漫画、游戏串流）里拖不动
/// 整个窗口。
///
/// 这些页都上报了 [FushiTitleBarColorScope]（沉浸页），自绘标题行（拖动区 + 窗口
/// 按钮）平时隐去且不吃指针，唯一入口是「指针在窗口最顶边 8px 停留 400ms」——
/// Windows 窗口化时那 8px 正压着顶边 resize 把手。修法：
///  * 顶栏会收起的页（阅读器 / 漫画，与视频 BUG-3929 同一套）经
///    [FushiTitleBarRevealScope] 让标题行随工具栏出现；
///  * 顶栏常驻、标题行那一条只有背景的页（音乐 / 歌词模式 / 游戏串流）经
///    [FushiTitleBarDragBandScope] 把标题行变成隐形拖动条：拖动区始终命中，窗口
///    按钮指针进入才淡入（用户 2026-11-04 否决了按钮常显）；
///  * 音乐 / 歌词模式的空白背景经 [FushiWindowDragArea] 按住拖动即拖窗口。
class _FakeClock implements LyricsPlayerClock {
  @override
  Duration get position => const Duration(seconds: 42);

  @override
  Duration get duration => const Duration(minutes: 10);

  @override
  LyricsPlayerStats get stats => LyricsPlayerStats.empty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> windowCalls = <String>[];

  setUp(() {
    windowCalls.clear();
    FushiDesktopTitleBar.debugIsEnabled = true;
    FushiDesktopTitleBar.debugHostPlatform = () => TargetPlatform.windows;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          MethodCall call,
        ) async {
          windowCalls.add(call.method);
          switch (call.method) {
            case 'isMaximized':
            case 'isFullScreen':
            case 'isFocused':
              return false;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    FushiDesktopTitleBar.debugIsEnabled = false;
    FushiDesktopTitleBar.debugHostPlatform = () => defaultTargetPlatform;
    WindowCaptionChannel.captionMaxButtonHovered.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  Future<void> pumpShell(WidgetTester tester, Widget home) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 760);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) =>
            FushiDesktopTitleBar(title: const Text('Fushi'), child: child!),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 标题行拖动区中段（窗口按钮组在右上，顶边 8px 是 resize 把手）。
  const Offset captionPoint = Offset(400, 18);

  /// 窗口按钮的可见度（标题行那层 AnimatedOpacity）。
  double captionOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.byType(DragToMoveArea).first,
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      )
      .opacity;

  Future<void> mouseDragAt(WidgetTester tester, Offset from) async {
    final TestGesture mouse = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(60, 0));
    await mouse.moveBy(const Offset(60, 0));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
  }

  Future<void> mouseDoubleClickAt(WidgetTester tester, Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  Widget lyricsOverlay() => Scaffold(
    body: ReaderLyricsPlayerOverlay(
      lyricsView: const SizedBox.expand(),
      data: LyricsPlayerData(
        title: '無職転生',
        cover: null,
        isPlaying: false,
        speed: 1,
        lyricsMasked: false,
        clock: _FakeClock(),
      ),
      callbacks: LyricsPlayerCallbacks(
        onClose: () {},
        onPlayPause: () {},
        onPreviousCue: () {},
        onNextCue: () {},
        onSeek: (_) {},
        onToggleMask: () {},
        onOpenStatistics: () {},
        onSpeedChanged: (_) {},
        onMore: (_) {},
        onTapBackground: () {},
      ),
      onHtmlThemeChanged: (_) {},
    ),
  );

  group('隐形拖动条（有声书歌词模式真覆盖层）', () {
    testWidgets('按钮隐去时拖动区仍命中：拖动 → startDragging，双击 → maximize', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester, lyricsOverlay());
      expect(
        FushiDesktopTitleBar.pageColors.value,
        isNotNull,
        reason: '前置：沉浸页',
      );
      expect(FushiDesktopTitleBar.captionDragBand.value, isTrue);
      expect(captionOpacity(tester), 0, reason: '窗口按钮默认不显示');

      windowCalls.clear();
      await mouseDragAt(tester, captionPoint);
      expect(windowCalls, contains('startDragging'));

      windowCalls.clear();
      await mouseDoubleClickAt(tester, captionPoint);
      expect(windowCalls, contains('maximize'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('看不见的窗口按钮不吃点击；指针进入带子按钮淡入，离开淡出', (WidgetTester tester) async {
      await pumpShell(tester, lyricsOverlay());
      final Offset close = tester.getCenter(
        find.byKey(FushiDesktopTitleBar.closeButtonKey),
      );
      // 同一只鼠标走完全程（测试里一台鼠标设备只能 add 一次）。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(400, 400));

      // 直接移到关闭键上立刻点（按钮还没浮出）：不能一点就关窗。
      windowCalls.clear();
      await mouse.moveTo(close);
      await mouse.down(close);
      await mouse.up();
      await tester.pump();
      expect(windowCalls, isNot(contains('close')), reason: '隐去的关闭键一点就关窗不可接受');

      // 停在带子里（离顶边 18px，不是顶边 8px）：短暂停留即浮出。
      await mouse.moveTo(captionPoint);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(captionOpacity(tester), 1);

      windowCalls.clear();
      await mouse.moveTo(close);
      await mouse.down(close);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(windowCalls, contains('close'), reason: '按钮浮出后照常可点');

      await mouse.moveTo(const Offset(400, 400));
      await tester.pumpAndSettle();
      expect(captionOpacity(tester), 0);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('划过带子（停留不够）不浮出', (WidgetTester tester) async {
      await pumpShell(tester, lyricsOverlay());
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(400, 400));
      await mouse.moveTo(captionPoint);
      await tester.pump(const Duration(milliseconds: 50));
      await mouse.moveTo(const Offset(400, 400));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(captionOpacity(tester), 0);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('空白背景拖动窗口（FushiWindowDragArea）', () {
    late int taps;

    Widget background() => Scaffold(
      body: FushiWindowDragArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          child: const SizedBox.expand(),
        ),
      ),
    );

    setUp(() => taps = 0);

    testWidgets('鼠标按住拖动越过阈值 → startDragging，不算单击', (WidgetTester tester) async {
      await pumpShell(tester, background());
      windowCalls.clear();
      await mouseDragAt(tester, const Offset(400, 400));
      expect(windowCalls, contains('startDragging'));
      expect(taps, 0);
    });

    testWidgets('单击仍走背景自己的回调；双击不最大化、不拖窗口', (WidgetTester tester) async {
      await pumpShell(tester, background());
      windowCalls.clear();
      await tester.tapAt(const Offset(400, 400), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(taps, 1);
      await mouseDoubleClickAt(tester, const Offset(400, 400));
      expect(taps, 3);
      expect(windowCalls, isNot(contains('startDragging')));
      expect(windowCalls, isNot(contains('maximize')));
    });

    testWidgets('触摸拖动不拖窗口（不抢触屏手势）', (WidgetTester tester) async {
      await pumpShell(tester, background());
      windowCalls.clear();
      await tester.dragFrom(
        const Offset(400, 400),
        const Offset(120, 0),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(windowCalls, isNot(contains('startDragging')));
    });

    testWidgets('没装自绘顶栏时不发起拖动', (WidgetTester tester) async {
      FushiDesktopTitleBar.debugIsEnabled = false;
      await pumpShell(tester, background());
      windowCalls.clear();
      await mouseDragAt(tester, const Offset(400, 400));
      expect(windowCalls, isNot(contains('startDragging')));
    });
  });

  testWidgets('阅读器 / 漫画式（chrome 会收起）：栏收起时顶部归正文，栏唤出时可拖窗口', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<bool> chrome = ValueNotifier<bool>(false);
    addTearDown(chrome.dispose);
    int pageTaps = 0;
    await pumpShell(
      tester,
      ValueListenableBuilder<bool>(
        valueListenable: chrome,
        builder: (_, bool shown, Widget? page) =>
            FushiTitleBarRevealScope(revealed: shown, child: page!),
        child: FushiTitleBarColorScope(
          colors: (
            background: const Color(0xFFF7F6EB),
            foreground: const Color(0xFF3A3A3A),
          ),
          child: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => pageTaps++,
              onPanStart: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    expect(FushiDesktopTitleBar.captionDragBand.value, isFalse);

    // 栏收起：顶部几行正文照常点词，按下不被标题行吃掉。
    await mouseDragAt(tester, captionPoint);
    expect(windowCalls, isNot(contains('startDragging')));
    await tester.tapAt(captionPoint, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(pageTaps, 1);

    chrome.value = true;
    await tester.pumpAndSettle();
    expect(captionOpacity(tester), 1);
    windowCalls.clear();
    await mouseDragAt(tester, captionPoint);
    expect(windowCalls, contains('startDragging'));
  });

  testWidgets('拖动条页被另一整页盖住时撤回', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 760);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        builder: (BuildContext context, Widget? child) =>
            FushiDesktopTitleBar(title: const Text('Fushi'), child: child!),
        home: const FushiTitleBarDragBandScope(child: Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.captionDragBand.value, isTrue);
    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.captionDragBand.value, isFalse);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.captionDragBand.value, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(FushiDesktopTitleBar.captionDragBand.value, isFalse);
  });

  group('沉浸页都要表态（BUG-3929 / BUG-4102）', () {
    String code(String path) =>
        compactCode(maskComments(File(path).readAsStringSync()));

    test('小说阅读器：顶栏可见态驱动标题行', () {
      expect(
        code('lib/src/pages/implementations/reader_fushi_page.dart'),
        contains('FushiTitleBarRevealScope(revealed:_bottomBarShouldPaint,'),
      );
    });

    test('漫画阅读页：与顶栏 MangaChromeReveal 同一判据驱动标题行', () {
      expect(
        code('lib/src/media/manga/reader/manga_fushi_page.dart'),
        contains('FushiTitleBarRevealScope(revealed:mangaChromeBarPainted('),
      );
    });

    test('音乐歌词页 / 歌词覆盖层 / 游戏串流：隐形拖动条；音乐与歌词背景可拖窗口', () {
      for (final String path in <String>[
        'lib/src/pages/implementations/music/music_lyrics_page.dart',
        'lib/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart',
        'lib/src/pages/implementations/game_stream_page.dart',
      ]) {
        expect(
          code(path),
          contains('FushiTitleBarDragBandScope('),
          reason: path,
        );
      }
      expect(
        code('lib/src/pages/implementations/music/music_lyrics_page.dart'),
        contains('FushiWindowDragArea(child:background)'),
      );
      expect(
        code(
          'lib/src/media/audiobook/lyrics_player/lyrics_player_overlay.dart',
        ),
        contains(
          'FushiWindowDragArea(child:GestureDetector(behavior:HitTestBehavior.opaque,onTap:widget.callbacks.onTapBackground,',
        ),
      );
    });

    // 棘轮：上报配色的页面（沉浸页）必须同时表态标题行怎么出现，否则它只能靠
    // 顶边 8px 停留浮出、Windows 上等于拖不动窗口。
    test(
      '上报配色的页面必须挂 FushiTitleBarRevealScope 或 FushiTitleBarDragBandScope',
      () {
        final List<String> immersive = <String>[];
        final List<String> missing = <String>[];
        for (final FileSystemEntity e in Directory(
          'lib',
        ).listSync(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          final String path = e.path.replaceAll(r'\', '/');
          if (path.endsWith('fushi_desktop_title_bar.dart')) continue;
          final String src = maskComments(e.readAsStringSync());
          if (!src.contains('FushiTitleBarColorScope(')) continue;
          immersive.add(path);
          if (src.contains('FushiTitleBarRevealScope(') ||
              src.contains('FushiTitleBarDragBandScope(')) {
            continue;
          }
          missing.add(path);
        }
        expect(immersive.length, greaterThanOrEqualTo(6), reason: '扫描前置');
        expect(missing, isEmpty);
      },
    );
  });
}

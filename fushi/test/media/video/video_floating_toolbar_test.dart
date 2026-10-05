import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_control_bar.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 视频播放器 M3 Expressive 浮动工具栏（2026-10-05）：控制条不再是贴边整条实体栏，
/// 而是每簇一枚悬浮胶囊（[VideoBarClusterStyle]）+ 悬浮进度条轨道槽 + spring 显隐。
void main() {
  const VideoBarClusterStyle style = VideoBarClusterStyle(
    color: Color(0xFF223344),
    centerColor: Color(0xFF445566),
    padding: 4,
    verticalPadding: 2,
    gap: 8,
    verticalAlignment: 1,
  );

  group('VideoControlBar 浮动胶囊', () {
    late List<String> selected;
    late List<String> backgroundTaps;
    late List<FocusNode> nodes;

    Widget box(String id, double width) {
      final FocusNode node = FocusNode(debugLabel: id);
      nodes.add(node);
      return Focus(
        focusNode: node,
        child: GestureDetector(
          onTap: () => selected.add(id),
          child: ColoredBox(
            key: Key(id),
            color: const Color(0xFF000000),
            child: SizedBox(width: width, height: 40),
          ),
        ),
      );
    }

    VideoBarMenuAction action(String label) => VideoBarMenuAction(
      icon: Icons.circle,
      label: label,
      onSelected: () => selected.add('menu:$label'),
    );

    // 起始簇：上一集 / 播放 / 时间；居中簇（传输）：−10s / 上一句 / 下一句 / +10s；
    // 末尾簇：字幕 / 倍速 / 全屏。
    List<VideoBarEntry> entries() => <VideoBarEntry>[
      VideoBarEntry(
        priority: 50,
        menuAction: action('prev-episode'),
        child: box('prev-episode', 44),
      ),
      VideoBarEntry(child: box('play', 56)),
      VideoBarEntry(child: box('time', 100)),
      VideoBarEntry(
        cluster: VideoBarCluster.center,
        priority: 80,
        group: VideoBarHideGroup.seek,
        menuAction: action('-10s'),
        child: box('seek-back', 44),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.center,
        priority: 75,
        group: VideoBarHideGroup.cue,
        menuAction: action('prev-cue'),
        child: box('prev-cue', 44),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.center,
        priority: 75,
        group: VideoBarHideGroup.cue,
        menuAction: action('next-cue'),
        child: box('next-cue', 44),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.center,
        priority: 80,
        group: VideoBarHideGroup.seek,
        menuAction: action('+10s'),
        child: box('seek-forward', 44),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.end,
        priority: 60,
        menuAction: action('subtitles'),
        child: box('subtitles', 44),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.end,
        priority: 65,
        menuAction: action('speed'),
        child: box('speed', 44),
      ),
      VideoBarEntry(
        cluster: VideoBarCluster.end,
        priority: 90,
        menuAction: action('fullscreen'),
        child: box('fullscreen', 44),
      ),
    ];
    // 原样内容宽：起始 200、居中 176、末尾 132 = 508；胶囊另占 3×8 + 2×8 = 40。

    Future<void> pumpBar(WidgetTester tester, double width) async {
      selected = <String>[];
      backgroundTaps = <String>[];
      nodes = <FocusNode>[];
      tester.view.physicalSize = const Size(1400, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // 画面层的「点画面」：胶囊上的点击不该落到这里。
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => backgroundTaps.add('video'),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 56,
                  child: VideoControlBar(
                    clusterStyle: style,
                    moreButtonBuilder: (VoidCallback open) => GestureDetector(
                      onTap: open,
                      child: const ColoredBox(
                        key: Key('more'),
                        color: Color(0xFF000000),
                        child: SizedBox(width: 44, height: 40),
                      ),
                    ),
                    entries: entries(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    tearDown(() {
      for (final FocusNode n in nodes) {
        n.dispose();
      }
    });

    bool visible(String id) =>
        find.byKey(Key(id)).hitTestable().evaluate().isNotEmpty;

    testWidgets('三簇各成一枚胶囊：留出内边距与间距，居中簇钉正中，胶囊贴条底', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      final Rect prev = tester.getRect(find.byKey(const Key('prev-episode')));
      final Rect time = tester.getRect(find.byKey(const Key('time')));
      final Rect seekBack = tester.getRect(find.byKey(const Key('seek-back')));
      final Rect seekFwd = tester.getRect(
        find.byKey(const Key('seek-forward')),
      );
      final Rect full = tester.getRect(find.byKey(const Key('fullscreen')));
      // 起始胶囊从 0 开始，按钮内缩 padding 4。
      expect(prev.left, moreOrLessEquals(4));
      // 末尾胶囊贴右，按钮离右缘 padding 4。
      expect(full.right, moreOrLessEquals(996));
      // 居中簇（内容 176 + 2×4 = 胶囊 184）在 1000 宽里居中：胶囊 408..592。
      expect(seekBack.left, moreOrLessEquals(412));
      expect(seekFwd.right, moreOrLessEquals(588));
      // 胶囊高 = 40 + 2×2 = 44，贴 56 高条的底：按钮竖直范围 14..54。
      expect(time.top, moreOrLessEquals(14));
      expect(time.bottom, moreOrLessEquals(54));
      expect(visible('more'), isFalse);
    });

    testWidgets('胶囊留白吃掉点击（不穿透成「点画面」），胶囊之间的空隙照常穿透', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      // 起始胶囊左内边距（x=2）：吸收。
      await tester.tapAt(const Offset(2, 34));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backgroundTaps, isEmpty);
      expect(selected, isEmpty);
      // 起始胶囊（0..208）与居中胶囊（408..）之间：穿透到画面。
      await tester.tapAt(const Offset(300, 34));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backgroundTaps, <String>['video']);
      // 胶囊里的按钮照常拿到自己的点击。
      await tester.tap(find.byKey(const Key('speed')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected, <String>['speed']);
      expect(backgroundTaps, <String>['video']);
    });

    testWidgets('窄窗：胶囊留白预扣后放不下的按优先级收进「⋯」，菜单列出它们', (WidgetTester tester) async {
      // 规划宽 = 520 − 胶囊留白 40 = 480 < 内容 508：收上一集（50）后 464 + ⋯44
      // = 508 仍超 → 再收字幕（60）：420 + 44 = 464 ≤ 480。
      await pumpBar(tester, 520);
      expect(visible('prev-episode'), isFalse);
      expect(visible('subtitles'), isFalse);
      expect(visible('more'), isTrue);
      expect(visible('play'), isTrue);
      expect(visible('fullscreen'), isTrue);
      // 「⋯」在末尾胶囊的最后，仍在胶囊内边距里。
      expect(
        tester.getRect(find.byKey(const Key('more'))).right,
        moreOrLessEquals(516),
      );
      await tester.tap(find.byKey(const Key('more')));
      await tester.pumpAndSettle();
      expect(find.text('prev-episode'), findsOneWidget);
      expect(find.text('subtitles'), findsOneWidget);
      expect(find.text('speed'), findsNothing);
      await tester.tap(find.text('subtitles'));
      await tester.pumpAndSettle();
      expect(selected, <String>['menu:subtitles']);
    });

    testWidgets('Tab 焦点按「起始 → 传输 → 末尾」胶囊顺序遍历', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      final List<String> order = <String>[];
      for (int i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final FocusNode? f = FocusManager.instance.primaryFocus;
        if (f?.debugLabel != null) order.add(f!.debugLabel!);
      }
      expect(order, <String>[
        'prev-episode',
        'play',
        'time',
        'seek-back',
        'prev-cue',
        'next-cue',
        'seek-forward',
        'subtitles',
        'speed',
        'fullscreen',
      ]);
    });

    testWidgets('最小 / 最大固有宽把胶囊留白算进去（顶栏按它给每组保底）', (WidgetTester tester) async {
      await pumpBar(tester, 1000);
      final RenderBox bar = tester.renderObject(
        find.descendant(
          of: find.byType(VideoControlBar),
          matching: find.byWidgetPredicate(
            (Widget w) => w.runtimeType.toString() == '_VideoControlBarLayout',
          ),
        ),
      );
      // 原样 508 + 胶囊 40。
      expect(bar.getMaxIntrinsicWidth(56), moreOrLessEquals(548));
      // 钉死项 play 56 + time 100 + ⋯ 44 + 胶囊 40。
      expect(bar.getMinIntrinsicWidth(56), moreOrLessEquals(240));
    });
  });

  group('VideoM3eChromeSlide spring 显隐', () {
    Future<ValueNotifier<bool>> pumpSlide(
      WidgetTester tester, {
      bool reduceMotion = false,
    }) async {
      final ValueNotifier<bool> visible = ValueNotifier<bool>(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: VideoM3eChromeSlide(
                enabled: true,
                visible: visible,
                hiddenOffset: const Offset(0, 12),
                child: const SizedBox(key: Key('bar'), width: 200, height: 40),
              ),
            ),
          ),
        ),
      );
      return visible;
    }

    Matrix4 transformOf(WidgetTester tester) => tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.byKey(const Key('bar')),
            matching: find.byType(Transform),
          ),
        )
        .map((Transform t) => t.transform)
        .fold(Matrix4.identity(), (Matrix4 a, Matrix4 b) => a * b);

    testWidgets('挂载即从下方弹入，静止后回到原位、原尺寸', (WidgetTester tester) async {
      await pumpSlide(tester);
      // 刚挂载：还在偏移处。
      expect(transformOf(tester).getTranslation().y, greaterThan(1));
      await tester.pumpAndSettle();
      final Matrix4 m = transformOf(tester);
      expect(m.getTranslation().y, moreOrLessEquals(0, epsilon: 0.01));
      expect(m.getMaxScaleOnAxis(), moreOrLessEquals(1, epsilon: 0.001));
    });

    testWidgets('隐藏时下滑并缩小，再显示时弹回', (WidgetTester tester) async {
      final ValueNotifier<bool> visible = await pumpSlide(tester);
      await tester.pumpAndSettle();
      visible.value = false;
      await tester.pumpAndSettle();
      final Matrix4 hidden = transformOf(tester);
      expect(hidden.getTranslation().y, greaterThan(10));
      expect(hidden.getMaxScaleOnAxis(), lessThan(0.95));
      visible.value = true;
      await tester.pump(const Duration(milliseconds: 16));
      expect(transformOf(tester).getTranslation().y, greaterThan(1));
      await tester.pumpAndSettle();
      expect(
        transformOf(tester).getTranslation().y,
        moreOrLessEquals(0, epsilon: 0.01),
      );
    });

    testWidgets('减弱动态效果：不位移不缩放', (WidgetTester tester) async {
      final ValueNotifier<bool> visible = await pumpSlide(
        tester,
        reduceMotion: true,
      );
      expect(transformOf(tester).getTranslation().y, 0);
      visible.value = false;
      await tester.pump();
      expect(transformOf(tester).getTranslation().y, 0);
      expect(transformOf(tester).getMaxScaleOnAxis(), 1);
    });
  });

  group('悬浮进度条', () {
    VideoSeekBarVisual visual({bool dragging = false, double position = 0.4}) =>
        VideoSeekBarVisual(
          position: position,
          buffer: 0.6,
          hover: dragging ? position : null,
          hovering: dragging,
          dragging: dragging,
          playing: !dragging,
          duration: const Duration(minutes: 10),
          alignment: Alignment.center,
        );

    Future<void> pumpTrack(WidgetTester tester, VideoSeekBarVisual v) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 600,
                  height: 36,
                  child: VideoM3eSeekTrack(
                    visual: v,
                    color: const Color(0xFFAACCFF),
                    scale: 1,
                    lane: const Color(0xE6202830),
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('拖动时手柄上方出时间气泡，跟着拖动比例走；松手收起', (WidgetTester tester) async {
      await pumpTrack(tester, visual(dragging: true, position: 0.5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('5:00'), findsOneWidget);
      await pumpTrack(tester, visual(dragging: true, position: 0.25));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2:30'), findsOneWidget);
      await pumpTrack(tester, visual(position: 0.25));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2:30'), findsNothing);
    });
  });

  group('接线守卫', () {
    final String theme = File(
      'lib/src/pages/implementations/video_fushi/controls_theme.part.dart',
    ).readAsStringSync();
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();

    test('两套 theme 都不再画整屏 backdrop（M3E 浮动工具栏自带胶囊底色）', () {
      expect(
        RegExp(
          r'backdropColor:\s*const Color\(0x00000000\)',
        ).allMatches(theme).length,
        2,
      );
      expect(theme.contains('fork.backdropColor'), isFalse);
    });

    test('M3E 进度条与底栏三簇收进同一块底部面板，顶栏按钮组画浮动胶囊', () {
      final String layout = File(
        'lib/src/pages/implementations/video_fushi/layout.part.dart',
      ).readAsStringSync();
      expect(theme.contains('lane:'), isFalse, reason: '轨道已收进底部面板，不再画独立轨道槽');
      expect(layout, contains('VideoM3eBottomPanel('));
      expect(layout, contains('geometry: _m3eBottomPanelGeometry()'));
      expect(
        page,
        contains('clusterStyle: _m3eFloatingBarStyle(inPanel: true)'),
        reason: '底栏三簇收进底部面板，不再各画胶囊',
      );
      expect(
        page,
        contains('clusterStyle: _m3eFloatingBarStyle(verticalAlignment: 0)'),
        reason: '顶栏按钮组必须是浮动胶囊',
      );
    });

    test('浮动底栏抬升是两套设计系统共用的同一口径（字幕避让 / 刻度 / 预览同源）', () {
      expect(page.contains('_appleBottomLift'), isFalse);
      expect(page, contains('double get _floatingChromeBottomLift'));
    });
  });
}

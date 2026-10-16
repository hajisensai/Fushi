import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_m3e_chrome.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart'
    show ReaderPanelSwitcher;

void main() {
  testWidgets('VideoTranslucentSidePanel keeps the video area visible', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            const ColoredBox(color: Colors.green),
            VideoTranslucentSidePanel(
              title: 'Speed',
              onClose: () {},
              child: const Text('1.5x'),
            ),
          ],
        ),
      ),
    );

    final Material material = tester.widget<Material>(
      find
          .ancestor(of: find.text('Speed'), matching: find.byType(Material))
          .first,
    );
    // M3E：面板读以 app 主色为种子、与 app 同亮度的着色方案（2026-10-14 去灰：与
    // 阅读器侧板同一套表面层级），底色是该方案的 surfaceContainerLow（半透明档）；
    // 画面靠面板四周的留白与面板宽度露出。
    final ColorScheme appScheme = Theme.of(
      tester.element(find.byType(VideoTranslucentSidePanel)),
    ).colorScheme;
    expect(material.color, videoM3ePanelSurfaceColor(appScheme, opaque: false));
    // 面板内容跟随 app 的日间 / 深色模式（默认 MaterialApp 是日间 → 浅色面板）。
    final BuildContext ctx = tester.element(find.text('Speed'));
    final ColorScheme panelScheme = Theme.of(ctx).colorScheme;
    expect(panelScheme.brightness, appScheme.brightness);
    expect(panelScheme.onSurface, videoM3ePanelScheme(appScheme).onSurface);
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('1.5x'), findsOneWidget);
    // BUG-254：右上角 X 关闭按钮已删除（关闭改由页面层全屏 barrier 点面板外承载）。
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('VideoTranslucentSidePanel mirrors rounded side on the left', (
    WidgetTester tester,
  ) async {
    Future<Material> pumpPanel(Alignment alignment) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 800,
            height: 480,
            child: VideoTranslucentSidePanel(
              title: alignment == Alignment.centerLeft ? 'Left' : 'Right',
              alignment: alignment,
              child: const Text('Panel'),
            ),
          ),
        ),
      );
      // 面板带滑入进场动效，等它落位再量几何。
      await tester.pumpAndSettle();
      return tester.widget<Material>(
        find
            .ancestor(
              of: find.text(
                alignment == Alignment.centerLeft ? 'Left' : 'Right',
              ),
              matching: find.byType(Material),
            )
            .first,
      );
    }

    // 面板不再是「贴边抽屉」：它四边都留 10 的安全间距浮在画面上，所以四个角都
    // 该露出来（PR #800）。旧断言要求只在靠画面那一侧加圆角、外侧留直角——那是
    // 贴边形态的契约，面板改成浮动卡片后它描述的是已经不存在的外观。
    //
    // 镜像这件事因此从「圆角换边」挪到了**位置**上：左对齐贴左、右对齐贴右，两侧
    // 各留同一个 10 的间距；圆角则两边完全一致。两条一起断，退回半圆角抽屉、或
    // 左右间距不对称，都当场红。
    // MD3 Expressive 浮动面板圆角 28（四角一致）。
    const BorderRadius floatingRadius = BorderRadius.all(Radius.circular(28));
    BorderRadiusGeometry? radiusOf(Material m) =>
        (m.shape as RoundedRectangleBorder?)?.borderRadius;

    final Material left = await pumpPanel(Alignment.centerLeft);
    expect(
      radiusOf(left),
      floatingRadius,
      reason: '浮动侧栏四边都有间距，四个角都应是圆角（不是贴边抽屉的半圆角）',
    );
    expect(
      tester.getTopLeft(find.byType(Material).last).dx,
      10,
      reason: '左对齐时面板贴左，留 10 的安全间距',
    );

    final Material right = await pumpPanel(Alignment.centerRight);
    expect(
      radiusOf(right),
      floatingRadius,
      reason: '左右两侧圆角必须一致——镜像体现在位置上，不再体现在圆角换边',
    );
    expect(
      tester.getTopRight(find.byType(Material).last).dx,
      790,
      reason: '右对齐时面板贴右，留同样 10 的安全间距（800 - 10）',
    );
  });

  testWidgets(
    'phone portrait: bottomSheetWhenCompact docks the panel to the bottom '
    'without a title header',
    (WidgetTester tester) async {
      // 视频设置面板重设计（反馈 nGxUGtYot9）：手机竖屏（宽 < 600）贴底升起、只圆上
      // 两角、顶上一条拖动把手；title 为 null 时不画「视频设置」大标题页头。
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(384, 853);
      addTearDown(tester.view.reset);
      int closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: <Widget>[
              const ColoredBox(color: Colors.green),
              VideoTranslucentSidePanel(
                bottomSheetWhenCompact: true,
                onClose: () => closed++,
                child: const Text('Tabs + content'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Rect sheet = tester.getRect(
        find.byKey(const ValueKey<String>('video-side-panel-bottom-sheet')),
      );
      expect(sheet.bottom, 853, reason: '贴底');
      expect(sheet.width, 384, reason: '手机竖屏吃满宽');
      expect(
        sheet.height,
        closeTo(853 * VideoTranslucentSidePanel.bottomSheetHeightFraction, 0.5),
        reason: '半屏高，画面中部不被整列盖住',
      );
      final Material material = tester.widget<Material>(
        find
            .ancestor(
              of: find.text('Tabs + content'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        (material.shape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.vertical(top: Radius.circular(28)),
      );

      // 把手：点按关闭。
      await tester.tap(
        find.byKey(const ValueKey<String>('video-side-panel-drag-handle')),
      );
      expect(closed, 1);
    },
  );

  testWidgets('wide windows keep the floating side panel even when '
      'bottomSheetWhenCompact is set', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(853, 384);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoTranslucentSidePanel(
          bottomSheetWhenCompact: true,
          width: 400,
          child: const Text('Tabs + content'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video-side-panel-bottom-sheet')),
      findsNothing,
    );
    final Rect panel = tester.getRect(
      find
          .ancestor(
            of: find.text('Tabs + content'),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(panel.width, 400);
    expect(panel.right, 853 - 10, reason: '右对齐侧板，留 10 安全间距');
  });

  /// 面板切换条（字幕 / 音频 / 设置……）的测试替身：[selected] 记录点了哪个。
  ReaderPanelSwitcher switcherFor(
    ValueNotifier<String> current,
    List<String> selected,
  ) {
    return ReaderPanelSwitcher(
      items: const <({String id, IconData icon, String label})>[
        (id: 'subtitle', icon: Icons.subtitles, label: 'Subtitles'),
        (id: 'audio', icon: Icons.audiotrack, label: 'Audio'),
        (id: 'settings', icon: Icons.settings, label: 'Settings'),
      ],
      current: current,
      onSelect: (String id) {
        selected.add(id);
        current.value = id;
      },
    );
  }

  testWidgets('side panel hangs a vertical switcher rail on the video side', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    final ValueNotifier<String> current = ValueNotifier<String>('settings');
    addTearDown(current.dispose);
    final List<String> selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: VideoTranslucentSidePanel(
          width: 400,
          switcher: switcherFor(current, selected),
          child: const Text('Panel content'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder rail = find.byKey(
      const ValueKey<String>('video_panel_switcher'),
    );
    expect(rail, findsOneWidget);
    final Rect railRect = tester.getRect(rail);
    final Rect panel = tester.getRect(
      find
          .ancestor(
            of: find.text('Panel content'),
            matching: find.byType(Material),
          )
          .first,
    );
    // 右停靠：切换条在面板左侧（朝画面），纵向排列。
    expect(railRect.right, lessThanOrEqualTo(panel.left));
    expect(railRect.height, greaterThan(railRect.width));

    await tester.tap(
      find.byKey(const ValueKey<String>('video_panel_switch_subtitle')),
    );
    await tester.pump();
    expect(selected, <String>['subtitle']);
  });

  // 播放器面板 + 面板切换竖条跟随 app 的日间 / 深色模式，且二者同一份配色
  // （2026-10-14 用户：日间模式下设置面板是固定深色、旁边的竖条却是浅色）。
  for (final Brightness appBrightness in Brightness.values) {
    testWidgets(
      'panel and switcher rail both follow app ${appBrightness.name} mode',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 720);
        addTearDown(tester.view.reset);
        final ValueNotifier<String> current = ValueNotifier<String>('settings');
        addTearDown(current.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF6750A4),
                brightness: appBrightness,
              ),
            ),
            home: VideoTranslucentSidePanel(
              width: 400,
              switcher: switcherFor(current, <String>[]),
              child: const Text('Panel content'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final ColorScheme appScheme = Theme.of(
          tester.element(find.byType(VideoTranslucentSidePanel)),
        ).colorScheme;
        final ColorScheme panelScheme = Theme.of(
          tester.element(find.text('Panel content')),
        ).colorScheme;
        final ColorScheme railScheme = Theme.of(
          tester.element(
            find.byKey(const ValueKey<String>('video_panel_switch_audio')),
          ),
        ).colorScheme;
        expect(panelScheme.brightness, appBrightness);
        expect(railScheme.brightness, appBrightness);
        // 竖条与面板读的是同一份方案（不是一份面板方案 + 一份 app 方案）。
        expect(railScheme, panelScheme);
        expect(panelScheme, videoM3ePanelScheme(appScheme));
      },
    );
  }

  test(
    'panel / chrome schemes are cached per brightness, not just primary',
    () {
      // 同一主色：浅色 app 主题拿到浅色方案、深色拿深色方案；先后调用不串缓存。
      const Color seed = Color(0xFF386A20);
      final ColorScheme light = ColorScheme.fromSeed(seedColor: seed);
      final ColorScheme dark = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      );
      final ColorScheme sameLight = light.copyWith(primary: dark.primary);
      final ColorScheme sameDark = dark;
      expect(videoM3ePanelScheme(sameDark).brightness, Brightness.dark);
      expect(videoM3ePanelScheme(sameLight).brightness, Brightness.light);
      expect(videoM3eChromeScheme(sameLight).brightness, Brightness.light);
      expect(videoM3eChromeScheme(sameDark).brightness, Brightness.dark);
      expect(
        videoM3eNeutralChromeScheme(sameLight).brightness,
        Brightness.light,
      );
      expect(videoM3eNeutralChromeScheme(sameDark).brightness, Brightness.dark);
      // 日间：浅底深字；深色：深底白字（与旧实现一致）。
      expect(videoM3eForeground(sameDark), Colors.white);
      expect(videoM3eForeground(sameLight).computeLuminance(), lessThan(0.05));
      expect(
        videoM3eFloatingColor(
          sameLight,
        ).withValues(alpha: 1).computeLuminance(),
        greaterThan(0.6),
      );
      expect(
        videoM3eFloatingColor(sameDark).withValues(alpha: 1).computeLuminance(),
        lessThan(0.1),
      );
      expect(
        videoM3ePanelSurfaceColor(sameLight, opaque: true).computeLuminance(),
        greaterThan(0.6),
      );
      expect(videoM3ePanelBackdrop(sameDark), Colors.black);
      expect(
        videoM3ePanelBackdrop(sameLight).computeLuminance(),
        greaterThan(0.6),
      );
    },
  );

  testWidgets('a single-item switcher draws no rail', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoTranslucentSidePanel(
          width: 400,
          switcher: ReaderPanelSwitcher(
            items: const <({String id, IconData icon, String label})>[
              (id: 'settings', icon: Icons.settings, label: 'Settings'),
            ],
            current: ValueNotifier<String>('settings'),
            onSelect: (_) {},
          ),
          child: const Text('Panel content'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('video_panel_switcher')),
      findsNothing,
    );
  });

  testWidgets('phone portrait: switcher is a horizontal row under the handle '
      'and the sheet drags between half and expanded detents', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(384, 853);
    addTearDown(tester.view.reset);
    final ValueNotifier<String> current = ValueNotifier<String>('settings');
    addTearDown(current.dispose);
    final List<String> selected = <String>[];
    int closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            const ColoredBox(color: Colors.green),
            VideoTranslucentSidePanel(
              bottomSheetWhenCompact: true,
              title: 'Settings',
              switcher: switcherFor(current, selected),
              onClose: () => closed++,
              child: const Text('Panel content'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder sheet = find.byKey(
      const ValueKey<String>('video-side-panel-bottom-sheet'),
    );
    final Finder rail = find.byKey(
      const ValueKey<String>('video_panel_switcher'),
    );
    expect(rail, findsOneWidget);
    final Rect railRect = tester.getRect(rail);
    expect(railRect.width, greaterThan(railRect.height), reason: '横向一排');
    final Rect handle = tester.getRect(
      find.byKey(const ValueKey<String>('video-side-panel-drag-handle')),
    );
    expect(railRect.top, greaterThanOrEqualTo(handle.bottom));
    // 切换条代替页头标题（切换条本身已标明当前面板）。
    expect(find.text('Settings'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('video_panel_switch_audio')),
    );
    await tester.pump();
    expect(selected, <String>['audio']);

    // 上拉把手：停到展开档。
    expect(
      tester.getRect(sheet).height,
      closeTo(853 * VideoTranslucentSidePanel.bottomSheetHeightFraction, 0.5),
    );
    await tester.drag(
      find.byKey(const ValueKey<String>('video-side-panel-drag-handle')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(sheet).height,
      closeTo(853 * VideoTranslucentSidePanel.bottomSheetExpandedFraction, 0.5),
    );
    expect(closed, 0);

    // 下拉回半屏，再往下甩关闭。
    await tester.drag(
      find.byKey(const ValueKey<String>('video-side-panel-drag-handle')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(sheet).height,
      closeTo(853 * VideoTranslucentSidePanel.bottomSheetHeightFraction, 0.5),
    );
    await tester.fling(
      find.byKey(const ValueKey<String>('video-side-panel-drag-handle')),
      const Offset(0, 200),
      1500,
    );
    await tester.pumpAndSettle();
    expect(closed, 1);
  });

  testWidgets('touch fling on the panel content switches to the adjacent '
      'panel; mouse drags and slow drags do not', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(384, 853);
    addTearDown(tester.view.reset);
    final ValueNotifier<String> current = ValueNotifier<String>('audio');
    addTearDown(current.dispose);
    final List<String> selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: VideoTranslucentSidePanel(
          bottomSheetWhenCompact: true,
          switcher: switcherFor(current, selected),
          child: const SizedBox.expand(child: Text('Panel content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder content = find.text('Panel content');

    // 左甩：下一个面板（audio → settings）。
    await tester.fling(content, const Offset(-200, 0), 1500);
    await tester.pumpAndSettle();
    expect(selected, <String>['settings']);

    // 已在最后一个：再左甩不循环。
    await tester.fling(content, const Offset(-200, 0), 1500);
    await tester.pumpAndSettle();
    expect(selected, <String>['settings']);

    // 右甩：上一个面板（settings → audio）。
    await tester.fling(content, const Offset(200, 0), 1500);
    await tester.pumpAndSettle();
    expect(selected, <String>['settings', 'audio']);

    // 慢拖（不是甩动）不切。
    await tester.timedDrag(
      content,
      const Offset(-200, 0),
      const Duration(seconds: 2),
    );
    await tester.pumpAndSettle();
    expect(selected, <String>['settings', 'audio']);

    // 鼠标拖动不切（桌面不误触）。
    await tester.fling(
      content,
      const Offset(-200, 0),
      1500,
      deviceKind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(selected, <String>['settings', 'audio']);
  });
}

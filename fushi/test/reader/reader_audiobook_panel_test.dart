import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/utils.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(height: 700, child: child)),
    );

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  testWidgets('无控制器：信息卡给导入按钮；资源页只有可用入口；章节页列目录并标当前章', (tester) async {
    int imports = 0;
    int jumped = -1;
    await tester.pumpWidget(_host(ReaderAudiobookPanel(
      controller: null,
      toc: const <TtuTocEntry>[
        TtuTocEntry(index: 0, label: '表紙'),
        TtuTocEntry(index: 3, label: '第一話'),
        TtuTocEntry(index: 7, label: '第二話'),
      ],
      currentSection: 5,
      onJumpSection: (int i, String? _) async => jumped = i,
      title: '無職転生 20',
      chapterLabel: '第一話',
      coverPath: null,
      settingsBuilder: (_) => const Text('SETTINGS_TAB'),
      onAudioImport: () => imports++,
      onPickAlignment: null,
      onTranscribe: null,
    )));
    await tester.pump();

    // 默认章节页：三条目录，「当前章节」标在 index<=5 的最后一条（第一話）。
    expect(find.text('第一話'), findsNWidgets(2)); // 章节标签 + 列表行
    expect(find.text(t.reader_audiobook_current_chapter), findsOneWidget);
    await tester.tap(find.text('第二話'));
    await tester.pumpAndSettle();
    expect(jumped, 7);
  });

  testWidgets('资源页：对齐 / 转录入口按回调是否为 null 显隐；设置页走 settingsBuilder',
      (tester) async {
    int align = 0;
    await tester.pumpWidget(_host(ReaderAudiobookPanel(
      controller: null,
      toc: const <TtuTocEntry>[],
      currentSection: 0,
      onJumpSection: (_, __) async {},
      title: 'Book',
      chapterLabel: null,
      coverPath: null,
      settingsBuilder: (_) => const Text('SETTINGS_TAB'),
      onAudioImport: () {},
      onPickAlignment: () => align++,
      onTranscribe: null,
      initialTab: 'files',
    )));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_panel_alignment')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_panel_transcribe')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_panel_import')),
      findsOneWidget,
    );
    // 切到设置 tab。
    await tester.tap(find.text(t.settings));
    await tester.pumpAndSettle();
    expect(find.text('SETTINGS_TAB'), findsOneWidget);
  });

  testWidgets('切换 tab 从顶部显示，不继承章节滚动位置', (tester) async {
    await tester.pumpWidget(
      _host(
        ReaderAudiobookPanel(
          controller: null,
          toc: List<TtuTocEntry>.generate(
            40,
            (int i) => TtuTocEntry(index: i, label: 'Chapter $i'),
          ),
          currentSection: 0,
          onJumpSection: (_, __) async {},
          title: 'Book',
          chapterLabel: null,
          coverPath: null,
          settingsBuilder: (_) => Column(
            children: List<Widget>.generate(
              30,
              (int i) => SizedBox(height: 80, child: Text('Setting $i')),
            ),
          ),
        ),
      ),
    );
    final Finder scrollable = find.descendant(
      of: find.byKey(const ValueKey<String>('fushi_audiobook_scroll_chapters')),
      matching: find.byType(Scrollable),
    );
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    await tester.tap(find.text(t.settings));
    await tester.pumpAndSettle();
    final Finder settingsScroll = find.descendant(
      of: find.byKey(const ValueKey<String>('fushi_audiobook_scroll_settings')),
      matching: find.byType(Scrollable),
    );
    expect(tester.state<ScrollableState>(settingsScroll).position.pixels, 0);
    expect(find.text('Setting 0').hitTestable(), findsOneWidget);
  });

  testWidgets('资源 / 章节 / 设置是 MD3 标签页而非分段控制器，指示器跟随切换', (tester) async {
    await tester.pumpWidget(_host(ReaderAudiobookPanel(
      controller: null,
      toc: const <TtuTocEntry>[TtuTocEntry(index: 0, label: 'Chapter A')],
      currentSection: 0,
      onJumpSection: (_, __) async {},
      title: 'Book',
      chapterLabel: null,
      coverPath: null,
      settingsBuilder: (_) => const Text('SETTINGS_TAB'),
      onAudioImport: () {},
    )));
    await tester.pump();
    expect(find.byType(SegmentedButton<String>), findsNothing);
    final Finder bar = find.byType(TabBar);
    expect(bar, findsOneWidget);
    TabController controller() => tester.widget<TabBar>(bar).controller!;
    expect(controller().length, kReaderAudiobookPanelTabs.length);
    // 默认章节页。
    expect(controller().index, kReaderAudiobookPanelTabs.indexOf('chapters'));
    expect(find.text('Chapter A'), findsOneWidget);

    for (final String id in <String>['files', 'settings', 'chapters']) {
      await tester.tap(
        find.byKey(ValueKey<String>('fushi_audiobook_tab_button_$id')),
      );
      await tester.pumpAndSettle();
      expect(controller().index, kReaderAudiobookPanelTabs.indexOf(id));
      expect(
        find.byKey(ValueKey<String>('fushi_audiobook_tab_$id')),
        findsOneWidget,
      );
    }
    expect(find.text('Chapter A'), findsOneWidget);
  });

  testWidgets('initialTab 决定首个选中的标签页', (tester) async {
    await tester.pumpWidget(_host(ReaderAudiobookPanel(
      controller: null,
      toc: const <TtuTocEntry>[],
      currentSection: 0,
      onJumpSection: (_, __) async {},
      title: 'Book',
      chapterLabel: null,
      coverPath: null,
      settingsBuilder: (_) => const Text('SETTINGS_TAB'),
      initialTab: 'settings',
    )));
    await tester.pump();
    expect(
      tester.widget<TabBar>(find.byType(TabBar)).controller!.index,
      kReaderAudiobookPanelTabs.indexOf('settings'),
    );
    expect(find.text('SETTINGS_TAB'), findsOneWidget);
  });

  for (final double width in <double>[320, 360, 560, 900]) {
    testWidgets('有封面时宽度 $width 的五个播放按钮均留在面板内', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final AudiobookPlayerController controller = AudiobookPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          ReaderAudiobookPanel(
            controller: controller,
            toc: const <TtuTocEntry>[],
            currentSection: 0,
            onJumpSection: (_, __) async {},
            title: '安達としまむら3',
            chapterLabel: '一章「私に相応しいチョコを決めてください」',
            coverPath: 'missing-test-cover.png',
            settingsBuilder: (_) => const Text('Settings'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final Rect panel = tester.getRect(find.byType(ReaderAudiobookPanel));
      for (final IconData icon in <IconData>[
        Icons.replay_10_outlined,
        Icons.skip_previous_outlined,
        Icons.play_arrow_outlined,
        Icons.skip_next_outlined,
        Icons.forward_10_outlined,
      ]) {
        final Finder button = find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        );
        final Rect rect = tester.getRect(button);
        expect(panel.contains(rect.topLeft), isTrue);
        expect(panel.contains(rect.bottomRight), isTrue);
      }
      final Rect cover = tester.getRect(
        find.byKey(const ValueKey<String>('fushi_audiobook_cover')),
      );
      final Rect play = tester.getRect(
        find.byKey(const ValueKey<String>('fushi_audiobook_panel_play')),
      );
      if (width <= 360) {
        expect(play.top, greaterThanOrEqualTo(cover.bottom));
      } else {
        expect(play.left, greaterThan(cover.right));
      }
    });
  }

  testWidgets('顶部工具栏紧凑形态：非 pinned 动作收进 ⋮ 溢出菜单', (tester) async {
    int gallery = 0;
    final List<ReaderHeaderAction> leading = <ReaderHeaderAction>[
      ReaderHeaderAction(
        icon: Icons.arrow_back,
        label: 'back',
        pinned: true,
        onPressed: () {},
      ),
      ReaderHeaderAction(
        icon: Icons.collections_outlined,
        label: 'gallery',
        onPressed: () => gallery++,
      ),
    ];
    final List<ReaderHeaderAction> trailing = <ReaderHeaderAction>[
      ReaderHeaderAction(
        icon: Icons.tune_outlined,
        label: 'settings',
        pinned: true,
        onPressed: () {},
      ),
    ];
    expect(
      readerHeaderOverflow(
          compact: false, leading: leading, trailing: trailing),
      isEmpty,
    );
    expect(
      readerHeaderOverflow(compact: true, leading: leading, trailing: trailing)
          .map((a) => a.label),
      <String>['gallery'],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            // 三颗按钮（48 each）+ 两端 16 内边距之后，留给书名的不足
            // kReaderDesktopHeaderTitleMinWidth(120) —— 这一栏是真的放不下才折叠，
            // 不再是撞上一条与内容无关的固定窗宽阈值。
            width: 260,
            child: ReaderDesktopHeader(
              title: 'T',
              leading: leading,
              trailing: trailing,
              textColor: Colors.white,
              backgroundColor: Colors.black,
            ),
          ),
        ),
      ),
    ));
    expect(find.byIcon(Icons.collections_outlined), findsNothing);
    final Finder more =
        find.byKey(const ValueKey<String>('fushi_desktop_header_overflow'));
    expect(more, findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.tap(find.text('gallery'));
    await tester.pumpAndSettle();
    expect(gallery, 1);
  });

  // BUG-2528：手机横屏的 bottom sheet 只有 0.9×348≈313dp 高，固定部分（标题行 +
  // 信息卡 + 标签栏）实测就占 312dp。旧版恒为 Column(min)+Flexible，Flexible 在
  // 高度不够时不报 overflow 而是被压到 ~0：tab 视口只剩 1.2px、maxScrollExtent
  // 近乎 0，标签栏以下的资源 / 章节 / 设置既看不见又滚不出来。
  testWidgets('矮窗（手机横屏）：整块面板可滚，标签栏以下的内容能滚出来', (tester) async {
    await tester.binding.setSurfaceSize(const Size(768, 348));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          // showModalBottomSheet 那条路径给面板的高度（chrome.part.dart）。
          child: SizedBox(
            height: 348 * 0.9,
            child: ReaderAudiobookPanel(
              controller: controller,
              toc: const <TtuTocEntry>[TtuTocEntry(index: 0, label: '一章')],
              currentSection: 0,
              onJumpSection: (_, __) async {},
              title: '安達としまむら3',
              chapterLabel: '一章「私に相応しいチョコを決めてください」',
              coverPath: 'missing-test-cover.png',
              settingsBuilder: (_) => const Text('SETTINGS_TAB'),
              initialTab: 'settings',
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(readerAudiobookPanelPinsHero(348 * 0.9), isFalse);

    final Finder scroll =
        find.byKey(const ValueKey<String>('fushi_audiobook_scroll_settings'));
    final ScrollableState state = tester.state<ScrollableState>(
      find.descendant(of: scroll, matching: find.byType(Scrollable)),
    );
    // 滚动区覆盖整块面板（含信息卡），而不是被压扁的 tab 视口。
    expect(
      tester.getRect(scroll).height,
      greaterThan(tester.getRect(find.byType(ReaderAudiobookPanel)).height / 2),
    );
    expect(state.position.maxScrollExtent, greaterThan(0));

    // 滚到底 → 标签栏下面的 tab 内容真的露出来且可点。
    expect(find.text('SETTINGS_TAB').hitTestable(), findsNothing);
    await tester.drag(scroll, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('SETTINGS_TAB').hitTestable(), findsOneWidget);
  });

  testWidgets('高窗：信息卡仍钉住，只有 tab 内容滚', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReaderAudiobookPanel(
          controller: controller,
          toc: List<TtuTocEntry>.generate(
            40,
            (int i) => TtuTocEntry(index: i, label: 'Chapter $i'),
          ),
          currentSection: 0,
          onJumpSection: (_, __) async {},
          title: 'Book',
          chapterLabel: null,
          coverPath: 'missing-test-cover.png',
          settingsBuilder: (_) => const Text('SETTINGS_TAB'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(readerAudiobookPanelPinsHero(800), isTrue);
    final Finder cover =
        find.byKey(const ValueKey<String>('fushi_audiobook_cover'));
    final double coverTop = tester.getRect(cover).top;
    final Finder scroll =
        find.byKey(const ValueKey<String>('fushi_audiobook_scroll_chapters'));
    await tester.drag(scroll, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<ScrollableState>(
            find.descendant(of: scroll, matching: find.byType(Scrollable)),
          )
          .position
          .pixels,
      greaterThan(0),
    );
    expect(tester.getRect(cover).top, coverTop);
  });

  // 章节刻度曾是 slider 下方单独一条 CustomPaint、左右硬写 24px 内缩，而
  // slider 轨道内缩是 max(overlay, thumb)/2 = 12px：刻度整体往中间压，拇指走到
  // 章首时与刻度错开。现在刻度画在 slider 自己的轨道上，这里钉住「值 = 章首
  // 位置时，拇指中心与刻度同一 x」。
  for (final double fraction in <double>[0.1, 0.5, 0.9]) {
    testWidgets('章节刻度与拇指对齐（fraction=$fraction）', (tester) async {
      const double width = 400;
      final SliderThemeData theme = SliderThemeData(
        trackHeight: 3,
        trackShape: ReaderAudiobookChapterTrackShape(
          fractions: <double>[fraction],
          tickColor: const Color(0xFF123456),
        ),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: SliderTheme(
                  data: theme,
                  child: Slider(value: fraction, onChanged: (_) {}),
                ),
              ),
            ),
          ),
        ),
      );
      final RenderBox box = tester.renderObject<RenderBox>(
        find.byWidgetPredicate(
          (Widget w) => w.runtimeType.toString() == '_SliderRenderObjectWidget',
        ),
      );
      final Rect track = theme.trackShape!.getPreferredRect(
        parentBox: box,
        sliderTheme: theme,
        isEnabled: true,
      );
      // 轨道内缩由 overlay 决定（12px），不是旧刻度条的 24px。
      expect(track.left, 12);
      expect(track.width, box.size.width - 24);
      final double x = track.left + fraction * track.width;
      expect(
        ReaderAudiobookChapterTrackShape.tickX(
          track,
          fraction,
          TextDirection.ltr,
        ),
        x,
      );
      final double half = track.height / 2 + 3;
      expect(
        box,
        paints
          ..line(
            p1: Offset(x, track.center.dy - half),
            p2: Offset(x, track.center.dy + half),
            color: const Color(0xFF123456),
          ),
      );
      // 拇指（RoundSliderThumbShape 画在中心的圆）与刻度同一 x。
      expect(box, paints..circle(x: x, y: track.center.dy, radius: 6));
    });
  }
}

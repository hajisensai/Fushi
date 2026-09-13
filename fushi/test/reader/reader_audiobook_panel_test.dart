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
            width: 600, // < kReaderDesktopHeaderCompactWidth
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
}

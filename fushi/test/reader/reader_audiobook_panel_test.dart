import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      onJumpSection: (int i) async => jumped = i,
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
      onJumpSection: (_) async {},
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

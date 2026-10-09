import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart';
import 'package:fushi/utils.dart';

/// 有声书侧板（2026-10 重设计）：正在播放卡 + 章节列表；章节页顶部是收听概览与
/// 「对齐与转录」卡（资源操作）。2026-10-09 起不再有「设置」页签（播放设置并进
/// 「阅读设置 › 有声书」页）。
Widget _host(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: size.width, height: size.height, child: child),
    ),
  ),
);

ReaderAudiobookPanel _panel({
  List<TtuTocEntry> toc = const <TtuTocEntry>[],
  int currentSection = 0,
  Future<void> Function(int, String?)? onJump,
  VoidCallback? onImport,
  VoidCallback? onPickAlignment,
  VoidCallback? onTranscribe,
}) => ReaderAudiobookPanel(
  controller: null,
  toc: toc,
  currentSection: currentSection,
  onJumpSection: onJump ?? (_, __) async {},
  title: 'Book',
  chapterLabel: null,
  coverPath: null,
  onAudioImport: onImport,
  onPickAlignment: onPickAlignment,
  onTranscribe: onTranscribe,
);

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  testWidgets('面板没有页签栏（「设置」页签已移除，只剩章节）', (tester) async {
    await tester.pumpWidget(_host(_panel(onImport: () {})));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_tab_button_settings')),
      findsNothing,
    );
    expect(find.byType(ReaderPanelTabs<String>), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_tab_chapters')),
      findsOneWidget,
    );
  });

  testWidgets('无控制器：正在播放卡给导入入口，没有句子页签', (tester) async {
    await tester.pumpWidget(_host(_panel(onImport: () {})));
    await tester.pump();
    // 正在播放卡（无控制器时的空态）给导入入口；章节页的「对齐与转录」卡也有
    // 一个导入按钮（059b4bd7f36），所以按卡片限定范围。
    expect(
      find.descendant(
        of: find.byType(ReaderPanelEmpty),
        matching: find.text(t.audio_import),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('fushi_audiobook_tab_button_sentences'),
      ),
      findsNothing,
    );
  });

  testWidgets('章节页列目录并标当前章，点击跳章', (tester) async {
    int jumped = -1;
    await tester.pumpWidget(
      _host(
        _panel(
          toc: const <TtuTocEntry>[
            TtuTocEntry(index: 0, label: '表紙'),
            TtuTocEntry(index: 3, label: '第一話'),
            TtuTocEntry(index: 7, label: '第二話'),
          ],
          currentSection: 5,
          onJump: (int i, String? _) async => jumped = i,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining(t.reader_audiobook_current_chapter),
      findsOneWidget,
    );
    await tester.tap(find.text('第二話'));
    await tester.pumpAndSettle();
    expect(jumped, 7);
  });

  testWidgets('章节页顶部：对齐与转录卡按回调显隐（2026-10-06 从设置页挪来）', (tester) async {
    await tester.pumpWidget(
      _host(_panel(onImport: () {}, onPickAlignment: () {})),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.reader_audiobook_section_tools), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_source_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_panel_alignment')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_audiobook_panel_transcribe')),
      findsNothing,
    );
  });

  for (final Size size in <Size>[
    const Size(400, 900),
    const Size(420, 760),
    const Size(768, 348),
  ]) {
    testWidgets('不溢出 @ $size', (tester) async {
      await tester.pumpWidget(
        _host(
          _panel(
            toc: List<TtuTocEntry>.generate(
              30,
              (int i) => TtuTocEntry(index: i, label: 'Chapter $i'),
            ),
          ),
          size: size,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

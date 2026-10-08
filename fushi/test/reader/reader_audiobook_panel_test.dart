import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/reader/reader_panel_chrome_kit.dart';
import 'package:fushi/utils.dart';

/// 有声书侧板（2026-10 重设计）：正在播放卡 + 「章节 / 设置」页签；章节页顶部是
/// 收听概览与「对齐与转录」卡（资源操作），设置页只放 settingsBuilder。
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
  String initialTab = 'chapters',
}) => ReaderAudiobookPanel(
  controller: null,
  toc: toc,
  currentSection: currentSection,
  onJumpSection: onJump ?? (_, __) async {},
  title: 'Book',
  chapterLabel: null,
  coverPath: null,
  settingsBuilder: (_) => const Text('SETTINGS_TAB'),
  onAudioImport: onImport,
  onPickAlignment: onPickAlignment,
  onTranscribe: onTranscribe,
  initialTab: initialTab,
);

void main() {
  setUpAll(() => LocaleSettings.setLocale(AppLocale.zhCn));

  test('页签顺序：章节 / 设置，默认章节（句子页签已移除）', () {
    expect(kReaderAudiobookPanelTabs, <String>['chapters', 'settings']);
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
          initialTab: 'chapters',
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

  testWidgets('设置页只放 settingsBuilder', (tester) async {
    await tester.pumpWidget(
      _host(
        _panel(onImport: () {}, onPickAlignment: () {}, initialTab: 'settings'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SETTINGS_TAB'), findsOneWidget);
    expect(find.text(t.reader_audiobook_section_tools), findsNothing);
  });

  testWidgets('章节页顶部：对齐与转录卡按回调显隐（2026-10-06 从设置页挪来）', (tester) async {
    await tester.pumpWidget(
      _host(
        _panel(onImport: () {}, onPickAlignment: () {}, initialTab: 'chapters'),
      ),
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
            initialTab: 'chapters',
          ),
          size: size,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

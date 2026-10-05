import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/utils.dart';

/// 有声书侧板（2026-10 重设计）：正在播放卡 + 「句子 / 章节 / 设置」页签；资源
/// （对齐 / 转录 / 导入）收进设置页底部的次级分组。
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
  String initialTab = 'sentences',
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

  test('页签顺序：句子 / 章节 / 设置，默认句子', () {
    expect(kReaderAudiobookPanelTabs, <String>[
      'sentences',
      'chapters',
      'settings',
    ]);
  });

  testWidgets('无控制器：句子页给空态，正在播放卡给导入入口', (tester) async {
    await tester.pumpWidget(_host(_panel(onImport: () {})));
    await tester.pump();
    expect(find.text(t.reader_audiobook_no_sentences), findsOneWidget);
    expect(find.text(t.audio_import), findsOneWidget);
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

  testWidgets('设置页：settingsBuilder + 资源次级分组按回调显隐', (tester) async {
    await tester.pumpWidget(
      _host(
        _panel(onImport: () {}, onPickAlignment: () {}, initialTab: 'settings'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SETTINGS_TAB'), findsOneWidget);
    expect(find.text(t.reader_audiobook_section_tools), findsOneWidget);
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

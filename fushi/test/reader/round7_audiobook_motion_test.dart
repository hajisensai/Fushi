// 有声书侧栏当前章自动定位的回归测试（Round7 审查复现迁入）。
// HBK045（章节↔设置页签反切）随 2026-10-09 移除「设置」页签而不复存在：面板只剩
// 章节一页，没有页签切换。
// HBK046：第 80/100 章 + 多行长标题 + 200% 文字，点「定位当前章」后估算跳转的
//         目标仍未构建时要继续收敛，直到当前章确实可见（打开时不自动定位）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

const Key _chaptersKey = ValueKey<String>('fushi_audiobook_chapters');
const Key _revealKey = ValueKey<String>(
  'fushi_audiobook_reveal_current_chapter',
);

Future<void> _pumpPanel(
  WidgetTester tester, {
  int current = 0,
  bool longTitles = false,
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        splashFactory: NoSplash.splashFactory,
        extensions: const <ThemeExtension<dynamic>>[FushiEinkTheme(false)],
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: ReaderAudiobookPanel(
          controller: null,
          toc: List<TtuTocEntry>.generate(
            100,
            (int i) => TtuTocEntry(index: i, label: _title(i, longTitles)),
          ),
          currentSection: current,
          onJumpSection: (int _, String? __) async {},
          title: 'Book',
          chapterLabel: null,
          coverPath: null,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

String _title(int i, bool longTitles) => longTitles
    ? 'Chapter $i: An exceptionally long chapter title that wraps across '
          'multiple lines in the audiobook navigation panel'
    : 'Chapter $i';

void main() {
  testWidgets(
    'current distant long chapter is revealed on demand at text scale two',
    (WidgetTester tester) async {
      await _pumpPanel(
        tester,
        current: 80,
        longTitles: true,
        textScale: 2,
        reduceMotion: true,
      );
      final ListView list = tester.widget<ListView>(find.byKey(_chaptersKey));
      // Opening keeps the list at the top (2026-10-07: the user must see the
      // overview / alignment actions first); revealing is an explicit action.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(list.controller!.offset, 0);
      await tester.tap(find.byKey(_revealKey));
      await tester.pumpAndSettle();
      final Finder rowText = find.text(_title(80, true));
      expect(
        rowText,
        findsOneWidget,
        reason:
            'The current chapter must be built and exposed after reveal; '
            'offset=${list.controller!.offset}, max=${list.controller!.position.maxScrollExtent}',
      );
      final Rect viewport = tester.getRect(find.byKey(_chaptersKey));
      final Rect row = tester.getRect(rowText);
      expect(row.top, greaterThanOrEqualTo(viewport.top));
      expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
      // Repeating the same explicit request after manual scrolling must work.
      list.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_revealKey));
      await tester.pumpAndSettle();
      final Rect revealedAgain = tester.getRect(rowText);
      expect(revealedAgain.top, greaterThanOrEqualTo(viewport.top));
      expect(revealedAgain.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ticker does not undo manual chapter scroll in the same chapter',
    (WidgetTester tester) async {
      await _pumpPanel(tester, reduceMotion: true);
      final ListView list = tester.widget<ListView>(find.byKey(_chaptersKey));
      list.controller!.jumpTo(800);
      await tester.pump();
      final double before = list.controller!.offset;
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(list.controller!.offset, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

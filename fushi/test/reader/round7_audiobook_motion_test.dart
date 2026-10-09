// 有声书侧栏页签切换与当前章自动定位的回归测试（Round7 审查复现迁入）。
// HBK045：章节→设置→章节 20ms 内反切，AnimatedSwitcher 新旧章节页同时存活，
//         不得共享 GlobalKey / ScrollController。
// HBK046：第 80/100 章 + 多行长标题 + 200% 文字，点「定位当前章」后估算跳转的
//         目标仍未构建时要继续收敛，直到当前章确实可见（打开时不自动定位）。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

const Key _chaptersKey = ValueKey<String>('fushi_audiobook_chapters');
const Key _chaptersTab = ValueKey<String>(
  'fushi_audiobook_tab_button_chapters',
);
const Key _settingsTab = ValueKey<String>(
  'fushi_audiobook_tab_button_settings',
);
const Key _revealKey = ValueKey<String>(
  'fushi_audiobook_reveal_current_chapter',
);

Future<void> _pumpPanel(
  WidgetTester tester, {
  int current = 0,
  bool longTitles = false,
  double textScale = 1,
  bool reduceMotion = false,
  bool eink = false,
}) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        splashFactory: NoSplash.splashFactory,
        extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
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
          settingsBuilder: (_) => const Text('Panel settings'),
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

Future<void> _switchBackQuickly(WidgetTester tester) async {
  await tester.tap(find.byKey(_settingsTab));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.tap(find.byKey(_chaptersTab));
  await tester.pump();
}

void main() {
  testWidgets(
    'quick chapter-settings-chapter switches keep unique list state',
    (WidgetTester tester) async {
      await _pumpPanel(tester);
      await _switchBackQuickly(tester);
      expect(
        tester.takeException(),
        isNull,
        reason:
            'Outgoing and incoming chapter tabs cannot share a GlobalKey '
            'or attach one ScrollController to concurrent lists.',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_chaptersKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final bool eink in <bool>[false, true]) {
    testWidgets(
      'quick tab switch control with ${eink ? 'eink' : 'reduced motion'}',
      (WidgetTester tester) async {
        await _pumpPanel(tester, eink: eink, reduceMotion: !eink);
        await _switchBackQuickly(tester);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(_chaptersKey), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

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

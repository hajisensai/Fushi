import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_workbench_page.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

// 2026-11-20 反馈 #4：有声漫画工作台复用「制作有声书」的步骤外壳（左边步骤栏 +
// 底部主按钮），原菜单那排有声按钮拆进四步。

const String _p = MangaAudioWorkbenchView.keyPrefix;

const MangaAudioWorkbenchSnapshot _midway = MangaAudioWorkbenchSnapshot(
  pageCount: 180,
  ocrPages: 160,
  blockCount: 900,
  annotatedPages: 40,
  lineCount: 128,
  speakerCount: 6,
  assignedSpeakers: 4,
  preview: <MangaAudioWorkbenchLine>[
    (speaker: 'そよ', text: '雨、やまないね'),
    (speaker: '爱音', text: '傘、持ってる？'),
  ],
);

Future<List<String>> _pump(
  WidgetTester tester, {
  required Size size,
  MangaAudioWorkbenchSnapshot snapshot = _midway,
  MangaAudioWorkbenchStep selected = MangaAudioWorkbenchStep.recognize,
  bool glass = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final List<String> calls = <String>[];
  MangaAudioWorkbenchStep step = selected;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFushiThemeData(
        scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        textTheme: Typography.material2021().black,
        glass: glass ? FushiGlassMaterial.premium : FushiGlassMaterial.off,
        glassDesign: glass,
      ),
      home: FushiGlassScope(
        child: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                MangaAudioWorkbenchView(
                  snapshot: snapshot,
                  selected: step,
                  onSelect: (MangaAudioWorkbenchStep s) {
                    calls.add('select:${s.name}');
                    setState(() => step = s);
                  },
                  onRecognize: () => calls.add('recognize'),
                  onOpenScript: () => calls.add('script'),
                  onOpenStudio: () => calls.add('studio'),
                  onImport: () => calls.add('import'),
                  onOpenAudiobookSource: () => calls.add('source'),
                  onOpenDramaTrack: () => calls.add('drama'),
                  onExportPackage: () => calls.add('export-package'),
                  onImportPackage: () => calls.add('import-package'),
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

bool _focusInside(Finder finder) {
  final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final Element target = finder.evaluate().single;
  bool inside = identical(focused, target);
  (focused as Element).visitAncestorElements((Element e) {
    if (identical(e, target)) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  for (final bool glass in <bool>[false, true]) {
    testWidgets('宽屏（${glass ? 'Apple' : 'MD3'}）：步骤栏四步 + 副行 + 侧栏底部主按钮', (
      WidgetTester tester,
    ) async {
      final List<String> calls = await _pump(
        tester,
        size: const Size(1280, 800),
        glass: glass,
      );
      expect(find.byKey(const ValueKey<String>('$_p-sidebar')), findsOneWidget);
      for (final MangaAudioWorkbenchStep s in MangaAudioWorkbenchStep.values) {
        expect(
          find.byKey(ValueKey<String>('$_p-step-${s.name}')),
          findsOneWidget,
        );
      }
      expect(find.text('1. 识别台词'), findsOneWidget);
      expect(find.text('已识别 160/180 页 · 900 个气泡'), findsWidgets);
      expect(find.text('6 个角色 · 已指派 4'), findsOneWidget);
      final Finder primary = find.byKey(const ValueKey<String>('$_p-primary'));
      expect(primary, findsOneWidget);
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(calls, <String>['recognize']);

      // 第 2 步：主按钮打开演出稿，正文列出演出稿开头几句。
      await tester.tap(find.byKey(const ValueKey<String>('$_p-step-script')));
      await tester.pumpAndSettle();
      expect(find.text('雨、やまないね'), findsOneWidget);
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(calls.last, 'script');

      // 第 4 步：导入成品 / 有声书音源 / 广播剧三种来源。
      await tester.tap(find.byKey(const ValueKey<String>('$_p-step-render')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('$_p-import')));
      await tester.pumpAndSettle();
      expect(calls.last, 'import');

      // 有声漫画包：导出（本卷有演出稿就能导）/ 导入。
      expect(find.byKey(const ValueKey<String>('$_p-package')), findsOneWidget);
      for (final String id in <String>['export-package', 'import-package']) {
        final Finder row = find.byKey(ValueKey<String>('$_p-$id'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(calls.last, id);
      }
    });
  }

  testWidgets('窄屏：顶部步骤选择片 + 底部固定条放主按钮', (WidgetTester tester) async {
    await _pump(tester, size: const Size(400, 800));
    expect(find.byKey(const ValueKey<String>('$_p-step-tabs')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('$_p-bottom-bar')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('$_p-bottom-bar')),
        matching: find.byKey(const ValueKey<String>('$_p-primary')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Tab 与方向键能把焦点走到第 1 步，Enter 选中', (WidgetTester tester) async {
    final List<String> calls = await _pump(
      tester,
      size: const Size(1280, 800),
      selected: MangaAudioWorkbenchStep.voices,
    );
    final Finder step1 = find.byKey(
      const ValueKey<String>('$_p-step-recognize'),
    );
    int presses = 0;
    while (!_focusInside(step1) && presses < 12) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      presses++;
    }
    expect(_focusInside(step1), isTrue, reason: 'Tab $presses 次仍没到第 1 步');
    // 方向键在步骤之间走：下到第 2 步再上回第 1 步。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      _focusInside(find.byKey(const ValueKey<String>('$_p-step-script'))),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_focusInside(step1), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, contains('select:recognize'));
  });

  testWidgets('在线章节：顶部说明不能做，主按钮不可点', (WidgetTester tester) async {
    await _pump(
      tester,
      size: const Size(1280, 800),
      snapshot: const MangaAudioWorkbenchSnapshot(unsupportedReason: '暂不支持'),
    );
    expect(
      find.byKey(const ValueKey<String>('$_p-unsupported')),
      findsOneWidget,
    );
    final Finder button = find.descendant(
      of: find.byKey(const ValueKey<String>('$_p-primary')),
      matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
    );
    expect(tester.widget<ButtonStyleButton>(button.first).enabled, isFalse);
  });

  group('菜单副行 mangaAudioWorkbenchStatusText', () {
    test('没开始 / 做不了 → null（菜单显示「把漫画做成有声版」）', () {
      expect(
        mangaAudioWorkbenchStatusText(
          const MangaAudioWorkbenchSnapshot(ocrPages: 10, pageCount: 10),
        ),
        isNull,
      );
      expect(
        mangaAudioWorkbenchStatusText(
          const MangaAudioWorkbenchSnapshot(unsupportedReason: 'x'),
        ),
        isNull,
      );
      expect(t.manga_audio_workbench_not_started, '把漫画做成有声版');
    });

    test('标注中 / 生成了一部分 / 已就绪', () {
      expect(mangaAudioWorkbenchStatusText(_midway), '已标注 40/160 页 · 128 句');
      expect(
        mangaAudioWorkbenchStatusText(
          const MangaAudioWorkbenchSnapshot(
            ocrPages: 10,
            annotatedPages: 10,
            lineCount: 128,
            renderedLines: 96,
          ),
        ),
        '128 句台词 · 已生成 96/128 句',
      );
      expect(
        mangaAudioWorkbenchStatusText(
          const MangaAudioWorkbenchSnapshot(lineCount: 128, hasAudio: true),
        ),
        '有声版已就绪 · 128 句台词',
      );
    });

    test('一进来停在第一个没做完的步骤', () {
      expect(
        const MangaAudioWorkbenchSnapshot().suggestedStep,
        MangaAudioWorkbenchStep.recognize,
      );
      expect(_midway.suggestedStep, MangaAudioWorkbenchStep.voices);
      expect(
        const MangaAudioWorkbenchSnapshot(
          ocrPages: 3,
          lineCount: 5,
          hasAudio: true,
        ).suggestedStep,
        MangaAudioWorkbenchStep.render,
      );
    });
  });
}

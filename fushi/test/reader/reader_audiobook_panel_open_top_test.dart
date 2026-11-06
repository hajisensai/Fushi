// 手机竖屏打开有声书底部面板（2026-10-07 用户录屏「弹出位置不对，要看到最上面的」）：
//  * 打开时内容停在顶部：之前章节列表一挂载就把当前章 ensureVisible 到 1/3 处，
//    Scrollable.ensureVisible 沿所有祖先滚动，连包住整块面板的外层滚动也被推下去，
//    「选择对齐文件 / 设备端转录生成字幕」那排一打开就被切掉；
//  * 底部 sheet 进场不过冲：欠阻尼弹簧把 sheet 先推到停靠位上方再落回。
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart'
    show TtuTocEntry;
import 'package:fushi/src/reader/reader_audiobook_panel.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';

const Key _sheetKey = ValueKey<String>('fushi_reader_side_sheet');
const Key _alignmentKey = ValueKey<String>('fushi_audiobook_panel_alignment');
const Key _transcribeKey = ValueKey<String>('fushi_audiobook_panel_transcribe');
const Key _chaptersKey = ValueKey<String>('fushi_audiobook_chapters');

/// 用户录屏 588×1280 px 的手机竖屏，按 1.5 dpr 折成逻辑 392×853。
const Size _phone = Size(392, 853);

Widget _panel(
  BuildContext ctx, {
  AudiobookPlayerController? controller,
  int currentSection = 30,
}) => ReaderSideSheet(
  title: '有声书',
  subtitle: 'こうして平塚静は',
  scrollable: false,
  onClose: () => Navigator.of(ctx).pop(),
  child: ReaderAudiobookPanel(
    controller: controller,
    toc: List<TtuTocEntry>.generate(
      40,
      (int i) => TtuTocEntry(index: i, label: '第$i章'),
    ),
    // 当前章在长目录深处：旧实现一打开就会把它滚进视野。
    currentSection: currentSection,
    onJumpSection: (int _, String? __) async {},
    onPickAlignment: () {},
    onTranscribe: () {},
    title: 'Book',
    chapterLabel: 'こうして平塚静は',
    coverPath: null,
  ),
);

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
  addTearDown(tester.view.reset);
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext ctx) {
            context = ctx;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return context;
}

void main() {
  test('底部 sheet 进场曲线不过冲；侧板保留 M3E 弹簧', () {
    final Curve bottom = readerPanelEnterCurve(ReaderPanelPresentation.bottom);
    for (int i = 0; i <= 200; i++) {
      final double t = i / 200;
      expect(
        bottom.transform(t),
        lessThanOrEqualTo(1.0),
        reason: 't=$t：底部 sheet 越过停靠位会先高后低地跳一下',
      );
    }
    expect(bottom.transform(1), 1);
    expect(
      readerPanelEnterCurve(ReaderPanelPresentation.side),
      isA<ReaderPanelSpringCurve>().having(
        (ReaderPanelSpringCurve c) => c.dampingRatio,
        'dampingRatio',
        lessThan(1),
      ),
    );
  });

  testWidgets('手机底部 sheet 打开有声书面板：停在顶部、看得到对齐 / 转录动作、高度不跳', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await _pumpHost(tester);
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => _panel(ctx),
    );
    await tester.pump();

    // 进场每帧记录 sheet 顶边：任何一帧都不能高于（小于）落定后的顶边。
    final List<double> tops = <double>[];
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      tops.add(tester.getTopLeft(find.byKey(_sheetKey)).dy);
    }
    await tester.pumpAndSettle();
    final double settledTop = tester.getTopLeft(find.byKey(_sheetKey)).dy;
    final double highest = tops.reduce((double a, double b) => a < b ? a : b);
    expect(
      highest,
      greaterThanOrEqualTo(settledTop - 0.5),
      reason: '进场时 sheet 冲到 $highest，高于停靠位 $settledTop（先高后低）',
    );

    // 面板每秒 tick 重建：落定后再过几秒，位置与滚动都不能再动。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(_sheetKey)).dy, settledTop);

    for (final ScrollableState s in tester.stateList<ScrollableState>(
      find.descendant(
        of: find.byKey(_sheetKey),
        matching: find.byType(Scrollable),
      ),
    )) {
      if (s.position.axis != Axis.vertical) continue;
      expect(
        s.position.pixels,
        0,
        reason: '${s.widget.key ?? s.widget.runtimeType} 打开时不应已滚离顶部',
      );
    }

    final Rect sheet = tester.getRect(find.byKey(_sheetKey));
    for (final Key key in <Key>[_alignmentKey, _transcribeKey]) {
      final Rect button = tester.getRect(find.byKey(key));
      expect(
        sheet.top <= button.top && button.bottom <= sheet.bottom,
        isTrue,
        reason: '$key 应在首屏可见：button=$button sheet=$sheet',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('定位当前章只滚章节列表，不连带外层滚动', (WidgetTester tester) async {
    final BuildContext context = await _pumpHost(tester);
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => _panel(ctx),
    );
    await tester.pumpAndSettle();

    final ScrollableState chapters = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(_chaptersKey),
        matching: find.byType(Scrollable),
      ),
    );
    // 整块面板只有**一个**竖向滚动，就是章节列表自己：钉住模式下「正在播放」卡在
    // 列表外不滚，单滚动模式下它是列表最顶上的 sliver（k2ykdRRxC3）。两种结构里
    // 都不存在能被定位连带推走的外层滚动；谁把「外层滚动 + 固定高度内层列表」的
    // 嵌套加回来，这里就多出一个竖向 Scrollable。
    final List<ScrollableState> vertical = <ScrollableState>[
      for (final ScrollableState s in tester.stateList<ScrollableState>(
        find.descendant(
          of: find.byKey(_sheetKey),
          matching: find.byType(Scrollable),
        ),
      ))
        if (s.position.axis == Axis.vertical) s,
    ];
    expect(vertical, hasLength(1), reason: '面板里只能有章节列表这一个竖向滚动（不得再嵌外层滚动）');
    expect(vertical.single, same(chapters));

    // 定位键在「章节」分组标题旁，先把它滚进章节列表视野里再点。
    const Key reveal = ValueKey<String>(
      'fushi_audiobook_reveal_current_chapter',
    );
    await tester.ensureVisible(find.byKey(reveal));
    await tester.pumpAndSettle();
    final double sheetTop = tester.getTopLeft(find.byKey(_sheetKey)).dy;
    await tester.tap(find.byKey(reveal));
    await tester.pumpAndSettle();

    expect(find.text('第30章'), findsOneWidget);
    final Rect viewport = tester.getRect(find.byKey(_chaptersKey));
    final Rect row = tester.getRect(find.text('第30章'));
    expect(row.top, greaterThanOrEqualTo(viewport.top));
    expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(chapters.position.pixels, greaterThan(0));
    expect(
      tester.getTopLeft(find.byKey(_sheetKey)).dy,
      sheetTop,
      reason: '定位不得把整块 sheet 推动',
    );
    expect(tester.takeException(), isNull);
  });

  test('源码守卫：定位当前章只滚章节列表自己的 ScrollPosition', () {
    // 面板在无界高度的宿主里（外层可滚的 ReaderSideSheet）走「固定 320 高的内层
    // 列表」分支，那里确实有外层滚动。`Scrollable.ensureVisible` 会沿**所有**祖先
    // 滚动，把外层一起推下去、切掉顶部的对齐 / 转录动作；只有
    // `ScrollPosition.ensureVisible` 只动自己。上面的 widget 用例在单滚动结构下
    // 观察不到这一差别（只有一个 Scrollable），所以这条约束钉在源码上。
    final File f = File('lib/src/reader/reader_audiobook_panel.dart');
    expect(f.existsSync(), isTrue, reason: 'run from the fushi/ package root');
    final String src = f.readAsStringSync();
    expect(src, contains('_scroll.position.ensureVisible('));
    expect(
      src.contains('Scrollable.ensureVisible('),
      isFalse,
      reason: 'Scrollable.ensureVisible 会连带滚动外层',
    );
  });

  Future<ScrollableState> openWithSection(
    WidgetTester tester,
    ValueNotifier<int> section,
  ) async {
    final BuildContext context = await _pumpHost(tester);
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => ValueListenableBuilder<int>(
        valueListenable: section,
        builder: (BuildContext ctx, int value, Widget? _) =>
            _panel(ctx, currentSection: value),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(_chaptersKey),
        matching: find.byType(Scrollable),
      ),
    );
  }

  testWidgets('播放跨章：当前章在视野里时章节列表跟到新章', (WidgetTester tester) async {
    final ValueNotifier<int> section = ValueNotifier<int>(2);
    addTearDown(section.dispose);
    await openWithSection(tester, section);
    const Key reveal = ValueKey<String>(
      'fushi_audiobook_reveal_current_chapter',
    );
    await tester.ensureVisible(find.byKey(reveal));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(reveal));
    await tester.pumpAndSettle();
    // 旧当前章在视野里，新章离得远（未跟随时根本不在视野）。
    expect(find.text('第2章').hitTestable(), findsOneWidget);

    section.value = 39;
    await tester.pumpAndSettle();

    expect(find.text('第39章'), findsOneWidget);
    final Rect viewport = tester.getRect(find.byKey(_chaptersKey));
    final Rect row = tester.getRect(find.text('第39章'));
    expect(row.top, greaterThanOrEqualTo(viewport.top));
    expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放跨章：停在顶部看资源区时不把列表拉走', (WidgetTester tester) async {
    final ValueNotifier<int> section = ValueNotifier<int>(30);
    addTearDown(section.dispose);
    final ScrollableState chapters = await openWithSection(tester, section);
    expect(chapters.position.pixels, 0);

    section.value = 31;
    await tester.pumpAndSettle();

    expect(chapters.position.pixels, 0);
    for (final ScrollableState s in tester.stateList<ScrollableState>(
      find.descendant(
        of: find.byKey(_sheetKey),
        matching: find.byType(Scrollable),
      ),
    )) {
      if (s.position.axis == Axis.vertical) expect(s.position.pixels, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实控制器的概览与播放控件不会在打开后推走顶部', (WidgetTester tester) async {
    final AudiobookPlayerController controller = AudiobookPlayerController();
    addTearDown(controller.dispose);
    final BuildContext context = await _pumpHost(tester);
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => _panel(ctx, controller: controller),
    );
    await tester.pumpAndSettle();
    final double top = tester.getTopLeft(find.byKey(_sheetKey)).dy;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(_sheetKey)).dy, top);
    for (final ScrollableState state in tester.stateList<ScrollableState>(
      find.descendant(
        of: find.byKey(_sheetKey),
        matching: find.byType(Scrollable),
      ),
    )) {
      if (state.position.axis == Axis.vertical) {
        expect(state.position.pixels, 0);
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

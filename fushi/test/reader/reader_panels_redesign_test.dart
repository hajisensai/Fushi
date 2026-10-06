import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_settings_preview.dart';
import 'package:fushi/src/reader/reader_settings_side_dialog.dart';
import 'package:fushi_engine/foundation/pref_store.dart';

/// 2026-10 阅读器侧板重设计：统一外壳的宽 / 窄自适应、拖动把手、焦点归还与
/// 实时预览卡。
class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

Widget _app(Widget Function(BuildContext) body) => MaterialApp(
  home: Scaffold(body: Builder(builder: body)),
);

Future<BuildContext> _pumpHost(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
  addTearDown(tester.view.reset);
  late BuildContext context;
  await tester.pumpWidget(
    _app((BuildContext ctx) {
      context = ctx;
      return const SizedBox.expand();
    }),
  );
  return context;
}

Widget _sheet(BuildContext ctx, {List<Widget> actions = const <Widget>[]}) =>
    ReaderSideSheet(
      title: '导航',
      subtitle: '吾輩は猫である',
      icon: Icons.menu_book_outlined,
      headerActions: actions,
      onClose: () => Navigator.of(ctx).pop(),
      child: const TextField(key: ValueKey<String>('panel_field')),
    );

void main() {
  group('readerPanelPresentationFor', () {
    test('只有调用方允许且窗口窄于 600 时才是底部 sheet', () {
      expect(
        readerPanelPresentationFor(
          const Size(420, 900),
          bottomSheetWhenCompact: true,
        ),
        ReaderPanelPresentation.bottom,
      );
      expect(
        readerPanelPresentationFor(
          const Size(600, 900),
          bottomSheetWhenCompact: true,
        ),
        ReaderPanelPresentation.side,
      );
      expect(
        readerPanelPresentationFor(
          const Size(420, 900),
          bottomSheetWhenCompact: false,
        ),
        ReaderPanelPresentation.side,
        reason: '漫画等未接入的调用方保持侧板',
      );
    });

    test('底部 sheet 高度：窗高 86% 与扣掉键盘 / 安全区后的可用高取小', () {
      expect(
        readerPanelBottomSheetHeight(
          windowHeight: 900,
          topPadding: 24,
          keyboardInset: 0,
        ),
        closeTo(900 * kReaderPanelBottomSheetHeightFraction, 0.001),
      );
      expect(
        readerPanelBottomSheetHeight(
          windowHeight: 900,
          topPadding: 24,
          keyboardInset: 400,
        ),
        900 - 400 - 24 - kReaderPanelBottomSheetTopGap,
      );
    });
  });

  testWidgets('窄窗 + bottomSheetWhenCompact：从底部升起、铺满宽度、带拖动把手', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await _pumpHost(tester, const Size(420, 900));
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => _sheet(ctx),
    );
    await tester.pumpAndSettle();

    final Rect panel = tester.getRect(
      find.byKey(const ValueKey<String>('fushi_reader_side_sheet')),
    );
    expect(panel.left, 0);
    expect(panel.width, 420);
    expect(panel.bottom, 900);
    expect(
      panel.height,
      closeTo(900 * kReaderPanelBottomSheetHeightFraction, 0.5),
    );
    expect(
      find.byKey(const ValueKey<String>('fushi_side_sheet_drag_handle')),
      findsOneWidget,
    );
    expect(find.text('吾輩は猫である'), findsOneWidget, reason: '副标题');
    expect(
      find.byKey(const ValueKey<String>('fushi_side_sheet_icon')),
      findsOneWidget,
    );

    // 键盘弹起：整块抬到键盘上方，关闭键仍在可见区内。
    await tester.tap(find.byKey(const ValueKey<String>('panel_field')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    tester.view.padding = const FakeViewPadding(top: 24);
    await tester.pumpAndSettle();
    final Rect lifted = tester.getRect(
      find.byKey(const ValueKey<String>('fushi_reader_side_sheet')),
    );
    expect(lifted.bottom, 900 - 360);
    expect(lifted.top, greaterThanOrEqualTo(24));
    final Offset close = tester.getCenter(
      find.byKey(const ValueKey<String>('fushi_side_sheet_close')),
    );
    expect(lifted.contains(close), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部 sheet：页头向下拖过阈值即关闭，拖一点松手弹回', (WidgetTester tester) async {
    final BuildContext context = await _pumpHost(tester, const Size(420, 900));
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => _sheet(ctx),
    );
    await tester.pumpAndSettle();
    final Finder handle = find.byKey(
      const ValueKey<String>('fushi_side_sheet_drag_handle'),
    );
    final Finder panel = find.byKey(
      const ValueKey<String>('fushi_reader_side_sheet'),
    );
    final double top = tester.getRect(panel).top;

    await tester.drag(handle, const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(tester.getRect(panel).top, top, reason: '小幅拖动松手弹回');

    await tester.drag(handle, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
  });

  testWidgets('宽窗即使允许底部 sheet 仍贴右侧，朝正文一侧圆角', (WidgetTester tester) async {
    final BuildContext context = await _pumpHost(tester, const Size(1600, 900));
    showReaderSideSheet<void>(
      context: context,
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) => _sheet(ctx),
    );
    await tester.pumpAndSettle();
    final Finder panel = find.byKey(
      const ValueKey<String>('fushi_reader_side_sheet'),
    );
    expect(tester.getRect(panel).right, 1600);
    expect(tester.getRect(panel).width, kReaderSideSheetWidth);
    expect(
      find.byKey(const ValueKey<String>('fushi_side_sheet_drag_handle')),
      findsNothing,
    );
    final Material material = tester.widget<Material>(panel);
    final RoundedRectangleBorder shape =
        material.shape! as RoundedRectangleBorder;
    final BorderRadius radius = shape.borderRadius as BorderRadius;
    expect(radius.topLeft.x, greaterThan(0));
    expect(radius.topRight.x, 0);
  });

  testWidgets('设置面板在底部 sheet 形态下不显示左右换边键', (WidgetTester tester) async {
    final BuildContext context = await _pumpHost(tester, const Size(420, 900));
    showReaderSettingsSideDialog<void>(
      context: context,
      preferences: _MemoryPrefs(),
      bottomSheetWhenCompact: true,
      builder: (BuildContext ctx) =>
          _sheet(ctx, actions: const <Widget>[ReaderSettingsSideButton()]),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('reader_settings_side_toggle')),
      findsNothing,
    );
  });

  testWidgets('面板关闭后焦点经 guardOverlay 归还正文焦点节点', (WidgetTester tester) async {
    final FocusNode body = FocusNode(debugLabel: 'reader-body');
    addTearDown(body.dispose);
    final PageFocusOwnership ownership = PageFocusOwnership(
      node: body,
      canOwn: (FocusReclaimCause cause) => true,
    );
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext ctx) {
              context = ctx;
              return Focus(focusNode: body, child: const SizedBox.expand());
            },
          ),
        ),
      ),
    );
    body.requestFocus();
    await tester.pump();
    expect(body.hasFocus, isTrue);

    final Future<void> open = ownership.guardOverlay<void>(
      () => showReaderSideSheet<void>(
        context: context,
        bottomSheetWhenCompact: true,
        builder: (BuildContext ctx) => _sheet(ctx),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('panel_field')));
    await tester.pump();
    expect(body.hasFocus, isFalse, reason: '面板里的输入框持焦');

    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_side_sheet_close')),
    );
    await tester.pumpAndSettle();
    await open;
    await tester.pump();
    expect(body.hasFocus, isTrue);
  });

  test('阅读器的侧板入口经 guardOverlay 打开并允许窄窗底部 sheet', () {
    final String src = File(
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
    ).readAsStringSync();
    final int at = src.indexOf('Future<void> _presentSideSheet(');
    expect(at, greaterThan(-1));
    final String body = src.substring(
      at,
      src.indexOf('bool _closeSideSheetForWebViewPointer'),
    );
    expect(body, contains('_focusOwnership.guardOverlay'));
    expect(
      'bottomSheetWhenCompact: true'.allMatches(body).length,
      2,
      reason: '导航 / 统计 / 有声书与可换边的设置面板都要在窄窗走底部 sheet',
    );
  });

  group('实时预览卡', () {
    test('字号缩放并夹在 10–30', () {
      expect(readerPreviewFontSize(30), 18);
      expect(readerPreviewFontSize(4), 10);
      expect(readerPreviewFontSize(200), 30);
      expect(readerPreviewFontWeight(400), FontWeight.w400);
      expect(readerPreviewFontWeight(720), FontWeight.w700);
    });

    testWidgets('改字号 / 主题后预览即时变化（动画结束后落到新值）', (WidgetTester tester) async {
      Widget card(double size, Color bg) => MaterialApp(
        home: Scaffold(
          body: ReaderSettingsPreviewCard(
            sample: '吾輩は猫である。',
            background: bg,
            foreground: Colors.black,
            readerFontSize: size,
            lineHeight: 1.6,
            fontWeight: 400,
            vertical: false,
          ),
        ),
      );
      await tester.pumpWidget(card(20, Colors.white));
      await tester.pumpWidget(card(40, const Color(0xFFF2E8D5)));
      await tester.pumpAndSettle();
      final DefaultTextStyle style = tester.widget<DefaultTextStyle>(
        find
            .ancestor(
              of: find.text('吾輩は猫である。'),
              matching: find.byType(DefaultTextStyle),
            )
            .first,
      );
      expect(style.style.fontSize, readerPreviewFontSize(40));
      final AnimatedContainer box = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey<String>('reader_settings_preview')),
      );
      expect((box.decoration! as BoxDecoration).color, const Color(0xFFF2E8D5));
    });
  });
}

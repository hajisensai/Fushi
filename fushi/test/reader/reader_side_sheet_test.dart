import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';

Widget _app(Widget Function(BuildContext) body) => MaterialApp(
      home: Scaffold(body: Builder(builder: body)),
    );

void main() {
  for (final double width in <double>[320, 360]) {
    testWidgets('手机 $width 抽屉避开安全区和键盘，关闭键始终可用', (tester) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.reset);

      late BuildContext context;
      await tester.pumpWidget(_app((BuildContext ctx) {
        context = ctx;
        return const SizedBox.expand();
      }));
      showReaderSideSheet<void>(
        context: context,
        builder: (BuildContext ctx) => ReaderSideSheet(
          title: '导航',
          onClose: () => Navigator.of(ctx).pop(),
          child: const TextField(
            key: ValueKey<String>('mobile_search'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder content = find.byType(ReaderSideSheet);
      final Finder close = find.byKey(
        const ValueKey<String>('fushi_side_sheet_close'),
      );
      expect(tester.getRect(content).top, 24);
      expect(tester.getRect(content).bottom, 700);
      expect(tester.getRect(content).width, width - 48);

      await tester.tap(find.byKey(const ValueKey<String>('mobile_search')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      tester.view.padding = const FakeViewPadding(top: 24);
      await tester.pumpAndSettle();

      final Rect available = Rect.fromLTRB(48, 24, width, 440);
      expect(tester.getRect(content), available);
      expect(available.contains(tester.getCenter(close)), isTrue);
      expect(
        tester.getRect(find.byType(SingleChildScrollView)).bottom,
        lessThanOrEqualTo(available.bottom),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(content, findsNothing);
    });
  }

  testWidgets('showReaderSideSheet：右抽屉贴右、左抽屉贴左，点外面关闭', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    late BuildContext ctx;
    await tester.pumpWidget(_app((BuildContext c) {
      ctx = c;
      return const SizedBox.expand();
    }));

    showReaderSideSheet<void>(
      context: ctx,
      builder: (_) => const ReaderSideSheetProbe(),
    );
    await tester.pumpAndSettle();
    final Finder sheet =
        find.byKey(const ValueKey<String>('fushi_reader_side_sheet'));
    expect(sheet, findsOneWidget);
    final Rect right = tester.getRect(sheet);
    expect(right.right, 1600);
    expect(right.width, kReaderSideSheetWidth);

    // 点抽屉外空白关闭。
    await tester.tapAt(const Offset(100, 450));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);

    showReaderSideSheet<void>(
      context: ctx,
      side: ReaderSideSheetSide.left,
      builder: (_) => const ReaderSideSheetProbe(),
    );
    await tester.pumpAndSettle();
    final Rect left = tester.getRect(sheet);
    expect(left.left, 0);
    expect(left.width, kReaderSideSheetWidth);
  });

  testWidgets('ReaderSideSheet 外壳：标题 + 关闭键触发 onClose', (tester) async {
    int closed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ReaderSideSheet(
          title: '导航',
          onClose: () => closed++,
          child: const Text('BODY'),
        ),
      ),
    ));
    expect(find.text('导航'), findsOneWidget);
    expect(find.text('BODY'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('fushi_side_sheet_close')));
    expect(closed, 1);
  });
}

/// 抽屉内容占位。
class ReaderSideSheetProbe extends StatelessWidget {
  const ReaderSideSheetProbe({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text('PROBE'));
}

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_fushi_card_view.dart';
import 'package:fushi/src/utils/components/fushi_marquee.dart';
import 'package:material_ui/material_ui.dart';

/// 两处自写 `computeDryBaseline` 在 Flutter 3.50 语义下（proxy box 对「子节点无基线」
/// 如实回 null，flutter#189723 / #190269）必须与实际布局给出的基线一致：
/// `debugCheckIntrinsicSizes` 打开时框架逐条比对，不一致直接抛错。
void main() {
  Future<void> layOut(
    WidgetTester tester,
    Widget child, {
    required BoxConstraints constraints,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(constraints: constraints, child: child),
          ),
        ),
      ),
    );
  }

  void expectDryMatchesActual(RenderBox box) {
    for (final TextBaseline baseline in TextBaseline.values) {
      final double? actual = box.getDistanceToBaseline(
        baseline,
        onlyReal: true,
      );
      final double? dry = box.getDryBaseline(box.constraints, baseline);
      expect(dry, actual, reason: '$baseline');
    }
  }

  testWidgets('FushiMarquee：放得下 / 放不下 / 高于一行的紧约束，dry 基线与实际一致', (
    WidgetTester tester,
  ) async {
    debugCheckIntrinsicSizes = true;
    addTearDown(() => debugCheckIntrinsicSizes = false);
    const TextStyle style = TextStyle(fontSize: 16);
    final Map<String, (String, BoxConstraints)> cases =
        <String, (String, BoxConstraints)>{
          'fits': ('Short', const BoxConstraints(maxWidth: 300)),
          'overflows': (
            'A rather long title that cannot fit in the row',
            const BoxConstraints(maxWidth: 80),
          ),
          'taller tight': (
            'Short',
            const BoxConstraints.tightFor(width: 300, height: 60),
          ),
        };
    for (final MapEntry<String, (String, BoxConstraints)> c in cases.entries) {
      await layOut(
        tester,
        FushiMarquee(text: c.value.$1, style: style),
        constraints: c.value.$2,
      );
      expect(tester.takeException(), isNull, reason: c.key);
      final RenderBox box = tester.renderObject<RenderBox>(
        find.byType(FushiMarquee),
      );
      expectDryMatchesActual(box);
      if (c.key == 'overflows') {
        expect(
          box.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
          null,
        );
      } else {
        expect(
          box.getDistanceToBaseline(TextBaseline.alphabetic, onlyReal: true),
          isNotNull,
        );
      }
    }
  });

  testWidgets('SrsNoBaseline：子节点有基线也对外回 null（dry 与实际一致）', (
    WidgetTester tester,
  ) async {
    debugCheckIntrinsicSizes = true;
    addTearDown(() => debugCheckIntrinsicSizes = false);
    await layOut(
      tester,
      const SrsNoBaseline(child: Text('読み')),
      constraints: const BoxConstraints(maxWidth: 200),
    );
    expect(tester.takeException(), isNull);
    final RenderBox box = tester.renderObject<RenderBox>(
      find.byType(SrsNoBaseline),
    );
    expectDryMatchesActual(box);
    expect(box.getDryBaseline(box.constraints, TextBaseline.alphabetic), null);
  });
}

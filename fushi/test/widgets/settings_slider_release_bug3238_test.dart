import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-3238：设置滑条松手后保留拖动值等调用方写回；调用方拒绝新值（重建时
/// value 仍是旧值）时，滑块必须交还旧值，而不是一直挂着被拒绝的拖动值。
void main() {
  Future<TestGesture> dragFrom12(WidgetTester tester) async {
    final Finder slider = find.byType(Slider);
    final TestGesture gesture = await tester.startGesture(
      tester.getTopLeft(slider) + const Offset(30, 24),
    );
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, greaterThan(12));
    return gesture;
  }

  testWidgets('调用方拒绝（重建但 value 不变）：松手后滑块回到调用方的值', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    AdaptiveSettingsSliderRow(
                      title: '字号',
                      value: 12,
                      min: 12,
                      max: 48,
                      divisions: 36,
                      onChanged: (_) {},
                      // 校验失败：不采纳新值，只刷新一下宿主。
                      onChangeEnd: (_) => setState(() {}),
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    final TestGesture gesture = await dragFrom12(tester);
    await gesture.up();
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 12);
  });

  testWidgets('异步提交在途（调用方尚未重建）：松手后保留拖动值，落地后显示新值', (WidgetTester tester) async {
    double committed = 12;
    double? ended;
    late StateSetter hostSetState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 500,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  hostSetState = setState;
                  return AdaptiveSettingsSliderRow(
                    title: '字号',
                    value: committed,
                    min: 12,
                    max: 48,
                    divisions: 36,
                    onChanged: (_) {},
                    onChangeEnd: (double v) => ended = v,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final TestGesture gesture = await dragFrom12(tester);
    await gesture.up();
    await tester.pump();
    expect(ended, isNotNull);
    expect(
      tester.widget<Slider>(find.byType(Slider)).value,
      ended,
      reason: '提交在途时不弹回旧值',
    );
    hostSetState(() => committed = ended!);
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, ended);
  });
}

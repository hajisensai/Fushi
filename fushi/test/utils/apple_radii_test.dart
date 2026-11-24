import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/apple/apple_radii.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:material_ui/material_ui.dart';

Future<FushiAppleRadii> _radiiFor(
  WidgetTester tester, {
  required TargetPlatform platform,
  required double width,
}) async {
  late FushiAppleRadii radii;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Theme(
        data: ThemeData(platform: platform),
        child: Builder(
          builder: (BuildContext context) {
            radii = FushiAppleRadii.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return radii;
}

void main() {
  testWidgets('iOS 档：输入框 / 选中底 10，分组同 inset grouped 26', (
    WidgetTester tester,
  ) async {
    final FushiAppleRadii r = await _radiiFor(
      tester,
      platform: TargetPlatform.iOS,
      width: 1200,
    );
    expect(r.desktop, isFalse);
    expect(r.field, 10);
    expect(r.selection, 10);
    expect(r.highlight, 8);
    expect(r.thumbnail, 6);
    expect(r.group, 26);
  });

  testWidgets('Mac 宽窗：macOS 档原值，分组与 FushiAppleMetrics 同源', (
    WidgetTester tester,
  ) async {
    final FushiAppleRadii r = await _radiiFor(
      tester,
      platform: TargetPlatform.macOS,
      width: 1200,
    );
    expect(r.desktop, isTrue);
    expect(r.scale, 1.0);
    expect(r.field, 6);
    expect(r.selection, 6);
    expect(r.highlight, 8);
    expect(r.group, 10);
  });

  testWidgets('Windows 宽窗：macOS 档整体乘放大系数', (WidgetTester tester) async {
    final FushiAppleRadii r = await _radiiFor(
      tester,
      platform: TargetPlatform.windows,
      width: 1200,
    );
    expect(r.scale, kFushiAppleMacScaleNonMac);
    expect(r.field, closeTo(6 * kFushiAppleMacScaleNonMac, 1e-9));
    expect(r.popover, closeTo(14 * kFushiAppleMacScaleNonMac, 1e-9));
  });

  testWidgets('桌面窄窗回到 iOS 档', (WidgetTester tester) async {
    final FushiAppleRadii r = await _radiiFor(
      tester,
      platform: TargetPlatform.macOS,
      width: 400,
    );
    expect(r.desktop, isFalse);
    expect(r.field, 10);
  });

  test('固定 iOS 档常量不放大', () {
    expect(FushiAppleRadii.ios.desktop, isFalse);
    expect(FushiAppleRadii.ios.artwork, 12);
    expect(FushiAppleRadii.ios.group, 26);
  });
}

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_inputs.dart'
    show kFushiAppleSearchBarHeight;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show kFushiAppleMacScaleNonMac;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';

// FushiSearchField 的 large 档契约：MD3 = M3 SearchBar（56 高、28 圆角全胶囊、
// 无描边、正文竖直居中、trailing 槽 48 触控区）；Apple iOS 档（窄窗）是大标题
// 下 44 高的独立搜索栏、macOS 档（宽窗）仍是 28 × macScale 的 NSSearchField。
// regular 档不受影响（MD3 40、Apple iOS 36）。

Future<void> _pump(
  WidgetTester tester, {
  required bool apple,
  required FushiSearchFieldSize size,
  List<Widget> trailing = const <Widget>[],
  String text = '',
  bool narrow = false,
}) async {
  if (narrow) {
    // 桌面平台窄于 600 = Apple iOS 档（fushiAppleUsesMacMetrics）。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: apple ? FushiGlassMaterial.minimal : FushiGlassMaterial.off,
    glassDesign: apple,
  ).copyWith(platform: TargetPlatform.windows);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: narrow ? 360 : 480,
              child: FushiSearchField(
                fieldKey: const ValueKey<String>('field'),
                controller: TextEditingController(text: text),
                focusNode: FocusNode(),
                hintText: 'Search',
                onChanged: (_) {},
                onSubmitted: (_) {},
                size: size,
                trailing: trailing,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('MD3 large is a 56-tall fully rounded search bar', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      apple: false,
      size: FushiSearchFieldSize.large,
      text: 'abc',
    );
    final Rect field = tester.getRect(
      find.byKey(const ValueKey<String>('field')),
    );
    expect(field.height, kFushiSearchFieldLargeHeight);
    expect(kFushiSearchFieldLargeHeight, 56);

    final InputDecorator decorator = tester.widget(find.byType(InputDecorator));
    final InputBorder enabled = decorator.decoration.enabledBorder!;
    expect(enabled, isA<OutlineInputBorder>());
    expect(
      (enabled as OutlineInputBorder).borderRadius,
      BorderRadius.circular(28),
    );
    expect(enabled.borderSide, BorderSide.none);
    // SearchBar 聚焦不画主色描边（用状态层表达）。
    expect(decorator.decoration.focusedBorder!.borderSide, BorderSide.none);
    expect(decorator.decoration.filled, isTrue);

    // 正文在 56 高的胶囊里竖直居中（±0.5px）。
    final Rect editable = tester.getRect(find.byType(EditableText));
    expect(
      (editable.center.dy - field.center.dy).abs(),
      lessThanOrEqualTo(0.5),
    );
  });

  testWidgets('MD3 large trailing actions get 48 touch targets', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      apple: false,
      size: FushiSearchFieldSize.large,
      trailing: <Widget>[
        SizedBox(
          key: const ValueKey<String>('action'),
          width: 40,
          height: 40,
          child: IconButton(onPressed: () {}, icon: const Icon(Icons.book)),
        ),
      ],
    );
    expect(find.byKey(const ValueKey<String>('action')), findsOneWidget);
    final Finder slot = find.ancestor(
      of: find.byKey(const ValueKey<String>('action')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is ConstrainedBox &&
            w.constraints.minWidth == 48 &&
            w.constraints.minHeight == 48,
      ),
    );
    expect(slot, findsOneWidget);
    expect(tester.getSize(slot).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(slot).height, greaterThanOrEqualTo(48));
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('field'))).height,
      56,
    );
  });

  testWidgets('MD3 regular stays 40 tall', (WidgetTester tester) async {
    await _pump(tester, apple: false, size: FushiSearchFieldSize.regular);
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('field'))).height,
      kFushiSearchFieldHeight,
    );
  });

  testWidgets('Apple large on the iOS tier is a 44-tall search bar', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      apple: true,
      size: FushiSearchFieldSize.large,
      text: 'abc',
      narrow: true,
    );
    final Rect field = tester.getRect(
      find.byKey(const ValueKey<String>('field')),
    );
    expect(field.height, kFushiAppleSearchBarHeight);
    final Rect editable = tester.getRect(find.byType(EditableText));
    expect(
      (editable.center.dy - field.center.dy).abs(),
      lessThanOrEqualTo(0.5),
    );
  });

  testWidgets('Apple large on the macOS tier stays a 28 x macScale field', (
    WidgetTester tester,
  ) async {
    await _pump(tester, apple: true, size: FushiSearchFieldSize.large);
    final Rect field = tester.getRect(
      find.byKey(const ValueKey<String>('field')),
    );
    expect(field.height, moreOrLessEquals(28 * kFushiAppleMacScaleNonMac));
  });
}

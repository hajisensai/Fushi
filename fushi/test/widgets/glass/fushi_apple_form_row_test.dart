// Apple 设计系统下 inset grouped 分组里的文本输入 = iOS / macOS 表单行（用户
// 2026-11-24「cupertino 下这种输入框都要统一 cupertino」）：
// - iOS 档：分组里直接是输入框的行没有填充框、行高 = rowMinHeight，标题当占位
//   （写法①）或左标题 + 右对齐输入（写法②）；
// - 分组外的独立输入框仍是 tertiaryFill 圆角 10 的实色框；
// - macOS 档：左标题 + 右侧 NSTextField 式小框（0.5px 描边）；
// - 设置行（AdaptiveSettingsRow 的 trailing 是输入框）在分组里同样是表单行，
//   标题只画一次；
// - 屏幕键盘辅助钮只在字段聚焦时出现；清除钮在编辑中（聚焦 + 有内容）出现；
// - M3E 一行不变（Material TextField + 浮动标签，键盘钮常驻）。
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme({required bool glass, required TargetPlatform platform}) =>
    buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      textTheme: Typography.material2021().black,
      glassDesign: glass,
    ).copyWith(platform: platform);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  bool glass = true,
  TargetPlatform platform = TargetPlatform.iOS,
  Size size = const Size(420, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(glass: glass, platform: platform),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 字段自己的 Apple 输入框壳（实色填充 / 描边的 AnimatedContainer）。
Finder _shellOf(Finder field) =>
    find.descendant(of: field, matching: find.byType(AnimatedContainer));

void main() {
  testWidgets('iOS：分组里的输入框是表单行（无填充框、标题当占位、行高 = 行高）', (
    WidgetTester tester,
  ) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);
    await _pump(
      tester,
      AdaptiveSettingsSection(
        title: 'Info',
        children: <Widget>[
          FushiTextField(
            key: const ValueKey<String>('title'),
            controller: c,
            labelText: 'Title',
          ),
          const FushiTextField(
            key: ValueKey<String>('author'),
            labelText: 'Author',
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    final Finder title = find.byKey(const ValueKey<String>('title'));
    expect(_shellOf(title), findsNothing, reason: '表单行不画填充框');
    final CupertinoTextField input = tester.widget<CupertinoTextField>(
      find.descendant(of: title, matching: find.byType(CupertinoTextField)),
    );
    expect(input.placeholder, 'Title', reason: '写法①：标题当占位');
    // 标题不再另画一行小标签（只剩占位里的那一份）。
    expect(find.text('Title'), findsOneWidget);
    final double rowMin = FushiAppleMetrics.of(
      tester.element(title),
    ).rowMinHeight;
    expect(tester.getSize(title).height, rowMin);
    // 行间是分组的分隔线：两行 + 一条细线。
    expect(
      tester.getTopLeft(find.byKey(const ValueKey<String>('author'))).dy -
          tester.getBottomLeft(title).dy,
      closeTo(1, 0.01),
    );
  });

  testWidgets('iOS：标题 + 占位都有时左标题、右对齐输入（写法②）', (WidgetTester tester) async {
    await _pump(
      tester,
      const AdaptiveSettingsSection(
        children: <Widget>[
          FushiTextField(
            key: ValueKey<String>('f'),
            labelText: 'Name',
            hintText: 'Required',
          ),
        ],
      ),
    );
    final Finder field = find.byKey(const ValueKey<String>('f'));
    final CupertinoTextField input = tester.widget<CupertinoTextField>(
      find.descendant(of: field, matching: find.byType(CupertinoTextField)),
    );
    expect(input.placeholder, 'Required');
    expect(input.textAlign, TextAlign.end);
    final Rect label = tester.getRect(find.text('Name'));
    final Rect editor = tester.getRect(find.byType(CupertinoTextField));
    expect(label.right, lessThan(editor.left), reason: '标题在左、输入在右');
    expect(label.center.dy, closeTo(editor.center.dy, 1));
  });

  testWidgets('iOS：分组外的独立输入框仍是 tertiaryFill 圆角 10 的实色框', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const FushiTextField(key: ValueKey<String>('f'), labelText: 'Name'),
    );
    final Finder shell = _shellOf(find.byKey(const ValueKey<String>('f')));
    expect(shell, findsOneWidget);
    final BoxDecoration deco =
        tester.widget<AnimatedContainer>(shell).decoration! as BoxDecoration;
    final FushiAppleColors apple = appleColorsOf(tester.element(shell));
    expect(deco.color, apple.tertiaryFill);
    expect(deco.borderRadius, BorderRadius.circular(10));
    expect(deco.border, isNull);
    // 分组外：标题仍在框上方。
    expect(
      tester.getBottomLeft(find.text('Name')).dy,
      lessThanOrEqualTo(tester.getTopLeft(shell).dy),
    );
  });

  testWidgets('macOS 档：分组里是左标题 + 右侧描边小框', (WidgetTester tester) async {
    await _pump(
      tester,
      const AdaptiveSettingsSection(
        children: <Widget>[
          FushiTextField(key: ValueKey<String>('f'), labelText: 'Server'),
        ],
      ),
      platform: TargetPlatform.macOS,
      size: const Size(1200, 800),
    );
    expect(tester.takeException(), isNull);
    final Finder field = find.byKey(const ValueKey<String>('f'));
    final Finder shell = _shellOf(field);
    expect(shell, findsOneWidget);
    final BoxDecoration deco =
        tester.widget<AnimatedContainer>(shell).decoration! as BoxDecoration;
    expect(deco.border, isNotNull, reason: 'NSTextField 0.5px 描边');
    final Rect label = tester.getRect(find.text('Server'));
    expect(label.right, lessThan(tester.getRect(shell).left));
    expect(label.center.dy, closeTo(tester.getRect(shell).center.dy, 1));
  });

  testWidgets('设置行（trailing 是输入框）在分组里是表单行，标题只画一次', (WidgetTester tester) async {
    await _pump(
      tester,
      const AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsRow(
            title: 'Port',
            subtitle: 'Listening port',
            controlBelow: true,
            trailing: FushiTextField(
              key: ValueKey<String>('f'),
              labelText: 'Port',
              hintText: '8080',
            ),
          ),
        ],
      ),
    );
    expect(tester.takeException(), isNull);
    final Finder field = find.byKey(const ValueKey<String>('f'));
    expect(_shellOf(field), findsNothing);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Listening port'), findsOneWidget);
  });

  testWidgets('键盘辅助钮只在聚焦时出现；表单行编辑中出现清除钮', (WidgetTester tester) async {
    final TextEditingController c = TextEditingController(text: 'abc');
    final FocusNode node = FocusNode();
    addTearDown(c.dispose);
    addTearDown(node.dispose);
    await _pump(
      tester,
      AdaptiveSettingsSection(
        children: <Widget>[
          FushiTextField(controller: c, focusNode: node, labelText: 'Title'),
        ],
      ),
      platform: TargetPlatform.windows,
      size: const Size(420, 900),
    );
    expect(find.byIcon(FushiIcons.keyboard), findsNothing);
    expect(find.byIcon(CupertinoIcons.clear_circled_solid), findsNothing);
    node.requestFocus();
    await tester.pump();
    expect(find.byIcon(FushiIcons.keyboard), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.clear_circled_solid), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.clear_circled_solid));
    await tester.pump();
    expect(c.text, isEmpty);
    expect(find.byIcon(CupertinoIcons.clear_circled_solid), findsNothing);
    node.unfocus();
    await tester.pump();
    expect(find.byIcon(FushiIcons.keyboard), findsNothing);
  });

  testWidgets('M3E 不变：Material TextField + 浮动标签，键盘钮常驻', (
    WidgetTester tester,
  ) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);
    await _pump(
      tester,
      AdaptiveSettingsSection(
        children: <Widget>[FushiTextField(controller: c, labelText: 'Title')],
      ),
      glass: false,
      platform: TargetPlatform.windows,
    );
    expect(find.byType(CupertinoTextField), findsNothing);
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.labelText, 'Title');
    expect(find.byIcon(FushiIcons.keyboard), findsOneWidget);
  });
}

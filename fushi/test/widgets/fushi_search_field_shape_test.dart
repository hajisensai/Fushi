// [FushiSearchField] 的**形态**守卫：它必须与三大媒体库页（书架 / 视频库 / 游戏库）
// 手写的工具条搜索框长一个样——透明底 + [OutlineInputBorder] + 固定 40 高 +
// 18px 图标 + `isDense`。
//
// 为什么要钉：此前这里是 MD3 [SearchBar]（高填充容器色、圆角 12、高约 56、24px
// 图标），于是同一导航里「发现」页与「全部视频」页两种外观，用户报了这条。改回
// [SearchBar] 或换掉任一参数，下面的断言会直接红。
//
// 期望值的来源（**改了那边就要改这边**）：
//   fushi/lib/src/pages/implementations/home_video_page.dart      `_buildVideoSearchBar`
//   fushi/lib/src/pages/implementations/reader_fushi_history_page.dart `_buildSearchBar`
//   fushi/lib/src/pages/implementations/games_library_page.dart   `_buildToolbar`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

import 'widget_test_helpers.dart';

/// 三大库页搜索框的形态参数，逐字抄自上面三处调用点。
const double _libraryPageFieldHeight = 40;
const double _libraryPageIconSize = 18;

Future<void> _pumpSearchField(
  WidgetTester tester, {
  required TextEditingController controller,
  required FocusNode focusNode,
  VoidCallback? onClear,
  TargetPlatform? platform,
}) async {
  // 后缀按钮按 `Theme.of(context).platform` 分流（桌面=软键盘，移动=粘贴），
  // 所以平台要从树里给，走的是组件真实的取值路径。
  final Widget bare = SizedBox(
    width: 600,
    child: FushiSearchField(
      controller: controller,
      focusNode: focusNode,
      hintText: 'Search',
      onChanged: (_) {},
      onSubmitted: (_) {},
      onClear: onClear,
    ),
  );
  // 注意别把包装结果赋回同一个变量：闭包捕获的是变量而非当时的值，
  // `x = Builder(builder: (_) => Theme(child: x))` 会自嵌套成无限递归。
  final Widget field = platform == null
      ? bare
      : Builder(
          builder: (BuildContext context) => Theme(
            data: Theme.of(context).copyWith(platform: platform),
            child: bare,
          ),
        );
  await tester.pumpWidget(buildTestApp(
    Align(alignment: Alignment.topCenter, child: field),
  ));
  await tester.pumpAndSettle();
}

InputDecoration _decorationOf(WidgetTester tester) {
  final TextField field = tester.widget<TextField>(find.byType(TextField));
  final InputDecoration? decoration = field.decoration;
  expect(decoration, isNotNull, reason: '搜索框必须带 InputDecoration');
  return decoration!;
}

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode(debugLabel: 'search-shape');
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
  });

  testWidgets('搜索框是描边工具条形态，不再是 MD3 SearchBar', (WidgetTester tester) async {
    await _pumpSearchField(
      tester,
      controller: controller,
      focusNode: focusNode,
    );

    // 换回 SearchBar 会让这条红；SearchBar 只要还在树里就是老形态。
    expect(find.byType(SearchBar), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    final Size size = tester.getSize(find.byType(TextField));
    expect(
      size.height,
      _libraryPageFieldHeight,
      reason: '搜索框高度必须与库页工具条一致',
    );
    expect(kFushiSearchFieldHeight, _libraryPageFieldHeight);

    final InputDecoration decoration = _decorationOf(tester);
    expect(
      decoration.border,
      isA<OutlineInputBorder>(),
      reason: '库页搜索框是描边框，不是填充底',
    );
    expect(decoration.isDense, isTrue);
    expect(decoration.filled, isNot(true), reason: '描边形态不带填充底色');

    final Icon prefix = decoration.prefixIcon! as Icon;
    expect(prefix.icon, Icons.search);
    expect(prefix.size, _libraryPageIconSize);
    expect(kFushiSearchFieldIconSize, _libraryPageIconSize);
  });

  testWidgets('清除按钮与软键盘按钮塞进 40 高不溢出', (WidgetTester tester) async {
    // 桌面平台才有软键盘后缀按钮；连同清除按钮就是 40 高里最挤的一帧。
    // FushiIconButton 默认 24px 图标 + spacing.gap 内边距合计约 40 高，不收窄就
    // 会撑破内容区——这条用例就是钉那次收窄。
    controller.text = '查询词';
    await _pumpSearchField(
      tester,
      controller: controller,
      focusNode: focusNode,
      onClear: () => controller.clear(),
      platform: TargetPlatform.windows,
    );

    expect(find.byIcon(Icons.close), findsOneWidget, reason: '有文字时应有清除键');
    expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
    // RenderFlex overflow 会以异常形式记录，这里必须是干净的一帧。
    expect(tester.takeException(), isNull);
    expect(
        tester.getSize(find.byType(TextField)).height, _libraryPageFieldHeight);
  });
}

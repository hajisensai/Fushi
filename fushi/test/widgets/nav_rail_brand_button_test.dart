import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/utils/components/nav_rail_brand_button.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

/// 侧栏左上角的品牌位是官网入口（与「设置 · 通用 · 官网」同一个
/// [openOfficialWebsite]）。这里咬住三件会静默退化的事：
///
/// 1. 鼠标点击真的发出 url_launcher 的 `launch`，且 URL 就是官网（不是 GitHub、
///    也不是更新镜像的版本化 R2 路径）。
/// 2. 键盘/手柄的 [ActivateIntent] 走同一条路径——品牌位若只挂 `onTap`，焦点确认
///    会静默无反应（rail 的目的地全部是焦点目标，品牌位不能是鼠标专属控件）。
/// 3. 品牌位有 button 语义 + 官网 tooltip，退回成纯装饰图标时立刻红。
void main() {
  final List<String> launchedUrls = <String>[];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    launchedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall call) async {
        if (call.method == 'launch') {
          final Map<Object?, Object?> args =
              Map<Object?, Object?>.from(call.arguments as Map);
          launchedUrls.add(args['url'] as String);
        }
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  Future<void> pumpBrandButton(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 80, child: NavRailBrandButton()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('tapping the rail brand icon opens the official website', (
    WidgetTester tester,
  ) async {
    await pumpBrandButton(tester);

    await tester.tap(find.byType(NavRailBrandButton));
    await tester.pump();

    expect(launchedUrls, <String>[kOfficialWebsiteUrl]);
    expect(kOfficialWebsiteUrl, 'https://fushi.moe');
  });

  testWidgets('keyboard/gamepad activation opens the same URL', (
    WidgetTester tester,
  ) async {
    await pumpBrandButton(tester);

    // 手柄 A / 回车走的是 ActivateIntent：在主焦点的 context 派发后向上走 Actions
    // 链。焦点节点住在 FushiFocusTarget 里，所以从它的 context 起跳最接近真实路径；
    // 只挂 onTap 的实现在这里拿不到任何反应。
    final BuildContext focusContext = tester.element(
      find.descendant(
        of: find.byType(NavRailBrandButton),
        matching: find.byType(FushiFocusTarget),
      ),
    );
    Actions.invoke(focusContext, const ActivateIntent());
    await tester.pump();

    expect(launchedUrls, <String>[kOfficialWebsiteUrl]);
  });

  testWidgets('brand icon exposes button semantics and the website tooltip', (
    WidgetTester tester,
  ) async {
    await pumpBrandButton(tester);

    expect(
      find.byTooltip(t.options_website),
      findsOneWidget,
      reason: '品牌位必须说明自己会打开官网，否则是个没有任何提示的可点图标',
    );

    final Iterable<Semantics> semantics = tester.widgetList<Semantics>(
      find.descendant(
        of: find.byType(NavRailBrandButton),
        matching: find.byType(Semantics),
      ),
    );
    expect(
      semantics.any((Semantics node) =>
          node.properties.button == true && node.properties.label == 'Fushi'),
      isTrue,
      reason: '退回成 Semantics(image: true) 的纯装饰图标时必须红',
    );
  });
}

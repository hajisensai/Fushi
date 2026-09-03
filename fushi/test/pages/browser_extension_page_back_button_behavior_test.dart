import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1748 行为测试：源码守卫只钉住 `leading: Navigator.of(context).canPop()`
/// 这个字面量存在，钉不住**运行时真的渲染出返回键**。用户在 12067 版本（已含
/// 守卫所钉的那次修复）仍报「设置 → 查词 → 浏览器扩展进去没有退出按钮」，
/// 说明必须黑盒 pump 真页面断言箭头。
/// 页面只读这几项状态；未初始化的 `prefsRepo` 会 NPE，逐项覆盖成常量。
class _FakeAppModel extends AppModel {
  _FakeAppModel() : super(testPlatformServices());

  @override
  bool get yomitanApiServerEnabled => false;

  @override
  int get yomitanApiPort => 19323;

  @override
  String get yomitanApiKey => '';
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('被 push 成全屏路由时，页头渲染出返回箭头', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => _FakeAppModel()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: Center(child: Text('base-route'))),
          ),
        ),
      ),
    );

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const BrowserExtensionPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    // 收尾：卸载页面，让页内 Timer.periodic 在 dispose 里被 cancel。
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

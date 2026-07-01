import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_schema_lookup.dart';
import 'package:hibiki/utils.dart';

/// TODO-1087：浏览器扩展安装引导弹窗的图文教程 widget 测试。
///
/// 验证：① 分步教程渲染（编号 1..5 + chrome://extensions 步骤 + 扩展路径步骤）；
/// ② chrome://extensions 与扩展路径都是「可复制字段」（点复制按钮写进剪贴板）；
/// ③ 自动配置横幅按 server/token 就绪与否切换成功/提醒文案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required bool serverEnabled,
    required bool hasToken,
    String path = r'/home/u/.local/share/hibiki/hibiki-browser-extension',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildBrowserExtensionInstallDialogForTest(
            path: path,
            serverEnabled: serverEnabled,
            hasToken: hasToken,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders numbered steps + chrome://extensions + path',
      (WidgetTester tester) async {
    const String path = r'/data/hibiki/hibiki-browser-extension';
    await pumpDialog(tester, serverEnabled: true, hasToken: true, path: path);

    // 分步编号 1..5 都在。
    for (final String n in <String>['1', '2', '3', '4', '5']) {
      expect(find.text(n), findsOneWidget, reason: 'missing step $n');
    }
    // chrome://extensions 作为可复制字段文本存在（不是埋在一段话里）。
    expect(find.text('chrome://extensions'), findsOneWidget);
    // 扩展文件夹路径存在且可选中/复制。
    expect(find.text(path), findsOneWidget);
    // 两处 SelectableText（可复制字段） + 复制按钮存在。
    expect(find.byIcon(Icons.copy), findsNWidgets(2));
  });

  testWidgets('copy button writes the extensions url to the clipboard',
      (WidgetTester tester) async {
    // 拦截剪贴板写入。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await pumpDialog(tester, serverEnabled: true, hasToken: true);

    // 第一个复制按钮 = chrome://extensions 字段。
    await tester.tap(find.byIcon(Icons.copy).first);
    await tester.pump();
    expect(copied, 'chrome://extensions');
  });

  testWidgets('banner shows ready state when server+token configured',
      (WidgetTester tester) async {
    await pumpDialog(tester, serverEnabled: true, hasToken: true);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
    expect(find.text(t.browser_extension_step_done_auto), findsWidgets);
  });

  testWidgets('banner nudges to enable server when not ready',
      (WidgetTester tester) async {
    await pumpDialog(tester, serverEnabled: false, hasToken: false);
    expect(find.text(t.browser_extension_enable_server_first), findsOneWidget);
  });
}

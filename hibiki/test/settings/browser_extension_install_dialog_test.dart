import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_schema_lookup.dart';
import 'package:hibiki/utils.dart';

/// TODO-1087：浏览器扩展安装引导弹窗的图文教程 widget 测试。
///
/// 验证：① 分步教程渲染（编号 1..5 + chrome:// 与 edge:// 两个扩展页步骤 + 扩展路径步骤）；
/// ② chrome://extensions / edge://extensions 与扩展路径都是「可复制字段」（点复制按钮写进剪贴板）；
/// ③ 自动配置横幅按 server/token 就绪与否切换成功/提醒文案。
/// TODO-1146：步骤 1 不再只硬编 chrome，Chrome 与 Edge 地址都列出（各一个可复制字段）。
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
    // chrome://extensions 与 edge://extensions 都作为可复制字段文本存在
    // （TODO-1146：不再只硬编 chrome，两浏览器各一条，不埋在一段话里）。
    expect(find.text('chrome://extensions'), findsOneWidget);
    expect(find.text('edge://extensions'), findsOneWidget);
    // 扩展文件夹路径存在且可选中/复制。
    expect(find.text(path), findsOneWidget);
    // 三处 SelectableText（可复制字段：chrome + edge + 路径） + 复制按钮存在。
    expect(find.byIcon(Icons.copy), findsNWidgets(3));
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

  // TODO-1146：源码/i18n 静态守卫。isDesktop 走 Platform.is*（宿主 OS），widget 测试无法
  // 切换到移动端，故移动分支 + 死 key 删除用源码扫描守。
  group('TODO-1146: mobile gating + edge url + dead-key removal', () {
    String schemaSrc() =>
        File('lib/src/settings/settings_schema_lookup.dart').readAsStringSync();

    test('install action gates mobile to the in-app-lookup message', () {
      final String src = schemaSrc();
      // 移动端（非 isDesktop）走专属提示分支，不解压扩展。
      expect(src, contains('!DesktopLookupService.isDesktop'),
          reason: '安装动作必须按平台门控（移动端走专属提示分支）');
      expect(src, contains('t.browser_extension_mobile_unsupported'),
          reason: '移动端显示手机专属提示文案');
    });

    test('step 1 lists both chrome and edge extension pages (no hardcode)', () {
      final String src = schemaSrc();
      expect(src, contains('browserExtensionsPageUrl(BrowserKind.chrome)'),
          reason: 'Chrome 扩展页地址复用纯函数');
      expect(src, contains('browserExtensionsPageUrl(BrowserKind.edge)'),
          reason: 'Edge 扩展页地址复用纯函数（TODO-1146：不再只硬编 chrome）');
    });

    test('contradictory dead i18n keys are removed from all locales', () {
      final Directory dir = Directory('lib/i18n');
      final List<File> files = dir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.i18n.json'))
          .toList();
      expect(files, isNotEmpty);
      for (final File f in files) {
        final String content = f.readAsStringSync();
        expect(content.contains('"browser_extension_install_steps"'), isFalse,
            reason: '死 key browser_extension_install_steps 应删除：${f.path}');
        expect(content.contains('"browser_extension_folder_label"'), isFalse,
            reason: '死 key browser_extension_folder_label 应删除：${f.path}');
        expect(
            content.contains('"browser_extension_mobile_unsupported"'), isTrue,
            reason: '手机提示 key 应存在于所有语言：${f.path}');
      }
    });
  });
}

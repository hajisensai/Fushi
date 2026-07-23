import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/browser_extension_page.dart';
import 'package:hibiki/utils.dart';

/// 浏览器扩展半自动安装引导（分步图文）的 widget 测试。
///
/// 引导原为「设置 → 查词」里的 AlertDialog，现已迁到桌面专属顶层页
/// [BrowserExtensionPage]（仅桌面出现），分步 widget 抽成 [BrowserExtensionInstallSteps]
/// 复用 + 暴露给测试。验证：① 分步教程渲染（编号 1..5 + chrome:// 与 edge:// 两个扩展页
/// 步骤 + 扩展路径步骤）；② chrome://extensions / edge://extensions 与扩展路径都是「可复制
/// 字段」（点复制按钮写进剪贴板）；③ 自动配置横幅按 server/token 就绪与否切换成功/提醒文案。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<void> pumpSteps(
    WidgetTester tester, {
    required bool serverEnabled,
    required bool hasToken,
    String path = r'/home/u/.local/share/hibiki/hibiki-browser-extension',
    bool portConflict = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: buildBrowserExtensionInstallStepsForTest(
              path: path,
              serverEnabled: serverEnabled,
              hasToken: hasToken,
              portConflict: portConflict,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders numbered steps + chrome://extensions + path',
      (WidgetTester tester) async {
    const String path = r'/data/hibiki/hibiki-browser-extension';
    await pumpSteps(tester, serverEnabled: true, hasToken: true, path: path);

    // 分步编号 1..5 都在。
    for (final String n in <String>['1', '2', '3', '4', '5']) {
      expect(find.text(n), findsOneWidget, reason: 'missing step $n');
    }
    // chrome://extensions 与 edge://extensions 都作为可复制字段文本存在。
    expect(find.text('chrome://extensions'), findsOneWidget);
    expect(find.text('edge://extensions'), findsOneWidget);
    // 扩展文件夹路径存在且可选中/复制。
    expect(find.text(path), findsOneWidget);
    // 三处可复制字段（chrome + edge + 路径）各一个复制按钮。
    expect(find.byIcon(Icons.copy), findsNWidgets(3));
  });

  testWidgets('copy button writes the extensions url to the clipboard',
      (WidgetTester tester) async {
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

    await pumpSteps(tester, serverEnabled: true, hasToken: true);

    // 第一个复制按钮 = chrome://extensions 字段。
    await tester.tap(find.byIcon(Icons.copy).first);
    await tester.pump();
    expect(copied, 'chrome://extensions');
  });

  testWidgets(
      'ready state hides the redundant banner (done text only at step 5)',
      (WidgetTester tester) async {
    await pumpSteps(tester, serverEnabled: true, hasToken: true);
    // 就绪时不再显示顶部横幅：既没有提醒文案，也没有横幅的实心对勾图标。
    expect(find.text(t.browser_extension_enable_server_first), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    // 「完成」文案只在步骤 5 出现一次（步骤 5 用的是描边对勾 check_circle_outline）。
    expect(find.text(t.browser_extension_step_done_auto), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('banner nudges to enable server when not ready',
      (WidgetTester tester) async {
    await pumpSteps(tester, serverEnabled: false, hasToken: false);
    expect(find.text(t.browser_extension_enable_server_first), findsOneWidget);
  });

  testWidgets('port conflict explains how to hand 19633 from Yomitan to Hibiki',
      (WidgetTester tester) async {
    await pumpSteps(
      tester,
      serverEnabled: false,
      hasToken: true,
      portConflict: true,
    );
    expect(
      find.text(t.browser_extension_yomitan_port_conflict(port: 19633)),
      findsOneWidget,
    );
  });

  group('install flow moved to desktop-only page + i18n hygiene', () {
    test('install action removed from lookup settings', () {
      final String src = File('lib/src/settings/settings_schema_lookup.dart')
          .readAsStringSync();
      // 安装入口已从查词设置移除（迁到 BrowserExtensionPage）。
      expect(src.contains("id: 'lookup.install_browser_extension'"), isFalse,
          reason: '安装入口已移出查词设置，不应再有该 SettingsActionItem');
      expect(src.contains('_BrowserExtensionInstallDialog'), isFalse,
          reason: '安装弹窗已迁到 browser_extension_page.dart');
    });

    test('page lists both chrome and edge extension pages (no hardcode)', () {
      final String src =
          File('lib/src/pages/implementations/browser_extension_page.dart')
              .readAsStringSync();
      expect(src, contains('browserExtensionsPageUrl(BrowserKind.chrome)'),
          reason: 'Chrome 扩展页地址复用纯函数');
      expect(src, contains('browserExtensionsPageUrl(BrowserKind.edge)'),
          reason: 'Edge 扩展页地址复用纯函数');
    });

    test('browser extension tab is desktop-only (电脑才有)', () {
      final String src = File('lib/src/pages/implementations/home_page.dart')
          .readAsStringSync();
      // 顶层 tab 由平台门控：仅桌面（DesktopLookupService.isDesktop）插入。
      expect(src,
          contains('browserExtensionEnabled: DesktopLookupService.isDesktop'),
          reason: '浏览器扩展 tab 必须按桌面平台门控（电脑才有）');
    });

    test('contradictory dead i18n keys stay removed across all locales', () {
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

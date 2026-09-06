import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';
import 'package:fushi/utils.dart';

/// 浏览器扩展半自动安装引导（分步图文）的 widget 测试。
///
/// 引导原为「设置 → 查词」里的 AlertDialog，现已迁到桌面专属顶层页
/// [BrowserExtensionPage]（仅桌面出现），分步 widget 抽成 [BrowserExtensionInstallSteps]
/// 复用 + 暴露给测试。验证：① 分步教程渲染（编号 1..5 + [BrowserKind.values] 每个浏览器
/// 一条扩展页地址 + 扩展路径步骤）；② 每条扩展页地址与扩展路径都是「可复制
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
    String path = r'/home/u/.local/share/fushi/fushi-browser-extension',
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

  testWidgets('renders numbered steps + every browser extensions url + path',
      (WidgetTester tester) async {
    const String path = r'/data/fushi/fushi-browser-extension';
    await pumpSteps(tester, serverEnabled: true, hasToken: true, path: path);

    // 分步编号 1..5 都在。
    for (final String n in <String>['1', '2', '3', '4', '5']) {
      expect(find.text(n), findsOneWidget, reason: 'missing step $n');
    }
    // 每个受支持浏览器的扩展页地址都作为可复制字段文本存在（步骤 1 按枚举遍历渲染，
    // 新增 BrowserKind 时这里自动跟着要求它出现在引导里，不会漏渲染）。
    expect(BrowserKind.values, hasLength(greaterThanOrEqualTo(2)));
    for (final BrowserKind kind in BrowserKind.values) {
      expect(find.text(browserExtensionsPageUrl(kind)), findsOneWidget,
          reason: '$kind 的扩展页地址没渲染出来');
    }
    // 扩展文件夹路径存在且可选中/复制。
    expect(find.text(path), findsOneWidget);
    // 可复制字段 = 每个浏览器一个 + 扩展路径一个，各带一个复制按钮。
    expect(
        find.byIcon(Icons.copy), findsNWidgets(BrowserKind.values.length + 1));
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

    // 原守卫断言页面里含 `browserExtensionsPageUrl(BrowserKind.chrome)` /
    // `(BrowserKind.edge)` 两处字面调用——那正是「加一个浏览器要记得同时改 UI」的
    // 逐浏览器硬编码。列表改为按枚举遍历后，这里换成同义但更强的判据：支持范围的
    // 唯一真相源是 BrowserKind，页面既不逐个点名、也不自己拼 URL。
    test('page drives the browser list from BrowserKind.values (no hardcode)',
        () {
      final String src =
          File('lib/src/pages/implementations/browser_extension_page.dart')
              .readAsStringSync();
      expect(
          src, contains('for (final BrowserKind kind in BrowserKind.values)'),
          reason: '扩展页地址列表必须按 BrowserKind.values 遍历渲染');
      expect(src, contains('browserExtensionsPageUrl(kind)'),
          reason: '扩展页地址复用纯函数 browserExtensionsPageUrl');
      for (final BrowserKind kind in BrowserKind.values) {
        expect(src, isNot(contains('BrowserKind.${kind.name}')),
            reason: '页面不得逐个点名浏览器（BrowserKind.${kind.name}）：'
                '新增浏览器只该改枚举，不该回来改 UI');
      }
      expect(src, isNot(contains('://extensions')),
          reason: '页面不得写死扩展页 URL 字面量，一律经 browserExtensionsPageUrl 取');
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

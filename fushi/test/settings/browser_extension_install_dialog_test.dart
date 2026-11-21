import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/lookup/browser_default_detector.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';
import 'package:fushi/src/pages/implementations/web_hub_page.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/i18n/strings.g.dart';

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
              // flutter_test 默认平台是安卓；这些用例钉的是桌面流程。
              flow: BrowserExtensionInstallFlow.desktop,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'renders numbered steps, one chip per browser, one url at a time + path',
    (WidgetTester tester) async {
      const String path = r'/data/fushi/fushi-browser-extension';
      await pumpSteps(tester, serverEnabled: true, hasToken: true, path: path);

      // 分步编号 1..5 都在（stepper 初始停在第 1 步，后面都还是数字）。
      for (final String n in <String>['1', '2', '3', '4', '5']) {
        expect(find.text(n), findsOneWidget, reason: 'missing step $n');
      }
      // 每个受支持浏览器一枚 chip（步骤 1 按枚举遍历渲染，新增 BrowserKind 时这里
      // 自动跟着要求它出现在引导里，不会漏渲染）；地址只显示选中的那一个。
      expect(BrowserKind.values, hasLength(greaterThanOrEqualTo(2)));
      for (final BrowserKind kind in BrowserKind.values) {
        expect(
          find.text(browserDisplayName(kind)),
          findsOneWidget,
          reason: '$kind 的浏览器 chip 没渲染出来',
        );
      }
      final BrowserKind first = BrowserKind.values.first;
      expect(find.text(browserExtensionsPageUrl(first)), findsOneWidget);
      for (final BrowserKind kind in BrowserKind.values.skip(1)) {
        expect(
          find.text(browserExtensionsPageUrl(kind)),
          findsNothing,
          reason: '未选中的浏览器不该再各占一行地址',
        );
      }
      // 点另一个浏览器 chip → 地址换成它的。
      final BrowserKind second = BrowserKind.values[1];
      await tester.tap(find.text(browserDisplayName(second)));
      await tester.pumpAndSettle();
      expect(find.text(browserExtensionsPageUrl(second)), findsOneWidget);
      expect(find.text(browserExtensionsPageUrl(first)), findsNothing);

      // 第 4 步展开后：扩展文件夹路径卡（可选中 / 复制）出现。
      expect(find.text(path), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey<String>('browser-extension-step-3')),
      );
      await tester.pumpAndSettle();
      expect(find.text(path), findsOneWidget);
    },
  );

  testWidgets('Android flow: Vivaldi step, no desktop browser chips', (
    WidgetTester tester,
  ) async {
    const String path =
        '/storage/emulated/0/Download/Fushi/fushi-browser-extension';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: buildBrowserExtensionInstallStepsForTest(
              path: path,
              serverEnabled: true,
              hasToken: true,
              flow: BrowserExtensionInstallFlow.android,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 5 步都在，前两步换成安卓的。
    for (final String n in <String>['1', '2', '3', '4', '5']) {
      expect(find.text(n), findsOneWidget, reason: 'missing step $n');
    }
    expect(find.text(t.browser_extension_android_step_browser), findsOneWidget);
    expect(find.text(t.browser_extension_android_browser_hint), findsOneWidget);
    expect(find.text(t.browser_extension_android_get_browser), findsOneWidget);
    expect(find.text(t.browser_extension_android_step_manager), findsOneWidget);
    expect(find.text(t.browser_extension_step_load_unpacked), findsOneWidget);
    // 桌面的浏览器分段与扩展页地址不出现。
    for (final BrowserKind kind in BrowserKind.values) {
      expect(find.text(browserExtensionsPageUrl(kind)), findsNothing);
    }
    // 第 4 步：路径 + 安卓文件夹选择提示，没有「在文件管理器中打开」。
    final Finder step4 = find.byKey(
      const ValueKey<String>('browser-extension-step-3'),
    );
    await tester.ensureVisible(step4);
    await tester.pumpAndSettle();
    await tester.tap(step4);
    await tester.pumpAndSettle();
    expect(find.text(path), findsOneWidget);
    expect(find.text(t.browser_extension_android_folder_hint), findsOneWidget);
    expect(find.byTooltip(t.media_file_location_open), findsNothing);
    // 第 5 步：提醒 Fushi 要留在后台。
    final Finder step5 = find.byKey(
      const ValueKey<String>('browser-extension-step-4'),
    );
    await tester.ensureVisible(step5);
    await tester.pumpAndSettle();
    await tester.tap(step5);
    await tester.pumpAndSettle();
    expect(find.text(t.browser_extension_android_keep_running), findsOneWidget);
  });

  testWidgets('desktop flow keeps the browser step', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: buildBrowserExtensionInstallStepsForTest(
              path: '/x',
              serverEnabled: true,
              hasToken: true,
              flow: BrowserExtensionInstallFlow.desktop,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.browser_extension_android_step_browser), findsNothing);
    expect(find.text(t.browser_extension_step_dev_mode), findsOneWidget);
    expect(
      find.text(browserExtensionsPageUrl(BrowserKind.values.first)),
      findsOneWidget,
    );
  });

  testWidgets('detected default browser is preselected', (
    WidgetTester tester,
  ) async {
    final BrowserKind detected = BrowserKind.values.last;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: buildBrowserExtensionInstallStepsForTest(
              path: '/x',
              serverEnabled: true,
              hasToken: true,
              detectedBrowser: detected,
              flow: BrowserExtensionInstallFlow.desktop,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(browserExtensionsPageUrl(detected)), findsOneWidget);
  });

  testWidgets('copy button writes the extensions url to the clipboard', (
    WidgetTester tester,
  ) async {
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
      // 就绪时不再显示顶部横幅。
      expect(find.text(t.browser_extension_enable_server_first), findsNothing);
      // 「完成」文案只在最后一步（验证连接）展开后出现一次。
      expect(find.text(t.browser_extension_step_done_auto), findsNothing);
      // #3515 的状态块 + 三格检查让步骤列表变长，第 5 步落到 800×600 视口外。
      final Finder step5 = find.byKey(
        const ValueKey<String>('browser-extension-step-4'),
      );
      await tester.ensureVisible(step5);
      await tester.pumpAndSettle();
      await tester.tap(step5);
      await tester.pumpAndSettle();
      expect(find.text(t.browser_extension_step_done_auto), findsOneWidget);
    },
  );

  testWidgets('banner nudges to enable server when not ready', (
    WidgetTester tester,
  ) async {
    await pumpSteps(tester, serverEnabled: false, hasToken: false);
    expect(find.text(t.browser_extension_enable_server_first), findsOneWidget);
  });

  testWidgets(
    'port conflict explains how to hand 19633 from Yomitan to Fushi',
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
    },
  );

  group('install flow moved to desktop-only page + i18n hygiene', () {
    test('install action removed from lookup settings', () {
      final String src = File(
        'lib/src/settings/settings_schema_lookup.dart',
      ).readAsStringSync();
      // 安装入口已从查词设置移除（迁到 BrowserExtensionPage）。
      expect(
        src.contains("id: 'lookup.install_browser_extension'"),
        isFalse,
        reason: '安装入口已移出查词设置，不应再有该 SettingsActionItem',
      );
      expect(
        src.contains('_BrowserExtensionInstallDialog'),
        isFalse,
        reason: '安装弹窗已迁到 browser_extension_page.dart',
      );
    });

    // 原守卫断言页面里含 `browserExtensionsPageUrl(BrowserKind.chrome)` /
    // `(BrowserKind.edge)` 两处字面调用——那正是「加一个浏览器要记得同时改 UI」的
    // 逐浏览器硬编码。列表改为按枚举遍历后，这里换成同义但更强的判据：支持范围的
    // 唯一真相源是 BrowserKind，页面既不逐个点名、也不自己拼 URL。
    test(
      'page drives the browser list from BrowserKind.values (no hardcode)',
      () {
        final String src = File(
          'lib/src/pages/implementations/browser_extension_page.dart',
        ).readAsStringSync();
        expect(
          src,
          contains('for (final BrowserKind kind in BrowserKind.values)'),
          reason: '扩展页地址列表必须按 BrowserKind.values 遍历渲染',
        );
        expect(
          src,
          contains('browserExtensionsPageUrl(kind)'),
          reason: '扩展页地址复用纯函数 browserExtensionsPageUrl',
        );
        for (final BrowserKind kind in BrowserKind.values) {
          expect(
            src,
            isNot(contains('BrowserKind.${kind.name}')),
            reason:
                '页面不得逐个点名浏览器（BrowserKind.${kind.name}）：'
                '新增浏览器只该改枚举，不该回来改 UI',
          );
        }
        expect(
          src,
          isNot(contains('://extensions')),
          reason: '页面不得写死扩展页 URL 字面量，一律经 browserExtensionsPageUrl 取',
        );
      },
    );

    test('install guide: desktop and Android have it, iOS does not', () {
      // 2026-11-20 用户拍板：安卓也给安装引导（Vivaldi 从文件夹加载）。判据只在
      // browserExtensionInstallFlowOn 一处；「浏览器」页、设置入口、新手引导都问它。
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(
          browserExtensionInstallFlowOn(p),
          BrowserExtensionInstallFlow.desktop,
          reason: '$p',
        );
      }
      expect(
        browserExtensionInstallFlowOn(TargetPlatform.android),
        BrowserExtensionInstallFlow.android,
      );
      expect(
        browserExtensionInstallFlowOn(TargetPlatform.iOS),
        isNull,
        reason: 'iOS 没有 Safari Web Extension 目标，装不了这个扩展',
      );
      expect(browserExtensionInstallAvailableOn(TargetPlatform.iOS), isFalse);
      expect(
        webHubSectionAvailable(WebHubSection.browserExtension),
        browserExtensionInstallAvailableOn(defaultTargetPlatform),
      );
    });

    test('login-import bridge stays desktop-only (电脑才有)', () {
      // 原本扫的是 home_page.dart 里的字面量
      // `browserExtensionEnabled: DesktopLookupService.isDesktop`。那个参数已经
      // 不存在了：模块门控收口后，平台判据只在 ModuleId.availableOn 写一次
      // （旧实现散在 home_page / main / settings_schema_appearance 四处，正是漂移
      // 的来源）。所以这里改成**断言新真相源的行为**——比扫字面量强，也不会因为
      // 下一次接线换写法而无辜变红。
      // 2026-10-19 起扩展页是「浏览器」模块（五端都有）的次级子页，桌面限定的
      // 判据收在 browserExtensionSupportedOn 一处；「浏览器」页与新手引导的扩展
      // 步骤都问它。
      expect(
        browserExtensionSupportedOn(isDesktop: false),
        isFalse,
        reason: '手机浏览器装不了未解压扩展，非桌面必须没有扩展子页',
      );
      expect(browserExtensionSupportedOn(isDesktop: true), isTrue);
      expect(DesktopLookupService.isDesktop, isA<bool>());
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
        expect(
          content.contains('"browser_extension_install_steps"'),
          isFalse,
          reason: '死 key browser_extension_install_steps 应删除：${f.path}',
        );
        expect(
          content.contains('"browser_extension_folder_label"'),
          isFalse,
          reason: '死 key browser_extension_folder_label 应删除：${f.path}',
        );
        expect(
          content.contains('"browser_extension_mobile_unsupported"'),
          isTrue,
          reason: '手机提示 key 应存在于所有语言：${f.path}',
        );
      }
    });
  });
}

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';
import 'package:fushi/src/lookup/browser_extension_setup.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/browser_extension_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';

import '../helpers/test_platform_services.dart';

/// 安卓「准备扩展文件」要往公共 Download/Fushi 写，用户拒绝全文件访问时：
/// ① 不去解压（否则抛 FileSystemException）；② 页面复位「准备中」，按钮可再点，
/// 并提示去授权。此前 `_prepare` 没有 finally，异常后按钮永远转圈。
class _DeniedStorageAppModel extends AppModel {
  _DeniedStorageAppModel() : super(testPlatformServices());

  int permissionRequests = 0;

  @override
  bool get fushiApiServerEnabled => true;

  @override
  int get fushiApiPort => 19323;

  @override
  String get fushiApiKey => 'token';

  @override
  Future<bool> ensureFushiApiServerForBrowserExtension() async => true;

  @override
  Future<bool> hasExternalStoragePermission() async => false;

  @override
  Future<void> requestExternalStoragePermissions() async {
    permissionRequests++;
  }
}

Future<BrowserKind?> _noDefaultBrowser() async => null;

/// 页面有进场错峰与步骤展开动效（AnimatedSize / 交叉淡入），动效期间旧层盖在上面
/// 接不到点击；准备按钮转圈是无限动画，不能 pumpAndSettle，这里按固定时长推帧。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('安卓未授权：申请后复查仍拒绝 → 抛未授权异常，不解压', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final _DeniedStorageAppModel appModel = _DeniedStorageAppModel();
    bool extracted = false;
    await expectLater(
      prepareBrowserExtensionForInstall(
        appModel,
        extract: ({required BrowserExtensionServerConfig serverConfig}) async {
          extracted = true;
          return '/unused';
        },
      ),
      throwsA(isA<BrowserExtensionStoragePermissionDenied>()),
    );
    expect(appModel.permissionRequests, 1, reason: '没权限时应先申请一次');
    expect(extracted, isFalse, reason: '未授权不得去写公共 Download');
  });

  testWidgets('安卓拒绝存储权限后，「准备扩展文件」复位可点并提示授权', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _DeniedStorageAppModel appModel = _DeniedStorageAppModel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
        child: TranslationProvider(
          child: const MaterialApp(
            home: BrowserExtensionPage(detectBrowser: _noDefaultBrowser),
          ),
        ),
      ),
    );
    await _settle(tester);

    // 安卓流程第 4 步（index 3）是「选文件夹」，里面有「准备扩展文件」。
    await tester.tap(
      find.byKey(const ValueKey<String>('browser-extension-step-3')),
    );
    await _settle(tester);

    final Finder prepare = find.text(t.browser_extension_prepare_button);
    expect(prepare, findsOneWidget);
    await tester.ensureVisible(prepare);
    await _settle(tester);
    await tester.tap(prepare);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(appModel.permissionRequests, 1);
    expect(
      find.text(t.browser_extension_android_storage_denied),
      findsOneWidget,
      reason: '未授权要明确提示去授权',
    );
    final FushiFilledButton button = tester.widget<FushiFilledButton>(
      find.ancestor(of: prepare, matching: find.byType(FushiFilledButton)),
    );
    expect(button.onPressed, isNotNull, reason: '失败后必须复位 _preparing，按钮可再点');

    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/download_network_proxy.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/download_backend_setup_dialog.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// 下载后端的**呈现顺序**与**配置引导**。
///
/// 断言的是真实渲染：段的先后用两个标签的实际横坐标比，不是「字符串存在」——
/// 把两段调换回去，本文件必须红。
class _TestAppModel extends AppModel {
  _TestAppModel({
    required QbConnectionConfig config,
    this.embeddedReady = true,
  })  : _config = config,
        super(testPlatformServices());

  QbConnectionConfig _config;
  final bool embeddedReady;
  final String saveRoot = r'D:\downloads';

  /// 引导点「完成」时写进来的配置（断言真的落到了 AppModel）。
  QbConnectionConfig? saved;
  int pipelineReloads = 0;

  @override
  Locale get appLocale => const Locale('en', 'US');

  @override
  PackageInfo get packageInfo => PackageInfo(
        appName: 'Hibiki',
        packageName: 'jp.hibiki.test',
        version: '1.0.0',
        buildNumber: '1',
      );

  @override
  QbConnectionConfig? get qbConnectionConfig => _config;

  @override
  Future<void> setQbConnectionConfig(QbConnectionConfig? config) async {
    saved = config;
    if (config != null) _config = config;
  }

  @override
  Future<void> reloadVideoDownloadPipelineRuntime() async => pipelineReloads++;

  @override
  bool get supportsEmbeddedTorrent => true;

  @override
  bool get isEmbeddedTorrentReady => embeddedReady;

  @override
  String get downloadSaveRoot => saveRoot;

  @override
  DownloadNetworkProxyConfig get downloadNetworkProxyConfig =>
      const DownloadNetworkProxyConfig();
}

Widget _harness(
  _TestAppModel appModel,
  Widget child, {
  bool scrollable = true,
}) {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  appModel.themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });

  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          FushiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      // 对话框走 Center：AlertDialog 自带 IntrinsicWidth，套进滚动视图会去问
      // FushiSegmentedStrip 的 LayoutBuilder 要固有高度而炸掉（生产路径是
      // showAppDialog，本来就不在滚动视图里）。
      home: Scaffold(
        body: SizedBox(
          width: 900,
          child: scrollable
              ? SingleChildScrollView(child: child)
              : Center(child: child),
        ),
      ),
    ),
  );
}

/// 两个后端标签的实际横坐标：内置引擎必须在外接 qb 左边。
void _expectEmbeddedRendersFirst(WidgetTester tester) {
  final Finder embedded =
      find.text(t.video_setting_torrent_backend_embedded).last;
  final Finder qb = find.text(t.video_setting_torrent_backend_qb).last;
  expect(embedded, findsOneWidget);
  expect(qb, findsOneWidget);
  expect(
    tester.getTopLeft(embedded).dx,
    lessThan(tester.getTopLeft(qb).dx),
    reason: '内置引擎是开箱即用的默认后端，必须排在外接 qBittorrent 前面',
  );
}

void main() {
  testWidgets('下载设置：内置引擎段排在外接 qBittorrent 之前', (WidgetTester tester) async {
    final _TestAppModel appModel =
        _TestAppModel(config: const QbConnectionConfig());
    await tester.pumpWidget(_harness(
      appModel,
      const TorrentSettingsSection(embeddedSupportedOverride: true),
    ));
    await tester.pump();
    _expectEmbeddedRendersFirst(tester);
  });

  testWidgets('引导：段序同上，且开屏即停在内置引擎', (WidgetTester tester) async {
    final _TestAppModel appModel =
        _TestAppModel(config: const QbConnectionConfig());
    await tester.pumpWidget(_harness(
      appModel,
      DownloadBackendSetupDialog(
        appModel: appModel,
        embeddedSupportedOverride: true,
      ),
      scrollable: false,
    ));
    await tester.pump();

    _expectEmbeddedRendersFirst(tester);
    // 内置分支渲染的是「下载目录」，不是 qb 地址输入框：证明选中的是内置引擎，
    // 而不是只把标签画在了第一位。
    expect(find.text(appModel.saveRoot), findsOneWidget);
    expect(find.text(t.video_setting_qb_url), findsNothing);
  });

  testWidgets('引导：内置引擎一步落库，无需填任何字段', (WidgetTester tester) async {
    final _TestAppModel appModel =
        _TestAppModel(config: const QbConnectionConfig());
    await tester.pumpWidget(_harness(
      appModel,
      DownloadBackendSetupDialog(
        appModel: appModel,
        embeddedSupportedOverride: true,
      ),
      scrollable: false,
    ));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, t.dialog_done));
    await tester.pumpAndSettle();

    expect(appModel.saved?.backend, QbConnectionConfig.backendEmbedded);
    expect(appModel.pipelineReloads, 1,
        reason: '后端刚配好，管线 runtime 必须重建，否则仍报「后端未配置」');
  });

  testWidgets('引导：内置引擎运行库缺失时不让「完成」，并说清原因',
      (WidgetTester tester) async {
    final _TestAppModel appModel = _TestAppModel(
      config: const QbConnectionConfig(),
      embeddedReady: false,
    );
    await tester.pumpWidget(_harness(
      appModel,
      DownloadBackendSetupDialog(
        appModel: appModel,
        embeddedSupportedOverride: true,
      ),
      scrollable: false,
    ));
    await tester.pump();

    expect(find.text(t.download_backend_embedded_unavailable), findsOneWidget);
    final FilledButton done = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, t.dialog_done),
    );
    expect(done.onPressed, isNull,
        reason: '缺 DLL 的包配了也下不了，不能让用户以为配好了');
  });

  testWidgets('引导：切到外接 qb 后地址是必填项', (WidgetTester tester) async {
    final _TestAppModel appModel =
        _TestAppModel(config: const QbConnectionConfig());
    await tester.pumpWidget(_harness(
      appModel,
      DownloadBackendSetupDialog(
        appModel: appModel,
        embeddedSupportedOverride: true,
      ),
      scrollable: false,
    ));
    await tester.pump();

    await tester.tap(find.text(t.video_setting_torrent_backend_qb).last);
    await tester.pumpAndSettle();

    expect(find.text(t.video_setting_qb_url), findsOneWidget);
    FilledButton done() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, t.dialog_done),
        );
    expect(done().onPressed, isNull, reason: '地址空着的 qb 后端连不上');

    await tester.enterText(
      find.byType(TextField).first,
      'http://127.0.0.1:8080',
    );
    await tester.pump();
    expect(done().onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, t.dialog_done));
    await tester.pumpAndSettle();
    expect(appModel.saved?.backend, QbConnectionConfig.backendQbittorrent);
    expect(appModel.saved?.baseUrl, 'http://127.0.0.1:8080');
  });

  // 「非空」不是可用地址。qb 用户最常见的手输形式没有 scheme，而后端身份解析
  // （normalizeQbBackendAddress）要求 http/https + 非空 host。用「非空」放行的话，
  // 用户点完「完成」→ 落库 → 调用方解析身份抛 ArgumentError → 被当成「未配置」
  // 再弹一次本对话框，字段原样、没有任何提示，走不出去——正是本对话框要消灭的
  // 那种死路，被以模态弹窗的形式重造一遍。
  testWidgets('引导：缺 scheme 的地址被拒，且当场说明要填什么',
      (WidgetTester tester) async {
    final _TestAppModel appModel =
        _TestAppModel(config: const QbConnectionConfig());
    await tester.pumpWidget(_harness(
      appModel,
      DownloadBackendSetupDialog(
        appModel: appModel,
        embeddedSupportedOverride: true,
      ),
      scrollable: false,
    ));
    await tester.pump();
    await tester.tap(find.text(t.video_setting_torrent_backend_qb).last);
    await tester.pumpAndSettle();

    FilledButton done() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, t.dialog_done),
        );

    for (final String bad in <String>[
      '127.0.0.1:8080',
      'localhost:8080',
      'qb.example.com',
    ]) {
      await tester.enterText(find.byType(TextField).first, bad);
      await tester.pump();
      expect(done().onPressed, isNull,
          reason: '「$bad」解析不出后端身份，放行就会让用户困在配置引导里');
      expect(find.text(t.download_backend_qb_url_invalid), findsOneWidget,
          reason: '拒绝必须当场告诉用户该填什么，否则和静默失败无异');
      expect(appModel.saved, isNull, reason: '被拒的地址不得落库');
    }

    // 补全 scheme 后立刻可用，且错误提示消失（不是一直报红）。
    await tester.enterText(
      find.byType(TextField).first,
      'http://127.0.0.1:8080',
    );
    await tester.pump();
    expect(done().onPressed, isNotNull);
    expect(find.text(t.download_backend_qb_url_invalid), findsNothing);
  });
}

// 「限速也作用于局域网」开关的 app 侧守卫。
//
// 两件必须守住的事：
//  1. 限速输入框下方那句说明**随开关变化**。开关打开后，「不作用于局域网」
//     就是一句和实际行为相反的假话；界面绝不能写假话。
//  2. 开关的值真的从 QbConnectionConfig 流到 EmbeddedTorrentHost.applyLimits
//     （AppModel 那一段是纯 native 下发，widget 测不到，用源码守卫兜）。

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/download_network_proxy.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(this._config) : super(testPlatformServices());

  QbConnectionConfig _config;

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

  // prefs 未初始化的裸 AppModel：只在内存里记住配置，不落盘、不碰 native。
  @override
  Future<void> setQbConnectionConfig(QbConnectionConfig? config) async {
    if (config != null) _config = config;
  }

  @override
  DownloadNetworkProxyConfig get downloadNetworkProxyConfig =>
      const DownloadNetworkProxyConfig();
}

Widget _harness(QbConnectionConfig config) {
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
  final AppModel appModel = _TestAppModel(config)
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          FushiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Scaffold(
        body: SizedBox(
          width: 900,
          child: SingleChildScrollView(child: TorrentSettingsSection()),
        ),
      ),
    ),
  );
}

const QbConnectionConfig _embedded = QbConnectionConfig(
  backend: QbConnectionConfig.backendEmbedded,
  downloadLimitKbps: 512,
);

void main() {
  const String exempt =
      'Does not apply within your local network; LAN transfers always run at '
      'full speed.';
  const String included = 'Also applies within your local network.';

  testWidgets('开关关闭时说明写「不作用于局域网」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_embedded));
    await tester.pumpAndSettle();

    expect(find.text(exempt), findsWidgets);
    expect(find.text(included), findsNothing);
  });

  testWidgets('开关打开时说明翻成「同时作用于局域网」，绝不留下假话', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester
        .pumpWidget(_harness(_embedded.copyWith(limitLocalPeers: true)));
    await tester.pumpAndSettle();

    expect(find.text(included), findsWidgets);
    // 这条是整个文案改动的靶心：开关开着还显示「不作用于局域网」= 界面撒谎。
    expect(find.text(exempt), findsNothing,
        reason: 'helper must not assert LAN is exempt while the toggle is on');
  });

  testWidgets('开关默认关，且渲染出来了', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_embedded));
    await tester.pumpAndSettle();

    expect(find.text('Apply limits to LAN peers'), findsOneWidget);
    expect(
        find.text('Off by default: transfers with peers on your local network '
            'ignore the limits above.'),
        findsOneWidget,
        reason: '副标题要讲清默认行为，用户才知道翻开关会改变什么');
  });

  test('AppModel 把 limitLocalPeers 透传给 EmbeddedTorrentHost.applyLimits', () {
    // 源码守卫：这段是纯 native 下发（要真 DLL + 真局域网 peer 才看得见效果），
    // widget/单测都探不到。少了这一行，用户翻开关就完全没反应，而且**没有任何
    // 其它测试会红**——所以这条守卫是必要的，不是凑数。
    final File f = File('lib/src/models/app_model.dart');
    expect(f.existsSync(), isTrue, reason: 'run from the hibiki/ package root');
    final String src = f.readAsStringSync();
    final int call = src.indexOf('host.applyLimits(');
    expect(call, greaterThanOrEqualTo(0),
        reason: 'AppModel must still apply limits to the embedded host');
    final String block = src.substring(call, src.indexOf(');', call));
    expect(block, contains('limitLocalPeers:'),
        reason:
            'the LAN toggle must reach native, or it silently does nothing');
  });
}

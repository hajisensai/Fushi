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

/// BUG-1207：无内置引擎的平台（Android 支持后只剩 iOS——它从不构建也从不
/// 打包 `libfushi_torrent_ffi.so`）不得把「内置引擎」画出来让用户选中：
/// 选中后还会暴露一个**只有内置引擎才读**的下载目录，而实际运行时
/// `EmbeddedTorrentHost.open` 吞掉 `ArgumentError` 返回 null，
/// `_torrentBackendFor` 静默造一个 `QbTorrentBackend` —— 用户以为自己在用
/// 内置引擎、以为改的下载目录生效了，两件事都不成立。
///
/// 本守卫断言的是**真实渲染行为**（不是「某字符串存在」）：无内置引擎平台下
/// 后端选择器与下载目录必须整块不出现，且必须真的落到外接 qb 分支。
class _TestAppModel extends AppModel {
  _TestAppModel(this._config) : super(testPlatformServices());

  final QbConnectionConfig _config;

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
  DownloadNetworkProxyConfig get downloadNetworkProxyConfig =>
      const DownloadNetworkProxyConfig();
}

/// 存量配置：用户在某个版本里**显式**选过内置引擎（不是 auto），
/// 这正是 `resolveBackend` 过去原样放行、酿成死设置的那一类。
const QbConnectionConfig _explicitEmbedded = QbConnectionConfig(
  backend: QbConnectionConfig.backendEmbedded,
);

Widget _harness({required bool embeddedSupported}) {
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
  final AppModel appModel = _TestAppModel(_explicitEmbedded)
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
          child: SingleChildScrollView(
            child: TorrentSettingsSection(
                embeddedSupportedOverride: embeddedSupported),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('resolveBackend 按平台能力规约（BUG-1207 根因层）', () {
    test('无内置引擎的平台：显式 embedded 也必须解析成外接 qb', () {
      expect(
        _explicitEmbedded.resolveBackend(embeddedSupported: false),
        QbConnectionConfig.backendQbittorrent,
        reason: 'iOS 没有 libfushi_torrent_ffi.so，解析出 embedded 只会静默回退',
      );
    });

    test('有内置引擎的平台：显式 embedded 原样保留', () {
      expect(
        _explicitEmbedded.resolveBackend(embeddedSupported: true),
        QbConnectionConfig.backendEmbedded,
      );
    });

    test('auto 的既有行为不变（有引擎 embedded / 无引擎 qb）', () {
      const QbConnectionConfig auto = QbConnectionConfig();
      expect(auto.backend, QbConnectionConfig.backendAuto);
      expect(auto.resolveBackend(embeddedSupported: true),
          QbConnectionConfig.backendEmbedded);
      expect(auto.resolveBackend(embeddedSupported: false),
          QbConnectionConfig.backendQbittorrent);
    });

    test('显式 qbittorrent 在任何平台都是 qb', () {
      const QbConnectionConfig qb = QbConnectionConfig(
        backend: QbConnectionConfig.backendQbittorrent,
      );
      expect(qb.resolveBackend(embeddedSupported: true),
          QbConnectionConfig.backendQbittorrent);
      expect(qb.resolveBackend(embeddedSupported: false),
          QbConnectionConfig.backendQbittorrent);
    });
  });

  testWidgets('无内置引擎平台：后端选择器与下载目录整块不渲染，落到外接 qb 分支',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(embeddedSupported: false));
    await tester.pumpAndSettle();

    // ① 后端二选一整个控件不存在——用户点不到一个够不着的档位。
    //    （代理模式那条 strip 是 FushiSegmentedStrip<DownloadNetworkProxyMode>，
    //     泛型不同，不会被这个 finder 命中。）
    expect(find.byType(FushiSegmentedStrip<String>), findsNothing,
        reason: '本平台没有第二个可用后端，选择器必须整块不渲染');
    expect(find.text(t.video_setting_torrent_backend_embedded), findsNothing,
        reason: '「内置引擎」在本平台不存在，不得出现在界面上');

    // ② 死设置消失：下载目录只被内置引擎读取，外接 qb 的落盘目录 qb 自己管。
    expect(find.text(t.download_save_root_title), findsNothing,
        reason: '下载目录在无引擎平台改了不被任何人采用，不得暴露给用户');
    expect(find.text(t.download_save_root_change), findsNothing);

    // ③ 真的落到 qb 分支（不是整段都没渲染出来的假绿）。
    expect(find.text(t.video_setting_qb_url), findsOneWidget,
        reason: '本平台唯一可用后端是外接 qBittorrent，其连接字段必须在');
    expect(find.text(t.download_test_connection), findsOneWidget);

    // ④ 交代原因，别让用户以为选项丢了。
    expect(find.text(t.download_backend_unsupported_note), findsOneWidget);
  });

  testWidgets('有内置引擎平台：同一份显式 embedded 配置仍给出选择器与下载目录（不误伤）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(embeddedSupported: true));
    await tester.pumpAndSettle();

    expect(find.byType(FushiSegmentedStrip<String>), findsOneWidget);
    expect(find.text(t.video_setting_torrent_backend_embedded), findsOneWidget);
    expect(find.text(t.download_save_root_title), findsOneWidget,
        reason: '内置引擎真会读这个目录，必须保留');
    expect(find.text(t.download_backend_unsupported_note), findsNothing);
    expect(find.text(t.video_setting_qb_url), findsNothing,
        reason: '内置引擎分支不渲染 qb 连接字段');
  });
}

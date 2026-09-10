import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

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
}

/// 存量配置：用户在某个版本里**显式**选过内置引擎（不是 auto），
/// 这正是 `resolveBackend` 过去原样放行、酿成死设置的那一类。
const QbConnectionConfig _explicitEmbedded = QbConnectionConfig(
  backend: QbConnectionConfig.backendEmbedded,
);

Widget _harness(TorrentSettingsScope scope, {bool embeddedSupported = true}) {
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
      home: Scaffold(
        body: SizedBox(
          width: 900,
          child: SingleChildScrollView(
            child: TorrentSettingsSection(
              embeddedSupportedOverride: embeddedSupported,
              scope: scope,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final TorrentSettingsScope scope in TorrentSettingsScope.values) {
    testWidgets('${scope.name} disposal does not initialize hidden fields', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_harness(scope));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Explicitly unmount while the test can observe lifecycle errors. The
      // common scope has never built either controller-backed text field.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('common controls remain visible without advanced forms', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness(TorrentSettingsScope.common));
    await tester.pumpAndSettle();
    expect(find.text(t.download_save_root_title), findsOneWidget);
    expect(find.text(t.video_setting_torrent_download_limit), findsOneWidget);
    expect(find.text(t.video_setting_torrent_memory_limit), findsNothing);
    expect(find.text(t.download_tracker_url), findsNothing);
    expect(
      tester
          .widgetList<SettingsSearchTarget>(find.byType(SettingsSearchTarget))
          .map((SettingsSearchTarget target) => target.id),
      contains('downloads.save_root'),
    );
  });

  testWidgets(
    'advanced page exposes real field search targets without common duplicates',
    (WidgetTester tester) async {
      await tester.pumpWidget(_harness(TorrentSettingsScope.advanced));
      await tester.pumpAndSettle();
      expect(find.text(t.video_setting_torrent_memory_limit), findsOneWidget);
      expect(find.text(t.video_setting_qb_category), findsOneWidget);
      expect(find.text(t.download_save_root_title), findsNothing);
      expect(find.byType(FushiSegmentedStrip<String>), findsNothing);
      expect(
        tester
            .widgetList<SettingsSearchTarget>(find.byType(SettingsSearchTarget))
            .map((SettingsSearchTarget target) => target.id),
        contains('downloads.video_setting_torrent_memory_limit'),
      );
    },
  );

  testWidgets('qB connection subpage uses the existing platform fallback', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _harness(TorrentSettingsScope.connection, embeddedSupported: false),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.video_setting_qb_url), findsOneWidget);
    expect(find.text(t.download_test_connection), findsOneWidget);
    expect(find.text(t.download_tracker_url), findsNothing);
    expect(find.text(t.download_save_root_title), findsNothing);
  });
}

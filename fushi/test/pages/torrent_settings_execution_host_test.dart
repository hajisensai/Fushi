import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// 反馈 sOLqsIv6R9：「下载执行设备」是「交给互联电脑办」唯一的控件，AI 设置页的
/// 链接落在这一行上。没配对任何 host 时这一行也得在（说明 + 去配对），否则链接
/// 落空、定位挂点一直悬着。
class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'jp.fushi.test',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  QbConnectionConfig? get qbConnectionConfig => null;
}

Widget _harness() {
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
  final AppModel appModel = _TestAppModel()..themeNotifier = themeNotifier;
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
      home: const Scaffold(
        body: SingleChildScrollView(
          child: TorrentSettingsSection(scope: TorrentSettingsScope.common),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => SettingsSearchReveal.pendingItemId = null);

  testWidgets('unpaired: the execution-host row still renders with a hint', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('downloads-execution-host-unpaired')),
      findsOneWidget,
    );
    expect(find.text(t.download_execution_host_title), findsOneWidget);
    expect(find.text(t.download_execution_host_unpaired), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('downloads-execution-host')),
      findsNothing,
      reason: '没配对 host 时不给只有「本机」一个选项的下拉',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the AI page link lands on this row (reveal is consumed)', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SettingsSearchReveal.pendingItemId = kDownloadExecutionHostSettingsItemId;
    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(SettingsSearchReveal.pendingItemId, isNull, reason: '挂点被这一行消费');
    expect(
      find.ancestor(
        of: find.byKey(
          const ValueKey<String>('downloads-execution-host-unpaired'),
        ),
        matching: find.byType(SettingsRevealTarget),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

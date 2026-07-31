import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/download_network_proxy.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/pages/implementations/torrent_settings_section.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

// BUG-1084 / BUG-1278 守卫：设置详情卡片按用户拍板填满整宽（无 960 面板限宽），
// 但下载设置表单自身应在 4K pane 内按 560px 居中，避免说明与按钮贴住详情页左端、
// Switch 被推到最右端。输入框在表单内继续限制为 480px；窄 pane 下两层限制均退化
// 为填满可用宽度。
class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');

  @override
  PackageInfo get packageInfo => PackageInfo(
        appName: 'Hibiki',
        packageName: 'jp.hibiki.test',
        version: '1.0.0',
        buildNumber: '1',
      );

  // prefs 未初始化的裸 AppModel：把本组件 build 路径读到的两个 pref-backed
  // getter 换成常量默认（qb 未配置 → 桌面解析成内置引擎，字段最全）。
  @override
  QbConnectionConfig? get qbConnectionConfig => null;

  @override
  DownloadNetworkProxyConfig get downloadNetworkProxyConfig =>
      const DownloadNetworkProxyConfig();
}

Widget _harness({required double paneWidth}) {
  final HibikiDatabase db = HibikiDatabase.forTesting(
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
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: paneWidth,
            child: SingleChildScrollView(
              child: TorrentSettingsSection(),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'wide pane: content centers at 560 and fields cap at 480 '
      '(BUG-1084, BUG-1278)', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double paneWidth = 2400;
    await tester.pumpWidget(_harness(paneWidth: paneWidth));
    await tester.pumpAndSettle();

    final Finder content = find.byKey(
      const ValueKey<String>('torrent-settings-content'),
    );
    expect(content, findsOneWidget);
    expect(
      tester.getSize(content).width,
      moreOrLessEquals(kTorrentSettingsContentMaxWidth, epsilon: 1.0),
    );
    expect(
      tester.getCenter(content).dx,
      moreOrLessEquals(paneWidth / 2, epsilon: 1.0),
      reason: 'the whole settings form must be centered in the wide pane',
    );

    final double contentLeft = tester.getTopLeft(content).dx;
    // HibikiSegmentedStrip 是泛型控件，实例的 runtimeType 是
    // HibikiSegmentedStrip<DownloadNetworkProxyMode> / <String> / <int>；
    // find.byType 走 runtimeType 精确相等，对泛型永远 0 命中。按 Dart 的协变
    // 子类型关系用 `is HibikiSegmentedStrip<Object>` 判定才能覆盖全部实参。
    final Finder strips = find.byWidgetPredicate(
      (Widget widget) => widget is HibikiSegmentedStrip<Object>,
      description: 'HibikiSegmentedStrip<*>',
    );
    expect(strips, findsWidgets);
    expect(
      tester.getTopLeft(strips.first).dx,
      moreOrLessEquals(contentLeft, epsilon: 1.0),
      reason: 'segmented controls align with the centered form, not the pane',
    );

    final Finder switches = find.byType(AdaptiveSettingsSwitchRow);
    expect(switches, findsWidgets);
    for (final Element element in switches.evaluate()) {
      expect(
        tester.getSize(find.byWidget(element.widget)).width,
        lessThanOrEqualTo(kTorrentSettingsContentMaxWidth + 1),
        reason: 'switch labels and toggles stay together inside the form',
      );
    }

    final Finder fields = find.byType(TextFormField);
    expect(fields, findsWidgets,
        reason: 'embedded backend must render its input fields');
    for (final Element element in fields.evaluate()) {
      final Size size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, lessThanOrEqualTo(481),
          reason: 'a field must never stretch across the full-width pane');
      expect(tester.getTopLeft(find.byWidget(element.widget)).dx,
          moreOrLessEquals(contentLeft, epsilon: 1.0),
          reason: 'capped fields align with the centered form');
    }
  });

  testWidgets('narrow pane: input fields still fill the available width',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double paneWidth = 400;
    await tester.pumpWidget(_harness(paneWidth: paneWidth));
    await tester.pumpAndSettle();

    final Finder content = find.byKey(
      const ValueKey<String>('torrent-settings-content'),
    );
    expect(tester.getSize(content).width,
        moreOrLessEquals(paneWidth, epsilon: 1.0));
    expect(tester.getTopLeft(content).dx, moreOrLessEquals(0, epsilon: 1.0));

    final Finder fields = find.byType(TextFormField);
    expect(fields, findsWidgets);
    for (final Element element in fields.evaluate()) {
      final Size size = tester.getSize(find.byWidget(element.widget));
      expect(size.width, moreOrLessEquals(paneWidth, epsilon: 1.0),
          reason: 'below the cap a field keeps filling the pane');
    }
  });
}

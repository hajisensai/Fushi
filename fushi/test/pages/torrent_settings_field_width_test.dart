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

// BUG-1858 守卫：设置页里**只有一条**输入框宽度规则——与普通设置行共用同一条
// 16px 左右基线，正文吃满剩下的宽度。
//
// 此前同一个设置分区里并存三种宽度：下载设置的输入框自己缩到 480，整段又收进
// 560（BUG-1084/BUG-1278 的居中限宽），而其余分类的设置行（`SettingsTextItem`）
// 照旧撑满 pane。用户 2026-08-25 实报「这里和别的输入框宽度不一样」并拍板统一成
// 撑满，两层限宽随之删除。本守卫钉住：内容容器与每一个输入框都吃满 pane 宽减去
// 两边各 16px，且左边缘落在同一条基线上。
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
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: paneWidth,
            child: SingleChildScrollView(
              child: const TorrentSettingsSection(),
            ),
          ),
        ),
      ),
    ),
  );
}

const double _kRowInset = 16;

void main() {
  /// 一个 pane 宽度下的完整不变量：内容容器吃满 `paneWidth - 2 * 16`、左边缘落在
  /// 16px 基线上，每个输入框与容器同宽同左边缘，开关行不越过容器右边界。
  Future<void> expectSingleBaseline(
    WidgetTester tester, {
    required double paneWidth,
  }) async {
    final double expectedWidth = paneWidth - 2 * _kRowInset;

    final Finder content = find.byKey(
      const ValueKey<String>('torrent-settings-content'),
    );
    expect(content, findsOneWidget);
    expect(
      tester.getSize(content).width,
      moreOrLessEquals(expectedWidth, epsilon: 1.0),
      reason: 'BUG-1858: 正文吃满内容区，不再收进 560',
    );
    final double contentLeft = tester.getTopLeft(content).dx;
    expect(
      contentLeft,
      moreOrLessEquals(_kRowInset, epsilon: 1.0),
      reason: 'BUG-1278: 左边缘与普通设置行同一条 16px 基线',
    );

    // FushiSegmentedStrip 是泛型控件，实例的 runtimeType 是
    // FushiSegmentedStrip<DownloadNetworkProxyMode> / <String> / <int>；
    // find.byType 走 runtimeType 精确相等，对泛型永远 0 命中。按 Dart 的协变
    // 子类型关系用 `is FushiSegmentedStrip<Object>` 判定才能覆盖全部实参。
    final Finder strips = find.byWidgetPredicate(
      (Widget widget) => widget is FushiSegmentedStrip<Object>,
      description: 'FushiSegmentedStrip<*>',
    );
    expect(strips, findsWidgets);
    expect(
      tester.getTopLeft(strips.first).dx,
      moreOrLessEquals(contentLeft, epsilon: 1.0),
      reason: '分段控件与正文同一条左基线',
    );

    final Finder switches = find.byType(AdaptiveSettingsSwitchRow);
    expect(switches, findsWidgets);
    for (final Element element in switches.evaluate()) {
      expect(
        tester.getSize(find.byWidget(element.widget)).width,
        lessThanOrEqualTo(expectedWidth + 1),
        reason: '开关行不越过正文右边界',
      );
    }

    final Finder fields = find.byType(TextFormField);
    expect(fields, findsWidgets,
        reason: 'embedded backend must render its input fields');
    for (final Element element in fields.evaluate()) {
      expect(
        tester.getSize(find.byWidget(element.widget)).width,
        moreOrLessEquals(expectedWidth, epsilon: 1.0),
        reason: 'BUG-1858: 输入框与开关 / 分段按钮共用同一条右边界',
      );
      expect(
        tester.getTopLeft(find.byWidget(element.widget)).dx,
        moreOrLessEquals(contentLeft, epsilon: 1.0),
        reason: '输入框与正文同一条左基线',
      );
    }
    expect(tester.takeException(), isNull);
  }

  testWidgets('wide pane: one baseline, fields fill the content area',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2600, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double paneWidth = 2400;
    await tester.pumpWidget(_harness(paneWidth: paneWidth));
    await tester.pumpAndSettle();

    await expectSingleBaseline(tester, paneWidth: paneWidth);
  });

  testWidgets('narrow pane: same rule, no extra cap kicks in',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const double paneWidth = 400;
    await tester.pumpWidget(_harness(paneWidth: paneWidth));
    await tester.pumpAndSettle();

    await expectSingleBaseline(tester, paneWidth: paneWidth);
  });
}

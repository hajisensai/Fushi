// 宽屏设置主从布局的「窗格接缝」行为守卫（BUG-2443）。
//
// 接缝指导航窗格与详情窗格之间那条 1px 分隔线。线本身没问题，问题是它两侧读不出
// 「两个窗格」：
//   * 导航窗格底色曾取 `surfaces.group`（surfaceContainerLow），与详情窗格的
//     `surfaces.page`（surface）在浅色主题下只差约 2%（#F0F4F8 vs #F5FAFD），
//     线两侧几乎同色，于是线读成一条凭空的竖线；
//   * 详情正文左内边距曾是 `page + gap`(28)、右边 `page`(20)，线左边是导航窗格的
//     20、右边是详情的 28，一条线两侧呼吸不一样宽。
//
// 这里钉住修复后的两条不变式：窗格底色取更高一档的 tonal（`surfaces.card`，面差
// 约 4.3%），详情正文左右内边距相等。源码层面的对应守卫在
// settings_redesign_static_test.dart。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_home_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

class _SeamTestAppModel extends AppModel {
  _SeamTestAppModel() : super(testPlatformServices());

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
  bool get reverseReaderBottomBar => false;
}

Future<AppModel> _buildAppModel() async {
  final FushiDatabase db = FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'hibiki_settings_seam_',
  );
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('auto'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('light'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  addTearDown(themeNotifier.dispose);

  return _SeamTestAppModel()
    ..themeNotifier = themeNotifier
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

Widget _wideSettings(AppModel appModel, ThemeNotifier themeNotifier) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.windows,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: const Scaffold(body: SettingsHomePage(embedded: true)),
      ),
    ),
  );
}

void main() {
  testWidgets('wide nav pane paints a tonal surface distinct from the detail '
      'pane, and the detail body is symmetric, so the divider reads as a pane '
      'edge sitting centred in the seam', (WidgetTester tester) async {
    final AppModel appModel = await _buildAppModel();
    final ThemeNotifier themeNotifier = appModel.themeNotifier;

    tester.view.devicePixelRatio = 1.0;
    // 宽屏主从分支的门是 maxWidth >= 720。
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(_wideSettings(appModel, themeNotifier));
    await tester.pump();

    final BuildContext context = tester.element(
      find.byType(SettingsHomePage).first,
    );
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    // 导航窗格是 MaterialSupportingPaneLayout 的 supporting，被一个上色 Container 包着。
    final Iterable<Container> panes = tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (Container container) => container.color == tokens.surfaces.card,
        );
    expect(panes, isNotEmpty, reason: '宽屏导航窗格必须画在 surfaces.card 这一档 tonal 面上');

    // 与详情窗格所在的页面底色确实不同档——同档等于没有分层，分隔线两侧就会同色。
    expect(tokens.surfaces.card, isNot(tokens.surfaces.page));
    expect(tokens.surfaces.card, isNot(tokens.surfaces.group));

    // 详情正文左右内边距相等：左边曾多出一个 gap（28 对 20），正文在自己的窗格里
    // 左右不等宽，而且线左是导航窗格的 20、线右是详情的 28，一条分隔线两侧呼吸
    // 不一样宽，线看着偏向左侧。
    final EdgeInsets insets = MaterialSettingsRenderer.detailHorizontalInsets(
      tokens,
    );
    expect(insets.left, insets.right, reason: '详情正文左右内边距必须相等，否则分隔线不居中于窗格之间的缝里');
    expect(insets.left, tokens.spacing.page);
  });
}

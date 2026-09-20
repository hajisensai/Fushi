// 宽屏设置主从布局的「窗格接缝」行为守卫。
//
// 历史：BUG-2443 曾把导航窗格提到 `surfaces.card` tonal 底、保留窗格之间那条 1px
// 分隔线，让线两侧读出「两个窗格」。用户实机反馈（2026-09-20 截图）那条线本身就
// 是多余的：左边一块圆角色块、右边一张分组卡、中间再夹一条竖线，接缝反而最扎眼。
// 现在两个窗格都直接落在页面底上，中间不画线、导航窗格不铺 tonal 底，分层交给
// 导航列表的 pill 选中态与右侧分组卡自己表达。
//
// 这里钉住三条不变式：宽屏主从不画 VerticalDivider；导航窗格不再被
// `surfaces.card` 色的 Container 包着；详情正文左右内边距相等（BUG-2443 的另
// 一半修复，与线无关，保留）。源码层面的对应守卫在
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
  testWidgets(
    'wide list-detail draws no divider and no tonal nav pane; the detail body '
    'stays symmetric',
    (WidgetTester tester) async {
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

      // 确实进了宽屏主从分支。
      expect(find.byType(MaterialSupportingPaneLayout), findsOneWidget);

      // 窗格之间不画分隔线：用户实报那条竖线多余。
      expect(
        find.descendant(
          of: find.byType(MaterialSupportingPaneLayout),
          matching: find.byType(VerticalDivider),
        ),
        findsNothing,
        reason: '宽屏设置主从的两个窗格之间不能再画 1px 分隔线',
      );

      final BuildContext context = tester.element(
        find.byType(SettingsHomePage).first,
      );
      final FushiDesignTokens tokens = FushiDesignTokens.of(context);

      // 导航窗格不再单独铺 tonal 底（曾是一个 surfaces.card 色的 Container）。
      final Iterable<Container> tonalPanes = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(MaterialSupportingPaneLayout),
              matching: find.byType(Container),
            ),
          )
          .where(
            (Container container) => container.color == tokens.surfaces.card,
          );
      expect(
        tonalPanes,
        isEmpty,
        reason: '宽屏导航窗格不能再被 surfaces.card 色的 Container 包成一块色块',
      );

      // 详情正文左右内边距相等：左边曾多出一个 gap（28 对 20），正文在自己的窗格
      // 里左右不等宽。
      final EdgeInsets insets = MaterialSettingsRenderer.detailHorizontalInsets(
        tokens,
      );
      expect(insets.left, insets.right, reason: '详情正文左右内边距必须相等');
      expect(insets.left, tokens.spacing.page);
    },
  );
}

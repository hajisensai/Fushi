// 宽屏设置主从布局的「窗格接缝」行为守卫。
//
// 历史：BUG-2443 曾把导航窗格整块铺成 `surfaces.card` tonal 底、保留窗格之间那条
// 1px 分隔线，让线两侧读出「两个窗格」。用户实机反馈（2026-09-20 两张截图）：线本
// 身多余，但左侧也要像右侧分组卡一样**有一张卡包住**——于是导航整块（搜索框 +
// 分类列表）装进一张与右侧分组卡同款的 FushiCard，窗格之间不画线，边界由卡片
// 自己表达。
//
// MD3 Expressive 重设计（2026-10）把左栏改成 Android 16 平板设置的形态：胶囊
// 搜索栏 + 导航抽屉式分类列表直接坐在页面底上，不再包卡。
//
// 这里钉住三条不变式：宽屏主从不画 VerticalDivider；搜索框与分类列表同在定宽
// 的左导航窗格里、上下相接且不贴边；详情正文左右内边距相等
// （BUG-2443 的另一半修复，与线无关，保留）。源码层面的对应守卫在
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
    'wide list-detail draws no divider; search and category list share the nav '
    'pane; the detail body stays symmetric',
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

      // MD3 Expressive 重设计（Android 16 平板「设置」）：导航窗格不再装进
      // FushiCard，而是胶囊搜索栏 + 导航抽屉式分类列表直接坐在页面底上，窗格
      // 定宽 navPaneWidth。原守卫的意图保持不变：宽屏左栏是一个完整的导航块
      // （搜索框与分类列表同在左窗格、上下相接），且不贴边。
      final Finder searchField = find.byType(TextField);
      expect(searchField, findsOneWidget);
      final Finder navList = find.byType(Md3SettingsNavList);
      expect(navList, findsOneWidget, reason: '宽屏左栏必须是 MD3 导航抽屉式分类列表');
      final Rect searchRect = tester.getRect(searchField);
      final Rect listRect = tester.getRect(navList);
      // 搜索框与分类列表同在左侧导航窗格里（不越过窗格宽度）。
      expect(
        searchRect.right,
        lessThanOrEqualTo(MaterialSettingsRenderer.navPaneWidth),
        reason: '搜索框必须在左侧导航窗格里',
      );
      expect(
        listRect.right,
        lessThanOrEqualTo(MaterialSettingsRenderer.navPaneWidth),
        reason: '分类列表必须与搜索框在同一个导航窗格里',
      );
      expect(
        listRect.top,
        greaterThanOrEqualTo(searchRect.bottom),
        reason: '分类列表接在搜索框下方，同属一个导航块',
      );
      // 导航块不贴边：外面有留白，否则又是一块贴边色块。
      expect(searchRect.left, greaterThan(0));
      expect(searchRect.top, greaterThan(0));

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

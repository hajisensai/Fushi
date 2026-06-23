import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/pages/implementations/anki_settings_page.dart';
import 'package:hibiki/src/pages/implementations/profile_management_page.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import '../helpers/test_platform_services.dart';

/// 「制卡」与「配置方案」两个设置 destination 已经扁平化（消掉子级菜单）：
/// 原本各藏在一层独立路由子页里的 Anki 正文 / Profile 管理正文，现在直接通过
/// [SettingsDestination.body] 平铺进父详情页。本测试守护三件事：
/// 1. schema 结构：两个 destination 都有 body、且不再含任何子页跳转项；
/// 2. 渲染后正文确实内联（AnkiSettingsBody / ProfileManagementBody 现身）、且
///    详情页里不再有任何子页跳转行；
/// 3. 平铺进来的「自动添加书名到标签」开关仍真生效（写穿 prefs）。
/// 4. TODO-135（方案A）：默认标签区三个开关——「hibiki」「来源分类」「自动添加
///    书名」——并入同一个**无条件显示**的区块。未配置 Anki 时它们也都露出（方案A
///    取舍），且「自动添加书名」仍可翻转写穿（绝不退化）。这是方案A的行为守卫：
///    撤掉「把两 tag 开关移出 isConfigured 门控」的修复，未配置态就只剩一个开关，
///    本测试转红。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase db;
  late AppModel appModel;
  late ThemeNotifier themeNotifier;
  late Directory tmpDir;
  ReaderSettings? prevReaderSettings;

  // AppModel 构造里会 new DefaultCacheManager()，它经 path_provider 取目录；host
  // 上无插件实现会抛 MissingPluginException（异步，落在测试体之后→误判失败）。
  // mock 成临时目录即可让其静默成功。
  late Directory ppDir;
  setUpAll(() {
    // AnkiSettingsBody 经 ankiViewModelProvider → BaseAnkiRepository 调
    // SharedPreferences.getInstance()；host 无插件实现会抛 MissingPluginException。
    // mock 空初值让 Anki body 的初始 load 确定性成功，不依赖异步异常逃逸时序。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ppDir = Directory.systemTemp.createTempSync('hibiki_flatten_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => ppDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (ppDir.existsSync()) ppDir.deleteSync(recursive: true);
  });

  Future<void> wire() async {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prevReaderSettings = ReaderHibikiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
    themeNotifier = ThemeNotifier(db, () => const TextTheme())
      ..loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
        'app_theme_key': PrefCodec.encode('system-theme'),
        'brightness_mode': PrefCodec.encode('system'),
        'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
      });
    tmpDir = Directory.systemTemp.createTempSync('hibiki_flatten_test_');
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    appModel = AppModel(testPlatformServices())
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      ..populateLanguages()
      ..populateLocales();
  }

  setUp(wire);

  tearDown(() async {
    ReaderHibikiSource.readerSettings = prevReaderSettings;
    themeNotifier.dispose();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
    await db.close();
  });

  /// 在一棵真实 MaterialApp 子树里渲染 [id] 这个 destination 的详情页，并把抓到的
  /// schema destination 列表回填到 [captured]。
  Future<SettingsDestination> pumpDestination(
    WidgetTester tester,
    SettingsDestinationId id,
    List<SettingsDestination> captured,
  ) async {
    late SettingsDestination target;
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            final SettingsContext sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            );
            final List<SettingsDestination> all = buildSettingsSchema(sctx);
            captured
              ..clear()
              ..addAll(all);
            target = all.firstWhere((SettingsDestination d) => d.id == id);
            return const MaterialSettingsRenderer().buildDetailPage(
              settingsContext: sctx,
              destination: target,
            );
          },
        ),
      ),
    ));
    // 让 anki / profile viewmodel 的异步初始 load 完成。
    await tester.pump(const Duration(milliseconds: 250));
    return target;
  }

  testWidgets(
      'card creation destination inlines Anki body, no sub-page nav, toggle persists',
      (WidgetTester tester) async {
    final List<SettingsDestination> all = <SettingsDestination>[];
    final SettingsDestination cardCreation = await pumpDestination(
      tester,
      SettingsDestinationId.cardCreation,
      all,
    );

    // ① schema 结构：有 body、无任何子页跳转项。
    expect(cardCreation.body, isNotNull,
        reason: '制卡 destination 应通过 body 平铺 Anki 正文');
    final List<SettingsItem> cardItems =
        cardCreation.sections.expand((SettingsSection s) => s.items).toList();
    expect(cardItems.whereType<SettingsNavigationItem>(), isEmpty,
        reason: '制卡 destination 不应再有「Anki 设置」子页跳转项');

    // ② 渲染后 Anki 正文内联现身、详情页无任何子页跳转行。
    expect(find.byType(AnkiSettingsBody), findsOneWidget);
    expect(find.byType(AdaptiveSettingsNavigationRow), findsNothing,
        reason: '平铺后不应再出现指向 Anki 子页的跳转行');

    // ③ TODO-135 方案A：默认标签区三个开关（hibiki / 来源分类 / 自动添加书名）都
    //    并入一个无条件显示的区块。未配置 Anki 时它们也都露出。TODO-757 又在该区追加
    //    「压缩制卡媒体」开关（同样无条件显示）——故页面里恰有四个 SwitchRow。
    expect(find.byType(AdaptiveSettingsSwitchRow), findsNWidgets(4),
        reason: 'TODO-135 方案A 三开关（hibiki / 来源分类 / 自动添加书名）'
            '+ TODO-757「压缩制卡媒体」开关，未配置 Anki 时都应显示');
    expect(
        find.widgetWithText(AdaptiveSettingsSwitchRow, 'Compress card media'),
        findsOneWidget,
        reason: 'TODO-757「压缩制卡媒体」开关应无条件显示');
    expect(find.widgetWithText(AdaptiveSettingsSwitchRow, 'Add "hibiki" tag'),
        findsOneWidget,
        reason: 'hibiki 标签开关应无条件显示');
    expect(
        find.widgetWithText(
            AdaptiveSettingsSwitchRow, 'Add source category tag'),
        findsOneWidget,
        reason: '来源分类开关应无条件显示');
    final Finder autoAddRow = find.widgetWithText(
        AdaptiveSettingsSwitchRow, 'Auto-add book title to tags');
    expect(autoAddRow, findsOneWidget,
        reason: '「自动添加书名」开关必须仍无条件可用（方案B会破坏，绝不退化）');

    // ④「自动添加书名」开关仍真生效（写穿 prefs）——必须保留的用户目标。
    final bool before = appModel.autoAddBookNameToTags;
    // 开关在 Anki 正文底部，初始在视口外——先滚动到它再点，否则 tap 落空。
    final Finder autoAddSwitch =
        find.descendant(of: autoAddRow, matching: find.byType(Switch));
    await tester.ensureVisible(autoAddSwitch);
    await tester.pump();
    await tester.tap(autoAddSwitch);
    await tester.pump();
    expect(appModel.autoAddBookNameToTags, isNot(before),
        reason: '点开关应翻转 autoAddBookNameToTags 并写穿 prefs');
  });

  testWidgets(
      'profiles destination inlines management body, keeps picker, no sub-page nav',
      (WidgetTester tester) async {
    final List<SettingsDestination> all = <SettingsDestination>[];
    final SettingsDestination profiles = await pumpDestination(
      tester,
      SettingsDestinationId.profiles,
      all,
    );

    // ① schema 结构：有 body、保留「配置」picker（custom item）、无子页跳转项。
    expect(profiles.body, isNotNull,
        reason: '配置方案 destination 应通过 body 平铺 Profile 管理正文');
    final List<SettingsItem> profileItems =
        profiles.sections.expand((SettingsSection s) => s.items).toList();
    expect(profileItems.whereType<SettingsNavigationItem>(), isEmpty,
        reason: '配置方案 destination 不应再有「配置管理」子页跳转项');
    expect(profileItems.whereType<SettingsCustomItem>(), isNotEmpty,
        reason: '应保留顶部「配置」快速切换 picker');

    // ② 渲染后管理正文内联现身、详情页无任何子页跳转行。
    expect(find.byType(ProfileManagementBody), findsOneWidget);
    expect(find.byType(AdaptiveSettingsNavigationRow), findsNothing,
        reason: '平铺后不应再出现指向「配置管理」子页的跳转行');
  });
}

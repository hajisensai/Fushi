import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/pages/implementations/anki_settings_page.dart';
import 'package:fushi/src/pages/implementations/profile_management_page.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

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

  late FushiDatabase db;
  late AppModel appModel;
  late PlatformServices platformServices;
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
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prevReaderSettings = ReaderFushiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderFushiSource.readerSettings = readerSettings;
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
    platformServices = testPlatformServices();
    appModel = AppModel(platformServices)
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
        prefsRepo: prefsRepo,
        databaseDirectory: tmpDir,
      )
      ..populateLanguages()
      ..populateLocales();
  }

  setUp(wire);

  tearDown(() async {
    ReaderFushiSource.readerSettings = prevReaderSettings;
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
    List<SettingsDestination> captured, {
    String? panelId,
  }) async {
    late SettingsDestination target;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
          platformServicesProvider.overrideWithValue(platformServices),
        ],
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            platform: TargetPlatform.android,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF386A58),
            ),
            extensions: <ThemeExtension<dynamic>>[
              FushiDesignSystemTheme(themeNotifier.designSystemTheme),
            ],
          ),
          home: Consumer(
            builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
              final SettingsContext sctx = SettingsContext(
                context: ctx,
                appModel: ref.read(appProvider),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              final List<SettingsDestination> all = buildSettingsSchema(sctx);
              captured
                ..clear()
                ..addAll(all);
              target = all.firstWhere((SettingsDestination d) => d.id == id);
              if (panelId != null) {
                target = target.sections
                    .expand((section) => section.items)
                    .whereType<SettingsNavigationItem>()
                    .firstWhere((item) => item.id == panelId)
                    .child!();
              }
              return const MaterialSettingsRenderer().buildDetailPage(
                settingsContext: sctx,
                destination: target,
              );
            },
          ),
        ),
      ),
    );
    // 让 anki / profile viewmodel 的异步初始 load 完成。
    await tester.pump(const Duration(milliseconds: 250));
    return target;
  }

  testWidgets('card creation keeps common settings inline and persists tags', (
    WidgetTester tester,
  ) async {
    final List<SettingsDestination> all = <SettingsDestination>[];
    final SettingsDestination cardCreation = await pumpDestination(
      tester,
      SettingsDestinationId.cardCreation,
      all,
    );

    final List<SettingsItem> cardItems = cardCreation.sections
        .expand((SettingsSection section) => section.items)
        .toList();
    expect(cardCreation.body, isNotNull);
    expect(cardCreation.bodyBeforeSections, isTrue);
    expect(cardItems.whereType<SettingsCustomItem>(), isEmpty);
    expect(
      cardItems.whereType<SettingsNavigationItem>().map((item) => item.id),
      <String>[
        'card_creation.connection.open',
        'card_creation.fields.open',
        'card_creation.lapis.open',
        'card_creation.media.open',
        'card_creation.maintenance.open',
      ],
    );
    expect(find.byType(AnkiSettingsBody), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(AnkiSettingsBody),
        matching: find.byType(AdaptiveSettingsSection),
      ),
      findsNothing,
      reason: '常用正文自带设置分区，不应再套额外卡片',
    );
    expect(
      tester.getBottomLeft(find.byType(AnkiSettingsBody)).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byType(AdaptiveSettingsNavigationRow).first).dy,
      ),
      reason: '常用正文应在复杂配置子页入口之前',
    );
    expect(
      find.byType(AdaptiveSettingsSwitchRow),
      findsNWidgets(3),
      reason: '常用标签开关直接可见，维护开关属于独立子页',
    );
    expect(find.byType(AdaptiveSettingsSliderRow), findsNothing);
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Add "fushi" tag'),
      findsOneWidget,
      reason: 'hibiki 标签开关应无条件显示',
    );
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Add source category tag'),
      findsOneWidget,
      reason: '来源分类开关应无条件显示',
    );
    final Finder autoAddRow = find.widgetWithText(
      AdaptiveSettingsSwitchRow,
      'Auto-add book title to tags',
    );
    expect(
      autoAddRow,
      findsOneWidget,
      reason: '「自动添加书名」开关必须仍无条件可用（方案B会破坏，绝不退化）',
    );
    // 「制卡到已配对设备」已移出本页，改挂 Hibiki 互联 →「交给已配对设备」（它的前置
    // 条件、目标设备、失效条件全由互联决定，互联关掉时留在这里就是纯死开关）。归属由
    // test/sync/sync_settings_visibility_test.dart 咬住；这里只守「不得回流」。
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Mine to paired device'),
      findsNothing,
      reason: '「制卡到已配对设备」不应再出现在 Anki 正文',
    );

    // ④「自动添加书名」开关仍真生效（写穿 prefs）——必须保留的用户目标。
    final bool before = appModel.autoAddBookNameToTags;
    // 开关在 Anki 正文底部，初始在视口外——先滚动到它再点，否则 tap 落空。
    final Finder autoAddSwitch = find.descendant(
      of: autoAddRow,
      matching: find.byType(Switch),
    );
    await tester.ensureVisible(autoAddSwitch);
    await tester.pump();
    await tester.tap(autoAddSwitch);
    await tester.pump();
    expect(
      appModel.autoAddBookNameToTags,
      isNot(before),
      reason: '点开关应翻转 autoAddBookNameToTags 并写穿 prefs',
    );
  });

  testWidgets('maintenance child preserves conservative defaults', (
    WidgetTester tester,
  ) async {
    await pumpDestination(
      tester,
      SettingsDestinationId.cardCreation,
      <SettingsDestination>[],
      panelId: 'card_creation.maintenance.open',
    );
    // 媒体去重的两个自动开关：**默认都关**（方案 A 的核心），且「自动直接删除」
    // 在自动处理关着时必须是**禁用**的——它是从属开关，打开自动处理不等于授权
    // 自动删。原实现的缺陷正是「自动路径绕过确认框」。
    final Finder dedupAutoRow = find.widgetWithText(
      AdaptiveSettingsSwitchRow,
      'Automatic processing',
    );
    expect(dedupAutoRow, findsOneWidget);
    expect(
      tester.widget<AdaptiveSettingsSwitchRow>(dedupAutoRow).value,
      isFalse,
      reason: '自动处理必须默认关',
    );
    final Finder dedupAutoDeleteRow = find.widgetWithText(
      AdaptiveSettingsSwitchRow,
      'Delete automatically without asking',
    );
    expect(dedupAutoDeleteRow, findsOneWidget);
    final AdaptiveSettingsSwitchRow autoDelete = tester
        .widget<AdaptiveSettingsSwitchRow>(dedupAutoDeleteRow);
    expect(autoDelete.value, isFalse, reason: '自动直接删除必须默认关');
    expect(autoDelete.onChanged, isNull, reason: '自动处理关着时「自动直接删除」必须禁用（从属开关）');
  });

  testWidgets('media child exposes quality controls without common settings', (
    WidgetTester tester,
  ) async {
    await pumpDestination(
      tester,
      SettingsDestinationId.cardCreation,
      <SettingsDestination>[],
      panelId: 'card_creation.media.open',
    );
    expect(find.byType(AdaptiveSettingsSliderRow), findsNWidgets(2));
    expect(find.byType(AdaptiveSettingsSwitchRow), findsNothing);
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
      expect(
        profiles.body,
        isNotNull,
        reason: '配置方案 destination 应通过 body 平铺 Profile 管理正文',
      );
      final List<SettingsItem> profileItems = profiles.sections
          .expand((SettingsSection s) => s.items)
          .toList();
      expect(
        profileItems.whereType<SettingsNavigationItem>(),
        isEmpty,
        reason: '配置方案 destination 不应再有「配置管理」子页跳转项',
      );
      expect(
        profileItems.whereType<SettingsCustomItem>(),
        isNotEmpty,
        reason: '应保留顶部「配置」快速切换 picker',
      );

      // ② 渲染后管理正文内联现身、详情页无任何子页跳转行。
      expect(find.byType(ProfileManagementBody), findsOneWidget);
      expect(
        find.byType(AdaptiveSettingsNavigationRow),
        findsNothing,
        reason: '平铺后不应再出现指向「配置管理」子页的跳转行',
      );
    },
  );
}

import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
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
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/pending_mining/pending_mines_page.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import '../srs/srs_test_support.dart';

import '../helpers/test_platform_services.dart';

/// 「制卡」与「配置方案」两个设置 destination 已经扁平化（消掉子级菜单）：
/// 原本各藏在一层独立路由子页里的 Anki 正文 / Profile 管理正文，现在直接通过
/// [SettingsDestination.body] 平铺进父详情页。本测试守护三件事：
/// 1. schema 结构：两个 destination 都有 body、且不再含任何子页跳转项；
/// 2. 渲染后正文确实内联（AnkiSettingsBody / ProfileManagementBody 现身）、且
///    详情页里不再有任何子页跳转行；
/// 3. 平铺进来的「自动添加书名到标签」开关仍真生效（写穿 prefs）。
/// 4. TODO-135（方案A）：默认标签区三个开关——「fushi」「来源分类」「自动添加
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
    ppDir = Directory.systemTemp.createTempSync('fushi_flatten_pp');
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
    tmpDir = Directory.systemTemp.createTempSync('fushi_flatten_test_');
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
    List<Override> extraOverrides = const <Override>[],
  }) async {
    late SettingsDestination target;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
          platformServicesProvider.overrideWithValue(platformServices),
          ...extraOverrides,
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
    // 「Anki」分组与各通用分组都用 custom rows 承载 AnkiSettingsBody 的行。
    expect(
      cardItems.whereType<SettingsCustomItem>().map((item) => item.id).toSet(),
      <String>{
        'card_creation.anki.route_rows',
        'card_creation.anki.rows',
        'card_creation.anki.configured_rows',
        'card_creation.anki.delivery_rows',
        'card_creation.content.rows',
        'card_creation.notices.rows',
        'card_creation.tags.rows',
      },
    );
    // 层级（2026-10-31）：当前目标的 Anki 配置紧跟正文（目标切换条），再是发送与
    // 待发、两种目标都生效的通用分组，媒体参数子页入口在最后。
    expect(cardCreation.sections.map((SettingsSection s) => s.id), <String>[
      'card_creation.anki',
      'card_creation.anki.delivery',
      'card_creation.content',
      'card_creation.notices',
      'card_creation.tags',
      'card_creation.configuration',
    ]);
    expect(
      cardCreation.sections.last.items.single.id,
      'card_creation.media.open',
    );
    expect(
      cardCreation.sections
          .firstWhere((SettingsSection s) => s.id == 'card_creation.anki')
          .items
          .whereType<SettingsNavigationItem>()
          .map((item) => item.id),
      <String>[
        'card_creation.connection.open',
        'card_creation.fields.open',
        'card_creation.lapis.open',
        'card_creation.maintenance.open',
      ],
    );
    final Finder mainBody = find.byWidgetPredicate(
      (Widget w) => w is AnkiSettingsBody && w.panel == null && w.row == null,
    );
    expect(mainBody, findsOneWidget);
    expect(
      find.ancestor(
        of: mainBody,
        matching: find.byType(AdaptiveSettingsSection),
      ),
      findsNothing,
      reason: '常用正文自带设置分区，不应再套额外卡片',
    );
    expect(
      tester.getBottomLeft(mainBody).dy,
      lessThanOrEqualTo(
        tester
            .getTopLeft(
              find.widgetWithText(
                AdaptiveSettingsNavigationRow,
                t.settings_anki_media,
              ),
            )
            .dy,
      ),
      reason: '常用正文应在复杂配置子页入口之前',
    );
    expect(
      find.byType(AdaptiveSettingsSwitchRow),
      findsNWidgets(12),
      reason:
          '常用开关（卡片内容 2 + 制卡提示 2 + 标签 5（含「标题嵌在分类下」））与 Anki 分组的批量制卡 + '
          '连不上时暂存 + 落地设备直接可见，维护开关属于独立子页',
    );
    for (final String notice in <String>[
      'Show mining confirmations',
      'Show duplicate-card notices',
    ]) {
      expect(
        find.widgetWithText(AdaptiveSettingsSwitchRow, notice),
        findsOneWidget,
        reason: '「制卡提示」开关应无条件显示（两种挖词目标都生效）',
      );
    }
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Batch mining'),
      findsOneWidget,
      reason: '批量制卡不受「Anki 已配置」门控：连不上 Anki 时正需要它',
    );
    expect(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        'Hold cards when Anki is unreachable',
      ),
      findsOneWidget,
      reason: '「连不上时暂存」同样不受「Anki 已配置」门控',
    );
    expect(find.byType(AdaptiveSettingsSliderRow), findsNothing);
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Add "fushi" tag'),
      findsOneWidget,
      reason: 'fushi 标签开关应无条件显示',
    );
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Add source category tag'),
      findsOneWidget,
      reason: '来源分类开关应无条件显示',
    );
    // 只改上面的计数不够：下次谁吞掉一个开关又加一个别的，计数照样是 4。相邻几个
    // 开关本来就是具名断言，这个（BUG-2396 起的「制卡所在字符数」）补齐第四个。
    expect(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        'Auto-add mining position to tags',
      ),
      findsOneWidget,
      reason: '「制卡所在字符数」开关应无条件显示',
    );
    final Finder autoAddRow = find.widgetWithText(
      AdaptiveSettingsSwitchRow,
      'Auto-add work title to tags',
    );
    expect(
      autoAddRow,
      findsOneWidget,
      reason: '「自动添加书名」开关必须仍无条件可用（方案B会破坏，绝不退化）',
    );
    // 「制卡到已配对设备」已移出本页，改挂 Fushi 互联 →「交给已配对设备」（它的前置
    // 条件、目标设备、失效条件全由互联决定，互联关掉时留在这里就是纯死开关）。归属由
    // test/sync/sync_settings_visibility_test.dart 咬住；这里只守「不得回流」。
    expect(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        'Mine to Fushi Interconnect server',
      ),
      findsNothing,
      reason: '「制卡到 Fushi 互联服务端」不应再出现在 Anki 正文',
    );

    // ④「自动添加书名」开关仍真生效（写穿 prefs）——必须保留的用户目标。
    final bool before = appModel.autoAddBookNameToTags;
    // 开关在 Anki 正文底部，初始在视口外——先滚动到它再点，否则 tap 落空。
    final Finder autoAddSwitch = find.descendant(
      of: autoAddRow,
      matching: find.byType(Switch),
    );
    // 居中滚入（与生产焦点滚动 FushiFocusScroll 同为 alignment 0.5）：设置页
    // 内容会滚到浮动页头底下（0a6d4be），贴视口顶边的行被页头盖住，tap 落空。
    await Scrollable.ensureVisible(
      tester.element(autoAddSwitch),
      alignment: 0.5,
    );
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
    // 图片质量 / 音频质量 + 句子音频头/尾 padding 两对滑块。
    expect(find.byType(AdaptiveSettingsSliderRow), findsNWidgets(4));
    // 开关只有「句子音频跟随播放倍速」（PR #1537，与音频质量同组）与「动图只播放
    // 一次」（反馈 ZxyIMK-C5V，与动图格式同组）；通用设置的开关一个都不该出现在这个子页。
    expect(find.byType(AdaptiveSettingsSwitchRow), findsNWidgets(2));
    expect(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        'Match sentence audio to playback speed',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(
        AdaptiveSettingsSwitchRow,
        'Play animated images once',
      ),
      findsOneWidget,
    );
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

  testWidgets('挖词目标 = Fushi 复习：Anki 专属项不渲染，换成复习牌组 / 笔记类型 + 字段映射', (
    WidgetTester tester,
  ) async {
    final (FushiDatabase srsDb, SrsDbStore store) = (await tester.runAsync(
      () => openSrsTestStore(),
    ))!;
    addTearDown(srsDb.close);
    await tester.runAsync(() async {
      await appModel.setModuleEnabled(ModuleId.srs, true);
      await appModel.setSrsMiningTarget(SrsMiningTarget.srs);
      // 一个非 Lapis 类型：选中后字段映射行逐字段出现。
      await store.importEvents(<SrsEvent>[
        SrsEntityEvent(
          SrsEntityRecord(
            id: 'nt-vocab',
            profileUid: kSrsTestProfile,
            kind: SrsEntityKind.noteType,
            payload: <String, Object?>{'ankiNum': 1, 'createdAt': 1},
          ),
        ),
      ]);
      await store
          .editFields(SrsEntityKind.noteType, 'nt-vocab', <String, Object?>{
            SrsFieldKeys.name: 'Vocab',
            SrsFieldKeys.fieldDef('fw'): const SrsFieldDef(
              id: 'fw',
              name: 'Word',
              ord: 0,
            ).toValue(),
            SrsFieldKeys.fieldDef('fm'): const SrsFieldDef(
              id: 'fm',
              name: 'Meaning',
              ord: 1,
            ).toValue(),
          });
      await appModel.setSrsMiningNoteTypeId('nt-vocab');
      await appModel.setSrsMiningFieldMapping('nt-vocab', 'fw', '{expression}');
    });

    await pumpDestination(
      tester,
      SettingsDestinationId.cardCreation,
      <SettingsDestination>[],
      extraOverrides: <Override>[
        srsStoreProvider.overrideWith((Ref ref) async => store),
      ],
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    // Anki 专属：批量制卡、跨设备中转、Anki 配置 / 刷新 / Lapis、AnkiConnect 入口都不在。
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, 'Batch mining'),
      findsNothing,
    );
    expect(find.byType(PendingMineLandingSwitchRow), findsNothing);
    expect(find.text(t.anki_fetch), findsNothing);
    expect(find.text(t.anki_create_lapis), findsNothing);
    expect(find.text('AnkiConnect'), findsNothing);
    expect(find.text(t.anki_not_configured), findsNothing);
    // 复习侧：牌组 / 笔记类型 + 非 Lapis 类型逐字段映射；共用的允许重复照旧。
    expect(
      find.byKey(const ValueKey<String>('srs-mining-deck')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('srs-mining-note-type')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('srs-mining-field-fw')),
      findsOneWidget,
    );
    expect(find.text('{expression}'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('srs-mining-field-fm')),
      findsOneWidget,
    );
    // 没映射过的「Meaning」按字段名预填到释义槽，而不是「未映射」。
    expect(find.text('{glossary-first}'), findsOneWidget);
    expect(find.text(t.anki_field_not_mapped), findsNothing);
    // 必填字段（第一个字段）都映射上了：不提示。
    expect(
      find.byKey(const ValueKey<String>('srs-mining-required-unmapped')),
      findsNothing,
    );
    expect(
      find.widgetWithText(AdaptiveSettingsSwitchRow, t.anki_allow_duplicates),
      findsOneWidget,
    );

    // 用户把第一个字段明确改成不填：显眼提示必填字段未映射。
    await tester.runAsync(
      () => appModel.setSrsMiningFieldMapping('nt-vocab', 'fw', ''),
    );
    await pumpDestination(
      tester,
      SettingsDestinationId.cardCreation,
      <SettingsDestination>[],
      extraOverrides: <Override>[
        srsStoreProvider.overrideWith((Ref ref) async => store),
      ],
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(find.text(t.anki_field_not_mapped), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('srs-mining-required-unmapped')),
      findsOneWidget,
    );
  });

  group('制卡页：挖词目标是一条分段条（与下载后端同形态）', () {
    final Finder strip = find.byKey(
      const ValueKey<String>('card-target-switch'),
    );
    SrsMiningTarget selected(WidgetTester tester) =>
        tester.widget<FushiSegmentedStrip<SrsMiningTarget>>(strip).selected;
    Finder segment(String label) =>
        find.descendant(of: strip, matching: find.text(label));

    testWidgets('当前发往 Anki（复习模块开）：分段条选 Anki，Anki 分组展开', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() async {
        await appModel.setModuleEnabled(ModuleId.srs, true);
        await appModel.setSrsMiningTarget(SrsMiningTarget.anki);
      });
      await pumpDestination(
        tester,
        SettingsDestinationId.cardCreation,
        <SettingsDestination>[],
      );
      expect(tester.takeException(), isNull);
      expect(selected(tester), SrsMiningTarget.anki);
      expect(find.text(t.card_target_anki_hint), findsWidgets);
      expect(find.text(t.anki_fetch), findsOneWidget, reason: 'Anki 分组默认展开');
      expect(
        find.byKey(const ValueKey<String>('srs-mining-deck')),
        findsNothing,
        reason: '未选中的 Fushi 复习一侧整组不显示',
      );
      // 分段条在最上方，Fushi 复习排第一（新用户默认目标）。
      expect(
        tester.getTopLeft(strip).dy,
        lessThan(tester.getTopLeft(find.text(t.anki_fetch)).dy),
      );
      expect(
        tester.getTopLeft(segment(t.srs_mining_target_srs)).dx,
        lessThan(tester.getTopLeft(segment(t.srs_mining_target_anki)).dx),
      );
      expect(find.textContaining('ecommend'), findsNothing);
      expect(find.textContaining('推荐'), findsNothing);
    });

    testWidgets('当前发往 Fushi 复习：Anki 分组整组不显示；点分段条的 Anki 切回', (
      WidgetTester tester,
    ) async {
      final (FushiDatabase srsDb, SrsDbStore store) = (await tester.runAsync(
        () => openSrsTestStore(),
      ))!;
      addTearDown(srsDb.close);
      await tester.runAsync(() async {
        await appModel.setModuleEnabled(ModuleId.srs, true);
        await appModel.setSrsMiningTarget(SrsMiningTarget.srs);
      });
      await pumpDestination(
        tester,
        SettingsDestinationId.cardCreation,
        <SettingsDestination>[],
        extraOverrides: <Override>[
          srsStoreProvider.overrideWith((Ref ref) async => store),
        ],
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(selected(tester), SrsMiningTarget.srs);
      expect(
        find.byKey(const ValueKey<String>('srs-mining-deck')),
        findsOneWidget,
      );
      // 内置 Fushi 卡片：卡面入口是「卡面外观」。
      expect(
        find.byKey(const ValueKey<String>('srs-mining-card-look')),
        findsOneWidget,
      );
      expect(find.text(t.anki_fetch), findsNothing);
      expect(find.text('AnkiConnect'), findsNothing);
      // 整页唯一的「Anki」是分段条里那一段：没有「Anki」分组头，也没有页头跳转胶囊。
      expect(find.text(t.srs_mining_target_anki), findsOneWidget);
      expect(segment(t.srs_mining_target_anki), findsOneWidget);

      await tester.tap(segment(t.srs_mining_target_anki));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(appModel.srsMiningTarget, SrsMiningTarget.anki);
    });

    testWidgets('复习模块关着：点「Fushi 复习」确认一次即开模块并改目标', (WidgetTester tester) async {
      await tester.runAsync(
        () => appModel.setModuleEnabled(ModuleId.srs, false),
      );
      await pumpDestination(
        tester,
        SettingsDestinationId.cardCreation,
        <SettingsDestination>[],
      );
      expect(selected(tester), SrsMiningTarget.anki);
      expect(
        tester.getSize(segment(t.srs_mining_target_srs)).height,
        greaterThan(0),
      );

      await tester.tap(segment(t.srs_mining_target_srs));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(t.dialog_ok).last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(appModel.moduleVisibility.isEnabled(ModuleId.srs), isTrue);
      expect(appModel.srsMiningTarget, SrsMiningTarget.srs);
    });

    for (final Size size in <Size>[
      const Size(360, 780),
      const Size(1280, 800),
    ]) {
      testWidgets('不溢出：${size.width.toInt()}×${size.height.toInt()}', (
        WidgetTester tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          await appModel.setModuleEnabled(ModuleId.srs, true);
          await appModel.setSrsMiningTarget(SrsMiningTarget.anki);
        });
        await pumpDestination(
          tester,
          SettingsDestinationId.cardCreation,
          <SettingsDestination>[],
        );
        expect(tester.takeException(), isNull);
        expect(strip, findsOneWidget);
      });
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../sync/sync_settings_schema_source_corpus.dart';

/// 读源码并把**注释**掩成等长空白，字符串字面量原样保留。
///
/// 【B 类要求型锚点整改，2026-08-01】本文件原来所有断言都跑在原始源码上，
/// `expect(source, contains('X'))` 只要 X 出现在任意一条注释里就绿。整改时这条
/// 掩码当场抓出一个**活的假绿**：`settings_home_page.dart` 要求包含
/// `'master-detail'`，而全文件里这个词只出现在
/// `false, // master-detail keeps selection in-pane.` 这条散文注释里——
/// 那条断言从来没有守住任何东西。已换成真实结构锚点 `SettingsDetailPage(`。
///
/// 这里用 [maskComments] 而不是 [maskCommentsAndStrings]：本文件有大量
/// `id: 'lookup.popup_instant_scroll'` 这类**要读字符串内容**的锚点。
String readNormalizedSource(String path) {
  return maskComments(File(path).readAsStringSync().replaceAll('\r\n', '\n'));
}

/// TODO-586：settings_schema.dart 已按领域拆成 8 个 destination 文件 + 1 个共享
/// fields 文件。把主文件与全部领域文件源拼成一份，让原本针对“单文件 schema”的
/// 整体契约断言（destination id 齐全、无旧 id、无旧弹窗页类名等）继续成立。
const List<String> kSettingsSchemaDomainFiles = <String>[
  'lib/src/settings/settings_schema.dart',
  'lib/src/settings/settings_schema_appearance.dart',
  'lib/src/settings/settings_schema_profiles.dart',
  'lib/src/settings/settings_schema_reading.dart',
  'lib/src/settings/settings_schema_lookup.dart',
  'lib/src/settings/settings_schema_card_creation.dart',
  'lib/src/settings/settings_schema_video.dart',
  'lib/src/settings/settings_schema_listening.dart',
  'lib/src/settings/settings_schema_system.dart',
  'lib/src/settings/settings_schema_fields.dart',
];

String readSettingsSchemaCombined() {
  return kSettingsSchemaDomainFiles.map(readNormalizedSource).join('\n');
}

void main() {
  const Map<String, List<String>> requiredFiles = <String, List<String>>{
    'lib/src/settings/settings_context.dart': <String>[
      'class SettingsContext',
      'AppModel appModel',
      'WidgetRef ref',
    ],
    'lib/src/settings/settings_destination.dart': <String>[
      'enum SettingsDestinationId',
      'sealed class SettingsItem',
      'class SettingsSwitchItem',
      'class SettingsSegmentedItem',
      'class SettingsSliderItem',
      'class SettingsStepperItem',
      'class SettingsCustomItem',
    ],
    // TODO-586：settings_schema.dart 按领域拆成 8 个 destination 文件 + 1 个共享
    // fields 文件（照搬 sync_settings_schema 独立 library 范式）。主文件只保留组装
    // buildSettingsSchema（调用各 buildXxxDestination + buildSyncBackupDestination）
    // 和 3 个 reader 投影 helper；各 destination id 字面量随函数体搬到对应领域文件。
    'lib/src/settings/settings_schema.dart': <String>[
      'List<SettingsDestination> buildSettingsSchema',
      'SettingsDestination buildReaderQuickSettingsDestination',
      'buildAppearanceDestination()',
      'buildProfilesDestination()',
      'buildReadingDestination()',
      'buildLookupDestination()',
      'buildCardCreationDestination()',
      'buildVideoDestination()',
      'buildListeningDestination()',
      'buildSyncBackupDestination()',
      'buildSystemDestination()',
    ],
    'lib/src/settings/settings_schema_appearance.dart': <String>[
      'SettingsDestination buildAppearanceDestination()',
      'SettingsDestinationId.appearance',
    ],
    'lib/src/settings/settings_schema_profiles.dart': <String>[
      'SettingsDestination buildProfilesDestination()',
      'SettingsDestinationId.profiles',
    ],
    'lib/src/settings/settings_schema_reading.dart': <String>[
      'SettingsDestination buildReadingDestination()',
      'SettingsDestinationId.reading',
    ],
    'lib/src/settings/settings_schema_lookup.dart': <String>[
      'SettingsDestination buildLookupDestination()',
      'SettingsDestinationId.lookup',
    ],
    'lib/src/settings/settings_schema_card_creation.dart': <String>[
      'SettingsDestination buildCardCreationDestination()',
      'SettingsDestinationId.cardCreation',
    ],
    'lib/src/settings/settings_schema_video.dart': <String>[
      'SettingsDestination buildVideoDestination()',
      'SettingsDestinationId.video',
    ],
    'lib/src/settings/settings_schema_listening.dart': <String>[
      'SettingsDestination buildListeningDestination()',
      'SettingsDestinationId.listening',
    ],
    'lib/src/settings/settings_schema_system.dart': <String>[
      'SettingsDestination buildSystemDestination()',
      'SettingsDestinationId.system',
    ],
    'lib/src/settings/settings_schema_fields.dart': <String>[
      'class SettingsSecretField',
      'class SettingsNumberField',
    ],
    'lib/src/sync/sync_settings_schema.dart': <String>[
      'SettingsDestination buildSyncBackupDestination',
      'SettingsDestinationId.syncBackup',
      'sync.sync_now',
      // 手动同步的实现搬去了 lib/src/sync/manual_sync_ui.dart（媒体页下拉同步共用
      // 同一入口），设置页这一行现在接的是那个共享入口。
      'runManualSyncWithFeedback',
    ],
    // schema 行的自适应组件收口在共享 settings_schema_widgets（见下条），两个渲染器
    // 只保留各自平台外壳并复用共享 SettingsSchemaSection。
    'lib/src/settings/material_settings_renderer.dart': <String>[
      'class MaterialSettingsRenderer',
      'SettingsSchemaSection',
      'FushiPageScaffold',
    ],
    'lib/src/settings/cupertino_settings_renderer.dart': <String>[
      'class CupertinoSettingsRenderer',
      'CupertinoPageScaffold',
      'CupertinoSliverNavigationBar',
      'SettingsSchemaSection',
    ],
    'lib/src/settings/settings_schema_widgets.dart': <String>[
      'class SettingsSchemaSection',
      'class SettingsSchemaItem',
      'AdaptiveSettingsSection',
      'AdaptiveSettingsSwitchRow',
      'AdaptiveSettingsSegmentedRow',
      'AdaptiveSettingsSliderRow',
    ],
    'lib/src/settings/settings_home_page.dart': <String>[
      'class SettingsHomePage',
      'DesktopContentKind.settings',
      // 旧锚点是散文词 'master-detail'，它在本文件里**只出现在一条注释**里
      // （`false, // master-detail keeps selection in-pane.`）——掩掉注释后当场
      // 露馅。主从布局的真实结构证据是它会把 destination 推进详情页。
      'SettingsDetailPage(',
    ],
    'lib/src/settings/settings_detail_page.dart': <String>[
      'class SettingsDetailPage',
      'SettingsDestination destination',
    ],
  };

  test('settings redesign files define schema-first platform renderers', () {
    for (final MapEntry<String, List<String>> entry in requiredFiles.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} must exist');

      // TODO-585: sync_settings_schema 拆成主库 + 5 个 part；该键读合并语料，
      // 让 runManualFullSync 等搬进 part 的标记仍被命中。
      final String source = entry.key.endsWith('sync_settings_schema.dart')
          ? maskComments(readSyncSettingsSchemaSource())
          : readNormalizedSource(entry.key);
      for (final String token in entry.value) {
        expect(
          source,
          contains(token),
          reason: '${entry.key} must contain $token（注释里的同名文本不算数）',
        );
      }
    }
  });

  test('settings home no longer uses the old linear adaptive page', () {
    final String source = readNormalizedSource(
        'lib/src/pages/implementations/hibiki_settings_page.dart');

    expect(source, contains('SettingsHomePage'));
    expect(source, contains('buildReaderQuickSettingsDestination'));
    expect(source, isNot(contains('class _ReaderBehaviorSettingsPage')));
    expect(source, isNot(contains('class _AudiobookSettingsPage')));
    expect(source, isNot(contains('class _UpdateSettingsPage')));
    expect(source, isNot(contains('_buildReaderOnlySwitches')));
  });

  test('reader settings dialog uses shared MD3 dialog chrome', () {
    final String source = readNormalizedSource(
        'lib/src/pages/implementations/hibiki_settings_page.dart');

    expect(containsIdentifierCall(source, 'FushiDialogFrame'), isTrue);
    expect(containsIdentifierCall(source, 'FushiModalSheetFrame'), isTrue);
    // 旧锚点把局部变量名 `context` 写进了契约（`FushiDesignTokens.of(context)`）。
    expect(containsIdentifierCall(source, 'FushiDesignTokens'), isTrue);
    expect(containsIdentifierCall(source, 'adaptiveAlertDialog'), isFalse);
  });

  test('settings shared actions use MD3 dialog chrome', () {
    final String actionsSource =
        readNormalizedSource('lib/src/settings/settings_actions.dart');
    // TODO-586：schema 拆成多领域文件，adaptiveAlertDialog 禁令要扫全部领域文件。
    final String schemaSource = readSettingsSchemaCombined();
    final String syncSource = maskComments(readSyncSettingsSchemaSource());
    final String combined = '$actionsSource\n$schemaSource\n$syncSource';

    expect(containsIdentifierCall(actionsSource, 'FushiDialogFrame'), isTrue);
    expect(
      containsIdentifierCall(actionsSource, 'FushiModalSheetFrame'),
      isTrue,
    );

    for (final String source in <String>[
      actionsSource,
      schemaSource,
      syncSource,
    ]) {
      expect(containsIdentifierCall(source, 'adaptiveAlertDialog'), isFalse);
    }
    expect(
      containsIdentifierCall(combined, 'showSettingsConfirmationDialog'),
      isTrue,
    );
  });

  test('settings renderers use shared MD3 spacing tokens', () {
    final String materialSource = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');
    final String cupertinoSource = readNormalizedSource(
        'lib/src/settings/cupertino_settings_renderer.dart');

    expect(
        containsIdentifierCall(materialSource, 'FushiDesignTokens'), isTrue);
    expect(
      containsIdentifierCall(cupertinoSource, 'FushiDesignTokens'),
      isTrue,
    );

    // 旧写法是 9 条 `isNot(contains('const EdgeInsets.fromLTRB(16, 8, 16, 16)'))`
    // 这样的**逐条拼写**禁令：只堵住被枚举到的那几种，16 改 20、换个构造器、
    // 换行重排全都静默放行。改成结构判据——渲染器里任何 EdgeInsets / SizedBox
    // 构造都不得带非零裸数字实参。
    expectTokenDerivedSpacing(materialSource, 'Material 设置渲染器');
    expectTokenDerivedSpacing(cupertinoSource, 'Cupertino 设置渲染器');
  });

  test('legacy adaptive alert factory is removed', () {
    final String source =
        readNormalizedSource('lib/src/utils/adaptive/adaptive_widgets.dart');

    expect(containsIdentifierCall(source, 'adaptiveAlertDialog'), isFalse);
    expect(containsIdentifierCall(source, 'CupertinoAlertDialog'), isFalse);
    // 裸子串 'AlertDialog(' 有两个毛病：① 它同时被上面两个更长的名字包含，把两条
    // 断言变成冗余；② 它匹配不到 `AlertDialog.adaptive(`（本仓真实在用的写法，
    // 见 media_sources_view.dart / log_uploader.dart），旧工厂以命名构造器形式
    // 复活就完全绕过。带标识符边界 + 吃命名构造器的匹配同时解决两点。
    expect(
      containsIdentifierCall(source, 'AlertDialog'),
      isFalse,
      reason: 'adaptive_widgets 不得再自造 AlertDialog（含 AlertDialog.adaptive）',
    );
  });

  test('legacy standalone display settings page is removed', () {
    // TODO-317: the residual DisplaySettingsPage (an AdaptiveSettingsScaffold
    // sub-page with zero live `lib/` references — its appearance row already
    // pointed elsewhere) was deleted. Reader display settings now live solely in
    // the schema `reading` destination rendered through the unified detail shell.
    expect(
      File('lib/src/pages/implementations/display_settings_page.dart')
          .existsSync(),
      isFalse,
      reason: 'DisplaySettingsPage should be deleted, not resurrected',
    );
    expect(
      readNormalizedSource('lib/pages.dart'),
      isNot(contains('display_settings_page.dart')),
      reason: 'pages barrel must not export the deleted display settings page',
    );
  });

  test('settings schema uses task-oriented destinations', () {
    final String destinationSource =
        readNormalizedSource('lib/src/settings/settings_destination.dart');
    final String schemaSource = readSettingsSchemaCombined();
    final String syncSource = maskComments(readSyncSettingsSchemaSource());
    final String combined = '$destinationSource\n$schemaSource\n$syncSource';

    for (final String token in <String>[
      'SettingsDestinationId.appearance',
      'SettingsDestinationId.profiles',
      'SettingsDestinationId.reading',
      'SettingsDestinationId.lookup',
      'SettingsDestinationId.cardCreation',
      'SettingsDestinationId.listening',
      'SettingsDestinationId.syncBackup',
      'SettingsDestinationId.system',
    ]) {
      expect(combined, contains(token), reason: 'missing $token');
    }

    expect(
        combined, isNot(contains('SettingsDestinationId.dictionaryAndCards')));
    expect(combined, isNot(contains('SettingsDestinationId.audiobook')));
    expect(schemaSource, isNot(contains('DictionarySettingsDialogPage')));
  });

  test('custom fonts are grouped with app appearance typography', () {
    // TODO-586：appearance/reading destination 各自独立成领域文件，整份文件即对应
    // 域的源（不再靠同文件相对位置切片）。
    final String appearanceSource = readNormalizedSource(
        'lib/src/settings/settings_schema_appearance.dart');
    final String readingSource =
        readNormalizedSource('lib/src/settings/settings_schema_reading.dart');

    expect(appearanceSource,
        contains('SettingsDestination buildAppearanceDestination()'));
    expect(readingSource,
        contains('SettingsDestination buildReadingDestination()'));

    expect(appearanceSource, contains('CustomFontsPage'));
    expect(appearanceSource, contains("id: 'appearance.font_catalog'"));
    expect(appearanceSource, contains('t.custom_fonts_catalog_title'));
    expect(appearanceSource, isNot(contains("id: 'appearance.fonts_app_ui'")));
    expect(appearanceSource, isNot(contains("id: 'appearance.fonts_body'")));
    expect(
      appearanceSource,
      isNot(contains("id: 'appearance.fonts_dictionary'")),
    );
    expect(readingSource, isNot(contains('CustomFontsPage')));
  });

  test('reader quick settings project from schema reader placements', () {
    // TODO-586：reader 投影 helper（collectReaderItems / sectionFor）留主文件；
    // 查词项的 ReaderPlacement 分组字面量随 _lookupDestination 搬到 lookup 领域文件。
    final String schemaSource =
        readNormalizedSource('lib/src/settings/settings_schema.dart');
    final String lookupSource =
        readNormalizedSource('lib/src/settings/settings_schema_lookup.dart');
    final String destinationSource =
        readNormalizedSource('lib/src/settings/settings_destination.dart');
    final String sheetSource = readNormalizedSource(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart');
    expect(schemaSource,
        contains('Map<ReaderGroup, List<SettingsItem>> collectReaderItems'));
    expect(schemaSource, contains('item.reader'));
    expect(schemaSource,
        isNot(contains("item.id == 'lookup.auto_read_on_lookup' ||")));

    expect(destinationSource, contains('lookup'));
    expect(schemaSource, contains('sectionFor(ReaderGroup.lookup'));
    expect(sheetSource, contains("page: 'lookup'"));
    expect(sheetSource, contains('ReaderGroup.lookup'));

    // 旧写法是 `substring(anchor, anchor + 520)` / `+ 360` 三个定长字符窗口：
    // 被守的那一项多写两行属性，`group:` 就漂出窗口、断言凭空变假；项变短又会把
    // **下一项**的属性读进来，断言指向错误对象。改成按括号配对取该 item 的
    // 构造器调用体，窗口由结构决定。
    for (final String itemId in <String>[
      "id: 'lookup.auto_read_on_lookup'",
      "id: 'lookup.pause_on_lookup'",
      // TODO-436：「滑动关闭弹窗」是查词弹窗手势行为，归查词分组。
      "id: 'reading_controls.enable_swipe_to_close'",
      // TODO-625：「滑动关闭灵敏度」与上面的开关配套，同属查词弹窗手势行为。
      "id: 'reading_controls.dismiss_swipe_sensitivity'",
    ]) {
      final String itemBody = enclosingCallOf(lookupSource, itemId).text;
      expect(itemBody, contains('group: ReaderGroup.lookup'),
          reason: '$itemId 必须归查词分组');
      expect(itemBody, isNot(contains('group: ReaderGroup.behavior')),
          reason: '$itemId 不得滞留在阅读控制分组');
    }
  });

  test('popup instant scroll is a global lookup display setting', () {
    final String lookupSource =
        readNormalizedSource('lib/src/settings/settings_schema_lookup.dart');
    // 「查词显示」拆成「词条内容 / 弹窗窗口」两组后，popup_instant_scroll 归弹窗
    // 窗口组；组尾还有带 ReaderPlacement 的滑动关闭手势对（TODO-436/625，本就
    // 该出现在书内快捷面板），所以既要断言它落在窗口组段内，也要断言它自身不是
    // reader-only。旧写法用一个跨两个标记的字符窗口同时表达这两件事，item 一长
    // 就会把邻项读进来；现在拆成「顺序」+「item 自身」两条独立判据。
    final int displayStart = lookupSource.indexOf(
      'title: t.settings_section_lookup_popup_window',
    );
    final int instantScrollStart =
        lookupSource.indexOf("id: 'lookup.popup_instant_scroll'");
    final int swipeStart =
        lookupSource.indexOf("id: 'reading_controls.enable_swipe_to_close'");
    expect(displayStart, isNonNegative);
    expect(instantScrollStart, greaterThan(displayStart),
        reason: 'popup_instant_scroll 必须落在「弹窗窗口」分组段内');
    expect(swipeStart, greaterThan(instantScrollStart));

    final String itemBody =
        enclosingCall(lookupSource, instantScrollStart).text;
    expect(itemBody, contains('t.popup_instant_scroll'));
    expect(itemBody, contains('popupInstantScroll'));
    expect(
      containsIdentifierCall(itemBody, 'ReaderPlacement'),
      isFalse,
      reason:
          'This controls shared lookup popup behavior across reader, video, '
          'and dictionary surfaces, so it must not become reader-only.',
    );
  });

  test('reader quick settings reuse the shared theme selector', () {
    final String sheetSource = readNormalizedSource(
        'lib/src/media/audiobook/reader_quick_settings_sheet.dart');
    final String actionsSource =
        readNormalizedSource('lib/src/settings/settings_actions.dart');

    expect(actionsSource, contains('Widget buildThemeSelector'));
    // 旧锚点把**实参写法** `_themeSettingsContext()` 也写进了契约；契约只是
    // 「快捷面板复用共享主题选择器」。
    expect(containsIdentifierCall(sheetSource, 'buildThemeSelector'), isTrue);
    expect(sheetSource, isNot(contains('TtuReaderSettings.availableThemes')));
    expect(
        containsIdentifierCall(sheetSource, 'buildReaderThemeChip'), isFalse);
  });

  test('sync backup settings use standard schema rows for options', () {
    final String source = maskComments(readSyncSettingsSchemaSource());

    // 旧锚点是 `"SettingsCustomItem(\n            id: 'sync.mode'"`——把 12 个
    // 空格的缩进和一个换行写进了契约，`dart format` 重排或多包一层就红，而守的
    // 根本不是格式。契约是「这个 id 属于哪种 schema 行类型」。
    expect(
        enclosingCallOf(source, "id: 'sync.mode'").name, 'SettingsCustomItem');
    expect(enclosingCallOf(source, "id: 'sync.statistics'").name,
        'SettingsSwitchItem');
    expect(enclosingCallOf(source, "id: 'sync.dictionary'").name,
        'SettingsSwitchItem');
    expect(source, isNot(contains("id: 'sync.audiobook'")));
    expect(source, isNot(contains("id: 'sync.options'")));
    expect(source, isNot(contains('class _SyncOptionsWidget')));
  });

  test('settings tab does not duplicate schema-level header actions', () {
    final String source =
        readNormalizedSource('lib/src/pages/implementations/home_page.dart');

    expect(source, isNot(contains('buildSettingsActions')));
    expect(source, isNot(contains('options_language')));
    expect(source, isNot(contains('options_github')));
  });

  test('profile destination uses one picker row for the active profile', () {
    // TODO-586：profiles destination 独立成领域文件。
    final String profilesSource =
        readNormalizedSource('lib/src/settings/settings_schema_profiles.dart');
    final String actionsSource =
        readNormalizedSource('lib/src/settings/settings_actions.dart');

    expect(profilesSource, contains('buildProfilePickerRow'));
    expect(profilesSource, isNot(contains('buildProfileSelectorRow')));
    expect(actionsSource, contains('AdaptiveSettingsPickerRow<int>'));
  });

  test('Cupertino icon font is bundled when CupertinoIcons are used', () {
    // pubspec 是 YAML，`maskComments` 是 Dart 词法（会把 `https://` 当行注释），
    // 这里按 YAML 的 `#` 注释规则剥。否则一条被注释掉的依赖行也能让断言变绿。
    final String pubspec = File('pubspec.yaml').readAsStringSync();

    expect(_yamlDeclares(pubspec, 'cupertino_icons:'), isTrue);
  });

  test('profile switching waits for reader settings refresh', () {
    final String source =
        readNormalizedSource('lib/src/profile/profile_view_model.dart');

    expect(
      containsCodeLine(
        source,
        'await ReaderFushiSource.readerSettings?.refreshFromDb()',
      ),
      isTrue,
    );
  });

  test(
      'wide settings nav pane gets a tonal container background (material only)',
      () {
    final String source =
        readNormalizedSource('lib/src/settings/settings_home_page.dart');
    // MD3 list-detail: nav pane on tonal token surface (surfaces.group =
    // surfaceContainerLow), gated to Material via the cupertino branch。
    // 旧锚点 `'cupertino ? null :'` 把三元表达式的**排版**写进了契约（换行一改
    // 就红）。契约是「取 surfaces.group 的那条语句本身被 cupertino 门控」。
    expect(source, contains('tokens.surfaces.group'));
    final String statement = _statementAround(source, 'tokens.surfaces.group');
    expect(
      statement,
      contains('cupertino'),
      reason: 'nav pane 的 tonal 底色必须由 cupertino 分支门控，实际语句：$statement',
    );
  });

  test('material destination list uses pill selection + gated chevron', () {
    final String source = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');
    expect(source, contains('FushiListItemSelectedShape'));
    // 旧锚点 `'pushRoutes ? const Icon(Icons.chevron_right)'` 同样钉死三元排版。
    // 契约是「trailing 的雪佛龙由 pushRoutes 门控」。
    final List<String> trailing = namedArgumentValues(source, 'trailing');
    expect(
      trailing.any((String value) =>
          value.contains('pushRoutes') &&
          value.contains('Icons.chevron_right')),
      isTrue,
      reason: 'destination 行的 chevron 必须由 pushRoutes 门控，实际：$trailing',
    );
  });

  test('settings lists and schema sections opt into contained surfaces', () {
    final String shared =
        readNormalizedSource('lib/src/utils/components/settings_shared.dart');
    final String schema =
        readNormalizedSource('lib/src/settings/settings_schema_widgets.dart');
    final String material = readNormalizedSource(
        'lib/src/settings/material_settings_renderer.dart');

    expect(shared, contains('class AdaptiveSettingsSurface'),
        reason: 'destination lists and non-row groups need the same surface');
    expect(shared, contains('SettingsSectionTitlePlacement.inside'));
    expect(schema,
        contains('titlePlacement: SettingsSectionTitlePlacement.inside'),
        reason:
            'schema detail section titles such as System must live inside the section surface');
    expect(containsIdentifierCall(material, 'AdaptiveSettingsSection'), isTrue,
        reason: 'Material destination list should be one grouped section');
    expect(material, contains('surfaceColor: tokens.surfaces.card'),
        reason:
            'wide supporting-pane list needs a visible lightweight surface over its tonal pane');
    expect(containsIdentifierCall(material, 'ListView.separated'), isFalse,
        reason: 'destination rows should not be a bare separated list');
  });

  test('settings Material polish keeps surfaces outlined and actions aligned',
      () {
    final String shared =
        readNormalizedSource('lib/src/utils/components/settings_shared.dart');

    expect(shared, contains('color ?? tokens.surfaces.card'),
        reason:
            'right-pane sections should read as card surfaces, not page fill');
    expect(shared, contains('borderColor: tokens.surfaces.outline'),
        reason: 'settings section surfaces need a lightweight MD3 outline');
    expect(shared, contains('endIndent:'));
    expect(shared, contains('tokens.spacing.rowHorizontal'),
        reason: 'row dividers should respect the section content density');
    expect(shared, contains('Alignment.centerRight'),
        reason: 'inline trailing actions must be visually right-aligned');
  });

  test('settings rows bound long text and inline controls for MD3 density', () {
    final String shared =
        readNormalizedSource('lib/src/utils/components/settings_shared.dart');
    final String destination =
        readNormalizedSource('lib/src/settings/settings_destination.dart');

    expect(shared, contains('kSettingsRowTitleMaxLines'));
    expect(shared, contains('kSettingsRowSubtitleMaxLines'));
    expect(shared,
        contains('maxLines: titleMaxLines ?? kSettingsRowTitleMaxLines'));
    // BUG-1184：说明文字（subtitle）**不再**硬钳 kSettingsRowSubtitleMaxLines。
    // 旧契约是「一律 3 行 + ellipsis」，窄屏上把说明尾部（路径、警告、生效条件）
    // 直接吃掉；设置行只有 minHeight、行高自由，这个上限纯属自伤。新契约：默认
    // 不限行数，调用点需要压缩时显式传 subtitleMaxLines（此时该常量仍是推荐值）。
    expect(shared, contains('maxLines: subtitleMaxLines'),
        reason: 'subtitle line count must come from the opt-in override, not a '
            'hard-coded clamp that truncates long help text on narrow screens');
    expect(shared, isNot(contains('maxLines: kSettingsRowSubtitleMaxLines')),
        reason: 'the old unconditional 3-line clamp must stay gone (BUG-1184)');
    expect(shared, contains('kSettingsPickerDefaultWidth'));
    expect(shared, contains('kSettingsPickerMinInlineWidth'));
    expect(shared, contains('trailingFlexible: !cupertino && !controlBelow'));
    expect(containsIdentifierCall(shared, 'LayoutBuilder'), isTrue,
        reason:
            'inline picker controls must be bounded by the settings row width');
    expect(destination, contains('this.controlBelow = true'),
        reason:
            'schema segmented rows default to the readable below-label form');
    // 裸子串 `'ListTile('` 顺带把 `SwitchListTile(` / `CheckboxListTile(` /
    // `SettingsListTile(` 一起命中，既让三条禁令互相冗余，又会误伤任何以
    // ListTile 结尾的共享组件；反过来它匹配不到 `ListTile.adaptive(`。带标识符
    // 边界后每个名字各管各的，禁令列表就得写全（这才是真实契约）。
    for (final String banned in <String>[
      'ListTile',
      'SwitchListTile',
      'CheckboxListTile',
      'RadioListTile',
      'ExpansionTile',
    ]) {
      expect(containsIdentifierCall(shared, banned), isFalse,
          reason: 'settings_shared.dart must keep the shared MD3 row system');
    }
    expect(containsIdentifierCall(shared, 'Card'), isFalse,
        reason: 'settings_shared.dart must not use a bare Material Card');
  });

  test('unified settings detail shell is the single page chrome (TODO-317)',
      () {
    // The shared shell delegates to the active platform renderer's
    // buildDetailPage, so every page built on it gets the SAME chrome
    // (FushiPageScaffold + 24px + AdaptiveSettingsSection on Material).
    final String shell =
        readNormalizedSource('lib/src/settings/settings_detail_page.dart');
    expect(shell, contains('Widget buildSettingsDetailShell('));
    expect(containsIdentifierCall(shell, 'renderer.buildDetailPage'), isTrue);

    // Every settings sub-page that the unified detail panel can navigate into
    // must route through that one shell — NOT its own bespoke scaffold — so the
    // user never sees a style jump between the detail pane and what it opens.
    // (Anki / Profile are projected as destination bodies and so are covered by
    // the renderer directly; these two are pushed sub-pages.)
    for (final String path in <String>[
      'lib/src/pages/implementations/shortcut_settings_page.dart',
      'lib/src/pages/implementations/miscellaneous_settings_page.dart',
    ]) {
      final String source = readNormalizedSource(path);
      expect(containsIdentifierCall(source, 'buildSettingsDetailShell'), isTrue,
          reason:
              '$path must render through the unified settings detail shell');
      // No parallel page-shell vocabulary: the converged pages do not stand up
      // their own AdaptiveSettingsScaffold or hand-rolled FushiPageScaffold.
      expect(
          containsIdentifierCall(source, 'AdaptiveSettingsScaffold'), isFalse,
          reason: '$path must not reintroduce its own settings scaffold');
      expect(containsIdentifierCall(source, 'FushiPageScaffold'), isFalse,
          reason: '$path must not hand-roll a page scaffold + bare list');
      // Body content is grouped into the shared section cards.
      expect(containsIdentifierCall(source, 'AdaptiveSettingsSection'), isTrue,
          reason: '$path body must use shared AdaptiveSettingsSection cards');
    }
  });
}

/// 「整个实参槽位就是一个数字字面量」的形态。
final RegExp _numericArgument = RegExp(r'[(,:]\s*(-?\d+(?:\.\d+)?)\s*[,)]');

/// 会被硬编码间距污染的构造器。
const List<String> _spacingConstructors = <String>['EdgeInsets', 'SizedBox'];

/// [expr] 里是否有**硬编码的非零间距**。
///
/// 零放行（零不是魔法尺寸，是「此边不留白」）；`tokens.spacing.card * 2` 这类以
/// 令牌为基准的算式也放行——契约是「间距来自设计令牌」，不是「不许出现数字」。
bool _hasHardcodedSpacing(String expr) {
  for (final RegExpMatch match in _numericArgument.allMatches(expr)) {
    final double? value = double.tryParse(match.group(1)!);
    if (value != null && value != 0) return true;
  }
  return false;
}

/// 该作用域内所有 `EdgeInsets` / `SizedBox` 构造都不得带非零裸数字实参。
void expectTokenDerivedSpacing(String code, String label) {
  for (final String name in _spacingConstructors) {
    for (final RegExpMatch match in identifierCall(name).allMatches(code)) {
      final EnclosingCall call = enclosingCall(code, match.end);
      expect(
        _hasHardcodedSpacing(call.text),
        isFalse,
        reason: '$label 的间距不得硬编码（一律走 tokens.spacing），实际是：${call.text}',
      );
    }
  }
}

/// 取 [needle] 所在的**语句**（上一个 `;` / `{` / `}` 到下一个 `;`）。
///
/// 用于「这个取值必须被某个条件门控」这类契约：断言语句里出现门控标识符，与三元
/// 表达式怎么排版无关。
String _statementAround(String code, String needle) {
  final int index = code.indexOf(needle);
  expect(index, isNonNegative, reason: '源码里找不到：$needle');
  int start = index;
  while (start > 0 &&
      code[start - 1] != ';' &&
      code[start - 1] != '{' &&
      code[start - 1] != '}') {
    start--;
  }
  int end = index;
  while (end < code.length && code[end] != ';') {
    end++;
  }
  return code.substring(start, end);
}

/// YAML 里是否有一条**未被注释掉**的行含 [key]。
///
/// TODO-2477：注释判定走共享 [maskHashComments]（等长掩码，且认引号状态，
/// `sed 's/#x/y/'` 这类引号内的 `#` 不会被当注释把半条命令抹掉）。
bool _yamlDeclares(String yaml, String key) {
  for (final String line in maskHashComments(yaml).split('\n')) {
    if (line.contains(key)) return true;
  }
  return false;
}

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/ops/settings_index.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/host_platform.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_schema.dart';

import '../helpers/test_platform_services.dart';

/// 设置项目录导出器（给官网 fushi.moe/settings.md、settings.json 用，读者是 AI）。
///
/// 数据源就是 `fushi_cli config ls` 与第二屏伴屏共用的那份设置索引
/// （`buildSettingsIndex`）：整棵设置 schema + 逃生口页面，一条不漏、不另维护清单。
/// 在一个全新（全默认值）的 `AppModel` 上各跑一遍英文 / 简体中文，把标题、位置、
/// 类型、可选值、范围、默认值合成一份目录。
///
/// - 平时作为普通测试跑：只校验目录形状（守住「导出器还能走完整棵 schema」）；
/// - 设了环境变量 [kSettingsCatalogDirEnv] 时把 `settings-catalog.json` /
///   `settings-catalog.md` 写进那个目录。CI 的 `.github/workflows/settings-catalog.yml`
///   这样生成后由 `tool/publish_settings_catalog.sh` 推到 `update-manifest` 分支。
///
/// 目录内容必须是**确定的**（不带时间戳 / commit）：发布脚本靠「内容没变就不提交」
/// 收敛，带了它们每次推送都会多一个提交。
const String kSettingsCatalogDirEnv = 'FUSHI_SETTINGS_CATALOG_DIR';

/// 目录 JSON 的格式版本；改字段含义时加一，官网 Worker 按它校验。
const int kSettingsCatalogSchema = 1;

const String _kCrumbSeparator = ' › ';

/// 一种界面语言下的一遍索引结果。
class _LocalePass {
  _LocalePass(this.tag, this.rows, this.texts);

  /// BCP 47 语言标签（`en` / `zh-CN`）。
  final String tag;

  /// 键 → `settingsIndexEntryJson` 的原始应答（schema 顺序）。
  final Map<String, Map<String, Object?>> rows;

  /// 键 → 该语言下的文案。
  final Map<String, _LocaleTexts> texts;
}

class _LocaleTexts {
  const _LocaleTexts({
    required this.title,
    required this.path,
    required this.description,
    required this.optionLabels,
  });

  final String title;

  /// 面包屑（「分类 › 分区 › 子页」）。
  final String path;

  /// 静态副标题；没有则空串。
  final String description;

  /// 可选值 token → 设置页上的标签。
  final Map<String, String> optionLabels;
}

_LocalePass _collect(String tag, SettingsContext settings) {
  // schema 树按 locale 缓存；显式清一次，不依赖缓存键比对。
  resetSettingsSchemaCache();
  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  final Map<String, _LocaleTexts> texts = <String, _LocaleTexts>{};
  for (final SettingsIndexEntry entry in buildSettingsIndex(settings).values) {
    rows[entry.key] = settingsIndexEntryJson(entry, settings);
    List<SettingsIndexChoice>? choices;
    try {
      choices = settingsIndexChoices(entry, settings);
    } catch (_) {
      choices = null;
    }
    texts[entry.key] = _LocaleTexts(
      title: entry.title,
      path: entry.breadcrumb,
      description: entry.item?.subtitle ?? '',
      optionLabels: <String, String>{
        for (final SettingsIndexChoice choice
            in choices ?? const <SettingsIndexChoice>[])
          choice.token: choice.label,
      },
    );
  }
  return _LocalePass(tag, rows, texts);
}

/// 把各语言的一遍结果合成目录条目。文案与结构字段以第一遍（基准平台的英文）为准；
/// 出厂默认值与「在哪些平台上显示」取自 [platformRows]（每个出包平台一遍的原始应答）：
/// 各平台默认值一致时只给 `default`，不一致时改给 `defaultByPlatform`；只在部分
/// 平台显示的行给 `platforms`。
List<Map<String, Object?>> _buildEntries(
  List<_LocalePass> passes,
  Map<HostPlatform, Map<String, Map<String, Object?>>> platformRows,
) {
  final _LocalePass base = passes.first;
  Map<String, String> localized(
    String key,
    String Function(_LocaleTexts texts) pick,
  ) => <String, String>{
    for (final _LocalePass pass in passes)
      if (pass.texts[key] != null && pick(pass.texts[key]!).isNotEmpty)
        pass.tag: pick(pass.texts[key]!),
  };

  final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
  for (final MapEntry<String, Map<String, Object?>> row in base.rows.entries) {
    final String key = row.key;
    final Map<String, Object?> json = row.value;
    final bool secret = json['redacted'] == true;
    final bool isValue = json['kind'] == CtlSettingKind.value;
    final Map<String, String> description = localized(
      key,
      (_LocaleTexts t) => t.description,
    );
    final List<Object?>? options = json['options'] as List<Object?>?;
    // 全新 AppModel 上读到的值就是出厂默认；机密项与读取失败的不给。
    final Map<String, Object?> defaults = <String, Object?>{};
    final List<String> shownOn = <String>[];
    for (final MapEntry<HostPlatform, Map<String, Map<String, Object?>>> pass
        in platformRows.entries) {
      final Map<String, Object?>? platformRow = pass.value[key];
      if (platformRow == null) continue;
      if (platformRow['visible'] == true) shownOn.add(pass.key.wireName);
      if (isValue && !secret && platformRow['error'] == null) {
        defaults[pass.key.wireName] = platformRow['value'];
      }
    }
    final bool uniformDefault =
        defaults.values.map((Object? v) => jsonEncode(v)).toSet().length <= 1;
    entries.add(<String, Object?>{
      'key': key,
      'kind': json['kind'],
      'type': json['type'],
      'title': localized(key, (_LocaleTexts t) => t.title),
      'path': localized(key, (_LocaleTexts t) => t.path),
      if (description.isNotEmpty) 'description': description,
      if (options != null)
        'options': <Map<String, Object?>>[
          for (final Object? token in options)
            <String, Object?>{
              'value': token,
              'label': <String, String>{
                for (final _LocalePass pass in passes)
                  if (pass.texts[key]?.optionLabels['$token'] != null)
                    pass.tag: pass.texts[key]!.optionLabels['$token']!,
              },
            },
        ],
      if (json['min'] != null) 'min': json['min'],
      if (json['max'] != null) 'max': json['max'],
      if (defaults.isNotEmpty && uniformDefault)
        'default': defaults.values.first,
      if (!uniformDefault) 'defaultByPlatform': defaults,
      // 全平台都显示 / 全平台都不显示（多半是要先开别的开关）的行不标平台。
      if (shownOn.isNotEmpty && shownOn.length < platformRows.length)
        'platforms': shownOn,
      if (secret) 'secret': true,
      if (json['userOnly'] == true) 'userOnly': true,
      if (json['runnable'] == true) 'runnable': true,
      if (json['destructive'] == true) 'destructive': true,
      if (json['help'] != null) 'help': json['help'],
      if (json['hint'] != null) 'hint': json['hint'],
      if (json['params'] != null) 'params': json['params'],
      if (json['listOps'] != null) 'listOps': json['listOps'],
      if (json['fields'] != null) 'fields': json['fields'],
    });
  }
  return entries;
}

Map<String, Object?> _buildCatalog(
  List<Map<String, Object?>> entries, {
  required String appVersion,
  required List<String> locales,
  required List<String> platforms,
}) => <String, Object?>{
  'schema': kSettingsCatalogSchema,
  'app': 'Fushi',
  'appVersion': appVersion,
  'source':
      'https://github.com/hajisensai/Fushi/blob/develop/fushi/test/settings/settings_catalog_export_test.dart',
  'locales': locales,
  // 默认值 / 可见行按这些出包平台各算了一遍（Linux 不出包，不算）。
  'platforms': platforms,
  'count': entries.length,
  'settings': entries,
};

String _cell(Object? value) => '${value ?? ''}'
    .replaceAll(r'\', r'\\')
    .replaceAll('|', r'\|')
    .replaceAll(RegExp(r'\s*\n\s*'), ' ')
    .trim();

String _code(Object? value) {
  final String text = '${value ?? ''}'.replaceAll('`', "'");
  return text.isEmpty ? '' : '`${_cell(text)}`';
}

String _localizedOf(Object? map, String tag) =>
    (map as Map<String, String>?)?[tag] ?? '';

/// 目录的 Markdown 版：按一级分类分节，一项一行。
String _renderMarkdown(Map<String, Object?> catalog) {
  final List<Map<String, Object?>> entries =
      catalog['settings']! as List<Map<String, Object?>>;
  final StringBuffer out = StringBuffer()
    ..writeln('# Fushi settings reference')
    ..writeln()
    ..writeln(
      '> Every setting of the Fushi app (version ${catalog['appVersion']}), '
      'generated from the app\'s own settings schema on each change. '
      '${entries.length} entries. Machine-readable copy: '
      '<https://fushi.moe/settings.json>.',
    )
    ..writeln()
    ..writeln('How to read this:')
    ..writeln()
    ..writeln(
      '- **Key** is the stable id of a setting. `fushi_cli config get <key>` / '
      '`fushi_cli config set <key> <value>` and the in-app AI assistant use '
      'the same keys.',
    )
    ..writeln(
      '- **Where** is the place inside the Settings page of the category '
      '(section › sub-page). Titles are given in English and Simplified '
      'Chinese; the app shows them in the interface language.',
    )
    ..writeln(
      '- **Type**: `bool`, `choice` (one of **Values**), `number` (range in '
      '**Values**), `text`, `secret` (a credential; never readable), `action` '
      '(a button), `status` (read-only), `list` (records), `custom` (a row '
      'drawn by the app, changed only in the Settings page).',
    )
    ..writeln(
      '- **Default** is the value on a fresh install. Where it differs '
      'between platforms, each value is listed with the platforms it applies '
      'to (${(catalog['platforms']! as List<Object?>).join(', ')}).',
    )
    ..writeln(
      '- *Only on ...* in Notes: the row is shown only on those platforms. '
      'Rows without it may still depend on another setting or module being '
      'enabled.',
    )
    ..writeln(
      '- Notes: *user only* = the AI assistant may not change it; '
      '*destructive* = asks for confirmation.',
    );

  // 逃生口页面的条目排在 schema 之后，但面包屑的头一段可能就是已有的一级分类：
  // 按分类归并（保持首次出现的顺序），不让同一个标题出现两次。
  final Map<String, List<Map<String, Object?>>> byCategory =
      <String, List<Map<String, Object?>>>{};
  for (final Map<String, Object?> entry in entries) {
    final String category = _localizedOf(
      entry['path'],
      'en',
    ).split(_kCrumbSeparator).first;
    (byCategory[category] ??= <Map<String, Object?>>[]).add(entry);
  }
  for (final MapEntry<String, List<Map<String, Object?>>> group
      in byCategory.entries) {
    final String zh = _localizedOf(
      group.value.first['path'],
      'zh-CN',
    ).split(_kCrumbSeparator).first;
    out
      ..writeln()
      ..writeln(
        '## ${group.key}${zh.isEmpty || zh == group.key ? '' : ' ($zh)'}',
      )
      ..writeln()
      ..writeln('| Key | Name | 名称 | Where | Type | Values | Default | Notes |')
      ..writeln('|---|---|---|---|---|---|---|---|');
    for (final Map<String, Object?> entry in group.value) {
      _writeRow(out, entry);
    }
  }
  return out.toString();
}

void _writeRow(StringBuffer out, Map<String, Object?> entry) {
  final List<String> crumbs = _localizedOf(
    entry['path'],
    'en',
  ).split(_kCrumbSeparator);
  final List<Map<String, Object?>>? options =
      entry['options'] as List<Map<String, Object?>>?;
  final String values = options != null
      ? options.map((Map<String, Object?> o) => _code(o['value'])).join(', ')
      : entry['min'] != null || entry['max'] != null
      ? '${entry['min'] ?? ''} – ${entry['max'] ?? ''}'
      : '';
  final List<String> notes = <String>[
    _localizedOf(entry['description'], 'en'),
    if (entry['help'] != null) '${entry['help']}',
    if (entry['platforms'] != null)
      '*only on ${(entry['platforms']! as List<Object?>).join(', ')}*',
    if (entry['userOnly'] == true) '*user only*',
    if (entry['destructive'] == true) '*destructive*',
  ].where((String s) => s.isNotEmpty).toList();
  out.writeln(
    '| ${_code(entry['key'])} '
    '| ${_cell(_localizedOf(entry['title'], 'en'))} '
    '| ${_cell(_localizedOf(entry['title'], 'zh-CN'))} '
    '| ${_cell(crumbs.skip(1).join(_kCrumbSeparator))} '
    '| ${entry['type']} '
    '| $values '
    '| ${_defaultCell(entry)} '
    '| ${_cell(notes.join(' · '))} |',
  );
}

/// Default 列：各平台一致时就是那个值；不一致时按值归并平台，
/// 如 `` `mp4` (android, windows, macos) · `webm` (ios) ``。
String _defaultCell(Map<String, Object?> entry) {
  if (entry.containsKey('default')) return _code(entry['default']);
  final Map<String, Object?>? byPlatform =
      entry['defaultByPlatform'] as Map<String, Object?>?;
  if (byPlatform == null) return '';
  final Map<String, List<String>> platformsByValue = <String, List<String>>{};
  for (final MapEntry<String, Object?> e in byPlatform.entries) {
    final String value = _code(e.value);
    (platformsByValue[value.isEmpty ? '(empty)' : value] ??= <String>[]).add(
      e.key,
    );
  }
  return platformsByValue.entries
      .map(
        (MapEntry<String, List<String>> e) =>
            '${e.key} (${e.value.join(', ')})',
      )
      .join(' · ');
}

String _appVersion() {
  final RegExpMatch? match = RegExp(
    r'^version:\s*([0-9A-Za-z.\-]+)',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync());
  if (match == null) throw StateError('pubspec.yaml 里没有 version');
  return match.group(1)!;
}

/// 在 [platform] 上「全新安装」的 app 里取一份 [SettingsContext]。
///
/// 全新安装的状态：空的内存库 + 刚加载的偏好仓库（一条偏好都没写过），读到的值
/// 就是出厂默认。裸 AppModel 没有偏好仓库，绝大多数值闭包会直接空指针。
/// 平台覆盖要先于 [PlatformServices] / [AppModel] 的构造（它们在构造时读平台）。
Future<SettingsContext> _freshInstallSettings(
  WidgetTester tester,
  HostPlatform platform,
) async {
  // 先卸掉上一个平台的树：pump 一帧把 riverpod 挂起的调度冲掉再卸，否则卸载时
  // autoDispose 再排一个任务会撞 `Only one task can be scheduled at a time`。
  await _unmountTree(tester);
  debugHostPlatformOverride = platform;
  debugDefaultTargetPlatformOverride = platform.targetPlatform;
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefs = PreferencesRepository(db);
  await tester.runAsync(prefs.loadFromDb);
  final Directory dataDir = Directory.systemTemp.createTempSync(
    'fushi_settings_catalog_',
  );
  addTearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });
  final PlatformServices services = testPlatformServices();
  final AppModel appModel = AppModel(services)
    // 空快照 = 主题 / 明暗 / 设计系统全取默认。
    ..themeNotifier = (ThemeNotifier(db, () => const TextTheme())
      ..loadFromPrefsSnapshot(const <String, String>{}))
    ..populateLocales()
    ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: dataDir)
    ..wireDatabaseForTesting(db);

  late SettingsContext settings;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [platformServicesProvider.overrideWithValue(services)],
      child: MaterialApp(
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            settings = SettingsContext(
              context: context,
              appModel: appModel,
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return settings;
}

Future<void> _unmountTree(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void _resetPlatformOverrides() {
  debugHostPlatformOverride = null;
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  tearDown(() {
    _resetPlatformOverrides();
    LocaleSettings.setLocale(AppLocale.en);
    resetSettingsSchemaCache();
  });

  testWidgets('设置项目录：走完整棵 schema，四个出包平台，中英双语，机密不出值', (
    WidgetTester tester,
  ) async {
    // 文案取基准平台（第一个出包平台 = Android）的中英两遍；其余平台只要原始应答
    // （默认值 / 可见性），英文一遍即可。
    final List<_LocalePass> passes = <_LocalePass>[];
    final Map<HostPlatform, Map<String, Map<String, Object?>>> platformRows =
        <HostPlatform, Map<String, Map<String, Object?>>>{};
    try {
      for (final HostPlatform platform in HostPlatform.shipping) {
        final SettingsContext settings = await _freshInstallSettings(
          tester,
          platform,
        );
        final bool isBase = platform == HostPlatform.shipping.first;
        for (final (String tag, AppLocale locale) in <(String, AppLocale)>[
          ('en', AppLocale.en),
          if (isBase) ('zh-CN', AppLocale.zhCn),
        ]) {
          LocaleSettings.setLocale(locale);
          final _LocalePass pass = _collect(tag, settings);
          if (isBase) passes.add(pass);
          if (tag == 'en') platformRows[platform] = pass.rows;
        }
      }
      // 卸掉最后一棵树再复位：复位后不能再有按旧平台构建的 widget 在跑。
      await _unmountTree(tester);
    } finally {
      _resetPlatformOverrides();
    }

    final List<Map<String, Object?>> entries = _buildEntries(
      passes,
      platformRows,
    );
    final Map<String, Object?> catalog = _buildCatalog(
      entries,
      appVersion: _appVersion(),
      locales: <String>[for (final _LocalePass pass in passes) pass.tag],
      platforms: <String>[
        for (final HostPlatform platform in platformRows.keys)
          platform.wireName,
      ],
    );
    final String json = const JsonEncoder.withIndent(' ').convert(catalog);
    final String markdown = _renderMarkdown(catalog);

    // 两种语言、四个平台走到的是同一批键（schema 结构不随语言 / 平台变，平台只改
    // 可见性与值）。
    expect(passes[1].rows.keys.toList(), passes[0].rows.keys.toList());
    for (final MapEntry<HostPlatform, Map<String, Map<String, Object?>>> pass
        in platformRows.entries) {
      expect(
        pass.value.keys.toSet(),
        passes[0].rows.keys.toSet(),
        reason: '${pass.key.wireName} 上的设置键与基准平台不同',
      );
    }
    // 平台覆盖真的生效了：galgame 设置只在 Windows 显示，挖矿片段格式 iOS 默认不同。
    expect(
      entries.any(
        (Map<String, Object?> e) =>
            (e['platforms'] as List<Object?>?)?.join(',') == 'windows',
      ),
      isTrue,
      reason: '没有任何只在 Windows 显示的行：平台覆盖没有生效',
    );
    expect(
      entries.any((Map<String, Object?> e) => e['defaultByPlatform'] != null),
      isTrue,
      reason: '所有默认值在四个平台上都一样：平台覆盖没有生效',
    );
    expect(entries.length, greaterThan(300), reason: '遍历没走完 schema');
    final Set<String> kinds = <String>{
      for (final Map<String, Object?> e in entries) e['kind']! as String,
    };
    expect(kinds, containsAll(CtlSettingKind.all));
    for (final Map<String, Object?> entry in entries) {
      final String key = entry['key']! as String;
      final Map<String, String> title = entry['title']! as Map<String, String>;
      expect(title['en'], isNotEmpty, reason: '$key 没有英文标题');
      expect(title['zh-CN'], isNotEmpty, reason: '$key 没有中文标题');
      if (entry['secret'] == true) {
        expect(entry.containsKey('default'), isFalse, reason: '$key 是机密项');
      }
    }
    // 中文那一遍确实是中文（语言切换生效）。
    expect(
      entries.any(
        (Map<String, Object?> e) =>
            (e['title']! as Map<String, String>)['zh-CN'] !=
            (e['title']! as Map<String, String>)['en'],
      ),
      isTrue,
    );
    // 读取失败的条目没有默认值；全默认的 AppModel 上任何一个平台都不该成片失败。
    final Map<String, List<String>> failedByPlatform = <String, List<String>>{
      for (final MapEntry<HostPlatform, Map<String, Map<String, Object?>>> pass
          in platformRows.entries)
        pass.key.wireName: <String>[
          for (final MapEntry<String, Map<String, Object?>> row
              in pass.value.entries)
            if (row.value['error'] != null) '${row.key}: ${row.value['error']}',
        ],
    };
    for (final MapEntry<String, List<String>> failed
        in failedByPlatform.entries) {
      expect(
        failed.value.length,
        lessThan(entries.length ~/ 20),
        reason: '${failed.key} 上读取失败的设置项过多：\n${failed.value.join('\n')}',
      );
    }
    expect(jsonDecode(json), isA<Map<String, Object?>>());
    expect(markdown, contains('| `appearance.brightness` '));
    // 每个一级分类只出一节（逃生口页面的条目并进同名分类）。
    final List<String> headings = <String>[
      for (final String line in markdown.split('\n'))
        if (line.startsWith('## ')) line,
    ];
    expect(headings.toSet().length, headings.length);
    expect(headings.length, greaterThan(15));

    // 统计行总是打印：CI 日志与分流到别的机器的运行都能看到走到了多少条。
    final int platformDefaults = entries
        .where((Map<String, Object?> e) => e['defaultByPlatform'] != null)
        .length;
    final int platformOnlyRows = entries
        .where((Map<String, Object?> e) => e['platforms'] != null)
        .length;
    final String unreadable = failedByPlatform.entries
        .map(
          (MapEntry<String, List<String>> e) =>
              '${e.key} ${e.value.length} [${e.value.take(8).join(' | ')}]',
        )
        .join('; ');
    // ignore: avoid_print
    print(
      'settings catalog: ${entries.length} entries, '
      '$platformDefaults platform-specific defaults, '
      '$platformOnlyRows platform-only rows, ${json.length} bytes json, '
      '${markdown.length} bytes md; unreadable: $unreadable',
    );
    final String? outDir = Platform.environment[kSettingsCatalogDirEnv];
    if (outDir != null && outDir.isNotEmpty) {
      await tester.runAsync(() async {
        final Directory dir = Directory(outDir);
        await dir.create(recursive: true);
        await File(
          '${dir.path}/settings-catalog.json',
        ).writeAsString('$json\n');
        await File('${dir.path}/settings-catalog.md').writeAsString(markdown);
      });
    }
  });
}

import 'package:flutter/widgets.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show CustomThemeEntry, kCustomThemeDefaultSeed;
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 自定义主题编辑页（`CustomThemePage`，「外观 › 主题」长按色卡进入，正文是自绘
/// 编辑器）在控制通道上的条目。
///
/// - `config items appearance.custom_themes.cli.themes ls|add|set|rm`：列出 / 新建 /
///   修改 / 删除自定义主题（主题色、界面底色、阅读器文字 / 背景色等各角色色）。
///   切换到某个主题仍走 `config set appearance.theme custom-theme:<id>`，或在
///   add / set 时带 `--arg select=true`。
///
/// 业务与页面同一份：[AppModel.upsertCustomTheme] / [AppModel.selectCustomTheme] /
/// [AppModel.setAppThemeKey] / [AppModel.deleteCustomTheme]，删除后的主题键回落与
/// 页面 `_resolveThemeKeyAfterDelete` 同一规则。
const String kCtlCustomThemesIdPrefix = 'appearance.custom_themes.cli.';

/// 颜色字段名 → 记录里的读写器。字段名与 [CustomThemeEntry.toJson] 的键去掉
/// `Color` 后缀一致（`surface` = 界面底色、`bg` = 阅读器背景色……）。
typedef _ColorRole = ({String help, int? Function(CustomThemeEntry e) read});

final Map<String, _ColorRole> _colorRoles = <String, _ColorRole>{
  'surface': (
    help: '界面底色（页面 / 卡片 / 菜单），整套容器梯度从它推；不给 = 由主题色派生',
    read: (CustomThemeEntry e) => e.surfaceColor,
  ),
  'bg': (help: '阅读器背景色', read: (CustomThemeEntry e) => e.bgColor),
  'font': (help: '阅读器文字色', read: (CustomThemeEntry e) => e.fontColor),
  'selection': (help: '选中高亮色', read: (CustomThemeEntry e) => e.selectionColor),
  'link': (help: '链接色', read: (CustomThemeEntry e) => e.linkColor),
  'secondary': (help: '次要强调色', read: (CustomThemeEntry e) => e.secondaryColor),
  'tertiary': (help: '点缀色', read: (CustomThemeEntry e) => e.tertiaryColor),
  'container': (
    help: '控件底色（primaryContainer）',
    read: (CustomThemeEntry e) => e.containerColor,
  ),
  'audio_highlight': (
    help: '有声书当前句高亮色',
    read: (CustomThemeEntry e) => e.sentenceAudioHighlightColor,
  ),
};

List<CtlBodyPage> buildCtlCustomThemesBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: '${t.settings_destination_appearance} › ${t.reader_theme}',
    items: <SettingsItem>[
      SettingsCustomItem(
        id: '${kCtlCustomThemesIdPrefix}themes',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.reader_theme,
        cliList: SettingsCliList(
          list: (SettingsContext c) async => <Map<String, Object?>>[
            for (final CustomThemeEntry e in c.appModel.customThemes)
              ctlCustomThemeRecord(c.appModel, e),
          ],
          add: _addTheme,
          update: _updateTheme,
          remove: _removeTheme,
          fields: <SettingsCliParam>[
            const SettingsCliParam('name', help: '主题名（可留空）', required: false),
            const SettingsCliParam(
              'accent',
              help: '主题色 #RRGGBB；派生色都从它出发。新建省略 = 品牌默认色',
              required: false,
            ),
            const SettingsCliParam(
              'auto_tone',
              help: 'true = 主题色只作种子、由配色算法自动调色调；false = 钉死原色（新建默认）',
              required: false,
            ),
            for (final MapEntry<String, _ColorRole> role in _colorRoles.entries)
              SettingsCliParam(
                role.key,
                help: '${role.value.help}；#RRGGBB / #AARRGGBB，空串或 none = 清除',
                required: false,
              ),
            const SettingsCliParam(
              'neutral',
              help: 'true = 派生色（标签 / 选中项 / 菜单 / 表面）用中性灰',
              required: false,
            ),
            const SettingsCliParam(
              'follow_system',
              help: 'true = 主题色跟随系统取色',
              required: false,
            ),
            const SettingsCliParam(
              'select',
              help: 'true = 写完后切换到该主题（新建默认 true）',
              required: false,
            ),
          ],
        ),
      ),
    ],
  ),
];

String _hex(int argb) {
  final String hex = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
  return hex.startsWith('FF') ? '#${hex.substring(2)}' : '#$hex';
}

/// 一条自定义主题的 CLI 记录。
Map<String, Object?> ctlCustomThemeRecord(
  AppModel appModel,
  CustomThemeEntry e,
) {
  return <String, Object?>{
    'id': e.id,
    'name': e.name,
    'active': appModel.appThemeKey == 'custom-theme:${e.id}',
    'accent': _hex(e.primaryColor ?? e.seed),
    'auto_tone': e.primaryColor == null,
    for (final MapEntry<String, _ColorRole> role in _colorRoles.entries)
      if (role.value.read(e) != null) role.key: _hex(role.value.read(e)!),
    'neutral': e.neutralDerived,
    'follow_system': e.followSystemAccent,
  };
}

/// `#RRGGBB` / `#AARRGGBB`（`#` 可省）→ ARGB；空串 / `none` → null。
int? _parseColor(String field, String raw) {
  final String v = raw.trim();
  if (v.isEmpty || v.toLowerCase() == 'none') return null;
  final String hex = v.startsWith('#') ? v.substring(1) : v;
  final int? parsed = hex.length == 6 || hex.length == 8
      ? int.tryParse(hex, radix: 16)
      : null;
  if (parsed == null) {
    throw ArgumentError('$field 不是合法颜色：$raw（要 #RRGGBB 或 #AARRGGBB）');
  }
  return hex.length == 6 ? 0xFF000000 | parsed : parsed;
}

bool _parseBool(String field, String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'true':
    case '1':
    case 'yes':
    case 'on':
      return true;
    case 'false':
    case '0':
    case 'no':
    case 'off':
      return false;
  }
  throw ArgumentError('$field 要 true / false：$raw');
}

void _rejectUnknownFields(Map<String, String> fields) {
  const Set<String> plain = <String>{
    'name',
    'accent',
    'auto_tone',
    'neutral',
    'follow_system',
    'select',
  };
  for (final String key in fields.keys) {
    if (!plain.contains(key) && !_colorRoles.containsKey(key)) {
      throw ArgumentError('未知字段：$key');
    }
  }
}

/// 把 [fields] 叠到 [base] 上（只改给出的字段），seed 与主题色同值，与编辑页
/// `_buildEntry` 一致。
CustomThemeEntry _merge(CustomThemeEntry base, Map<String, String> fields) {
  _rejectUnknownFields(fields);
  int? role(String key, int? current) =>
      fields.containsKey(key) ? _parseColor(key, fields[key]!) : current;

  final String? accentRaw = fields['accent'];
  final int accent = accentRaw != null
      ? (_parseColor('accent', accentRaw) ??
            (throw ArgumentError('accent 不能清空')))
      : (base.primaryColor ?? base.seed);
  final bool autoTone = fields.containsKey('auto_tone')
      ? _parseBool('auto_tone', fields['auto_tone']!)
      : base.primaryColor == null;
  return CustomThemeEntry(
    id: base.id,
    name: fields['name']?.trim() ?? base.name,
    seed: accent,
    primaryColor: autoTone ? null : accent,
    surfaceColor: role('surface', base.surfaceColor),
    bgColor: role('bg', base.bgColor),
    fontColor: role('font', base.fontColor),
    selectionColor: role('selection', base.selectionColor),
    linkColor: role('link', base.linkColor),
    secondaryColor: role('secondary', base.secondaryColor),
    tertiaryColor: role('tertiary', base.tertiaryColor),
    containerColor: role('container', base.containerColor),
    sentenceAudioHighlightColor: role(
      'audio_highlight',
      base.sentenceAudioHighlightColor,
    ),
    neutralDerived: fields.containsKey('neutral')
        ? _parseBool('neutral', fields['neutral']!)
        : base.neutralDerived,
    followSystemAccent: fields.containsKey('follow_system')
        ? _parseBool('follow_system', fields['follow_system']!)
        : base.followSystemAccent,
  );
}

Future<void> _persist(
  AppModel appModel,
  CustomThemeEntry entry, {
  required bool select,
}) async {
  await appModel.upsertCustomTheme(entry);
  if (!select) return;
  await appModel.selectCustomTheme(entry.id);
  await appModel.setAppThemeKey('custom-theme:${entry.id}');
}

Future<Object?> _addTheme(SettingsContext c, Map<String, String> fields) async {
  // 与编辑页新草稿同一默认值：品牌默认色、钉死主色。
  final CustomThemeEntry draft = CustomThemeEntry(
    id: 'ct-${DateTime.now().microsecondsSinceEpoch}',
    name: '',
    seed: kCustomThemeDefaultSeed,
    primaryColor: kCustomThemeDefaultSeed,
  );
  final CustomThemeEntry entry = _merge(
    draft,
    Map<String, String>.of(fields)..remove('select'),
  );
  final bool select = fields.containsKey('select')
      ? _parseBool('select', fields['select']!)
      : true;
  await _persist(c.appModel, entry, select: select);
  return ctlCustomThemeRecord(c.appModel, entry);
}

CustomThemeEntry _require(AppModel appModel, String id) {
  final CustomThemeEntry? entry = appModel.customThemeById(id);
  if (entry == null) throw ArgumentError('没有这个自定义主题：$id');
  return entry;
}

Future<Object?> _updateTheme(
  SettingsContext c,
  String id,
  Map<String, String> fields,
) async {
  final CustomThemeEntry entry = _merge(
    _require(c.appModel, id),
    Map<String, String>.of(fields)..remove('select'),
  );
  final bool select =
      fields.containsKey('select') && _parseBool('select', fields['select']!);
  await _persist(c.appModel, entry, select: select);
  return ctlCustomThemeRecord(c.appModel, entry);
}

Future<void> _removeTheme(SettingsContext c, String id) async {
  final AppModel appModel = c.appModel;
  _require(appModel, id);
  final bool wasActive = appModel.appThemeKey == 'custom-theme:$id';
  final List<CustomThemeEntry> remaining = appModel.customThemes
      .where((CustomThemeEntry e) => e.id != id)
      .toList();
  await appModel.deleteCustomTheme(id);
  // 页面删除后一律把主题键指回第一个剩余自定义主题 / 系统取色；CLI 只在删的
  // 正是当前主题时这么做，删别的主题不打断用户当前的预设选择。
  if (wasActive) {
    await appModel.setAppThemeKey(
      remaining.isEmpty ? 'system-theme' : 'custom-theme:${remaining.first.id}',
    );
  }
}

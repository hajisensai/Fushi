import 'package:flutter/widgets.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_cli_values.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;

/// 词典样式编辑器「可视化」页（`DictStyleVisualEditor`，规则表）在控制通道上的
/// 条目：`fushi_cli config items lookup.custom_css.cli.visual_rules ls|add|set|rm`。
///
/// 一条记录 = 一个「部位 + 作用域」的属性集合（与编辑器同一个数据结构
/// [DictStyleRule]）。记录 id：全局 = `<部位>`，单本词典 = `<部位>@<词典名>`
/// （只有释义系部位 `glossaryContent` / `glossaryTag` 能限定到单本词典）。
/// 写入走 `AppModel.saveDictStyleRules`——与编辑对话框「保存」同一个入口，同时
/// 刷新 Android 独立弹窗读的 CSS 编译产物缓存。手写 CSS 另见 schema 的
/// `lookup.custom_css` 动作。
///
/// 注意：编辑对话框开着时它持有自己的草稿，对话框再点保存会覆盖这里的写入。
const String kCtlDictStyleRulesId = 'lookup.custom_css.cli.visual_rules';

/// 清除某个属性的写法（空串同义）。
const String _kClear = 'none';

List<CtlBodyPage> buildCtlDictStyleBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: '${t.settings_destination_lookup} › ${t.dict_style_title}',
    items: <SettingsItem>[
      SettingsCustomItem(
        id: kCtlDictStyleRulesId,
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.dict_style_title,
        cliList: SettingsCliList(
          list: (SettingsContext c) async => <Map<String, Object?>>[
            for (final DictStyleRule rule in c.appModel.dictStyleRules)
              dictStyleRuleCliRecord(rule),
          ],
          add: _add,
          update: _update,
          remove: _remove,
          fields: <SettingsCliParam>[
            SettingsCliParam(
              'part',
              help:
                  '部位（仅 add）：'
                  '${DictStylePart.values.map((DictStylePart p) => p.name).join(' / ')}',
              required: false,
            ),
            const SettingsCliParam(
              'dictionary',
              help: '词典名（仅 add；省略 = 全部词典；只有 glossaryContent / glossaryTag 可限定）',
              required: false,
            ),
            const SettingsCliParam(
              'text_color',
              help: '文字颜色 #RRGGBB / #AARRGGBB；none = 清除',
              required: false,
            ),
            const SettingsCliParam(
              'background_color',
              help: '背景（高亮）色 #RRGGBB / #AARRGGBB；none = 清除',
              required: false,
            ),
            const SettingsCliParam(
              'bold',
              help: 'true / false；none = 清除',
              required: false,
            ),
            const SettingsCliParam(
              'italic',
              help: 'true / false；none = 清除',
              required: false,
            ),
            const SettingsCliParam(
              'underline',
              help: 'true / false；none = 清除',
              required: false,
            ),
            const SettingsCliParam(
              'font_scale',
              help: '字号倍数 0.6–2.4；none = 清除',
              required: false,
            ),
            const SettingsCliParam(
              'corner_radius',
              help: '圆角像素 0–24（配合背景色）；none = 清除',
              required: false,
            ),
          ],
        ),
      ),
    ],
  ),
];

/// 规则 → CLI 记录（颜色写成 `#AARRGGBB`，未设的属性不出现）。
Map<String, Object?> dictStyleRuleCliRecord(DictStyleRule rule) {
  final DictStyleProps p = rule.props;
  return <String, Object?>{
    'id': _recordId(rule.part, rule.dictionaryName),
    'part': rule.part.name,
    'dictionary': rule.dictionaryName,
    if (p.textColor != null) 'text_color': formatSettingsCliColor(p.textColor!),
    if (p.backgroundColor != null)
      'background_color': formatSettingsCliColor(p.backgroundColor!),
    if (p.bold != null) 'bold': p.bold,
    if (p.italic != null) 'italic': p.italic,
    if (p.underline != null) 'underline': p.underline,
    if (p.fontScale != null) 'font_scale': p.fontScale,
    if (p.cornerRadius != null) 'corner_radius': p.cornerRadius,
  };
}

String _recordId(DictStylePart part, String? dictionary) =>
    dictionary == null ? part.name : '${part.name}@$dictionary';

DictStylePart _parsePart(String raw) {
  final String name = raw.trim();
  for (final DictStylePart part in DictStylePart.values) {
    if (part.name == name) return part;
  }
  throw ArgumentError(
    '未知部位「$raw」，可选：'
    '${DictStylePart.values.map((DictStylePart p) => p.name).join(' / ')}',
  );
}

/// 校验作用域：部位必须支持单本词典；[requireInstalled] 时词典还必须已安装
/// （新建规则时；改 / 删已有规则不要求——词典删了之后残留的规则也要能清掉）。
String? _checkScope(
  SettingsContext c,
  DictStylePart part,
  String? dictionary, {
  bool requireInstalled = true,
}) {
  if (dictionary == null || dictionary.isEmpty) return null;
  if (!dictStylePartSupportsPerDictionary(part)) {
    throw ArgumentError(
      '部位 ${part.name} 只能全局设置（作用域锚点只包住释义子树），'
      '只有 glossaryContent / glossaryTag 能限定到单本词典',
    );
  }
  if (!requireInstalled) return dictionary;
  final bool installed = c.appModel.dictionaries.any(
    (Dictionary d) => d.name == dictionary,
  );
  if (!installed) throw ArgumentError('没有名为「$dictionary」的词典');
  return dictionary;
}

(DictStylePart, String?) _parseId(SettingsContext c, String id) {
  final int at = id.indexOf('@');
  final DictStylePart part = _parsePart(at < 0 ? id : id.substring(0, at));
  final String? dictionary = at < 0 ? null : id.substring(at + 1);
  return (part, _checkScope(c, part, dictionary, requireInstalled: false));
}

DictStyleRule? _find(
  List<DictStyleRule> rules,
  DictStylePart part,
  String? dictionary,
) {
  for (final DictStyleRule rule in rules) {
    if (rule.part == part && rule.dictionaryName == dictionary) return rule;
  }
  return null;
}

bool _isClear(String raw) =>
    raw.trim().isEmpty || raw.trim().toLowerCase() == _kClear;

bool? _parseBool(String key, String raw) {
  if (_isClear(raw)) return null;
  switch (raw.trim().toLowerCase()) {
    case 'true':
    case '1':
    case 'on':
      return true;
    case 'false':
    case '0':
    case 'off':
      return false;
  }
  throw ArgumentError('$key 要 true / false / none，收到「$raw」');
}

double? _parseRange(String key, String raw, double min, double max) {
  if (_isClear(raw)) return null;
  final double? value = double.tryParse(raw.trim());
  if (value == null || value < min || value > max) {
    throw ArgumentError('$key 要 $min–$max 的数，收到「$raw」');
  }
  return value;
}

/// 把 CLI 字段逐个覆写到 [props] 上；未给出的字段保持原值，`none` 清除。
DictStyleProps applyDictStyleCliFields(
  DictStyleProps props,
  Map<String, String> fields,
) {
  DictStyleProps out = props;
  for (final MapEntry<String, String> e in fields.entries) {
    final String v = e.value;
    switch (e.key) {
      case 'part':
      case 'dictionary':
        break;
      case 'text_color':
        out = out.copyWith(
          textColor: _isClear(v) ? null : parseSettingsCliColor(v),
        );
      case 'background_color':
        out = out.copyWith(
          backgroundColor: _isClear(v) ? null : parseSettingsCliColor(v),
        );
      case 'bold':
        out = out.copyWith(bold: _parseBool(e.key, v));
      case 'italic':
        out = out.copyWith(italic: _parseBool(e.key, v));
      case 'underline':
        out = out.copyWith(underline: _parseBool(e.key, v));
      case 'font_scale':
        out = out.copyWith(fontScale: _parseRange(e.key, v, 0.6, 2.4));
      case 'corner_radius':
        out = out.copyWith(cornerRadius: _parseRange(e.key, v, 0, 24));
      default:
        throw ArgumentError('未知字段 ${e.key}');
    }
  }
  return out;
}

Future<Object?> _add(SettingsContext c, Map<String, String> fields) async {
  final String? rawPart = fields['part'];
  if (rawPart == null || rawPart.trim().isEmpty) {
    throw ArgumentError('add 需要字段 part');
  }
  final DictStylePart part = _parsePart(rawPart);
  final String? dictionary = _checkScope(c, part, fields['dictionary']?.trim());
  final List<DictStyleRule> rules = c.appModel.dictStyleRules;
  if (_find(rules, part, dictionary) != null) {
    throw ArgumentError('规则 ${_recordId(part, dictionary)} 已存在，改属性用 set');
  }
  final DictStyleProps props = applyDictStyleCliFields(
    const DictStyleProps(),
    fields,
  );
  if (props.isEmpty) throw ArgumentError('至少给出一个属性字段');
  await c.appModel.saveDictStyleRules(
    dictStyleRulesWith(rules, part, dictionary, props),
  );
  return dictStyleRuleCliRecord(
    DictStyleRule(part: part, dictionaryName: dictionary, props: props),
  );
}

Future<Object?> _update(
  SettingsContext c,
  String id,
  Map<String, String> fields,
) async {
  if (fields.containsKey('part') || fields.containsKey('dictionary')) {
    throw ArgumentError('part / dictionary 是记录身份，不能 set；删掉重建');
  }
  final (DictStylePart part, String? dictionary) = _parseId(c, id);
  final List<DictStyleRule> rules = c.appModel.dictStyleRules;
  final DictStyleRule? existing = _find(rules, part, dictionary);
  if (existing == null) throw ArgumentError('没有规则 $id');
  final DictStyleProps props = applyDictStyleCliFields(existing.props, fields);
  await c.appModel.saveDictStyleRules(
    dictStyleRulesWith(rules, part, dictionary, props),
  );
  // 属性全清空 = 整条移除（与编辑器同一语义）。
  return props.isEmpty
      ? <String, Object?>{'id': id, 'removed': true}
      : dictStyleRuleCliRecord(
          DictStyleRule(part: part, dictionaryName: dictionary, props: props),
        );
}

Future<void> _remove(SettingsContext c, String id) async {
  final (DictStylePart part, String? dictionary) = _parseId(c, id);
  final List<DictStyleRule> rules = c.appModel.dictStyleRules;
  if (_find(rules, part, dictionary) == null) {
    throw ArgumentError('没有规则 $id');
  }
  await c.appModel.saveDictStyleRules(
    dictStyleRulesWith(rules, part, dictionary, const DictStyleProps()),
  );
}

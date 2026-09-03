/// 词典结果可视化样式规则的领域模型。
///
/// 数据结构决定一切：真相源是**结构化规则表**（部位 + 作用域 + 属性），CSS 只是
/// 编译产物。不把可视化产物和用户手写 CSS 存进同一份文本——那样回填面板就得反
/// 向解析手写 CSS，往返编辑必然互相破坏。两份独立存储，注入时拼接（编译产物在
/// 前、手写在后，手写优先）。
library;

import 'dart:convert';

/// 偏好键：可视化样式规则表（JSON）。
const String dictStyleRulesPrefKey = 'dict_style_rules';

/// 偏好键：规则表的 CSS 编译产物缓存。
///
/// 冗余数据，但这是**平台边界**决定的必要冗余：Android 独立弹窗 Activity 直接读
/// prefs 表（`PopupDbReader.kt`），跑不了 Dart 编译器。保存规则是唯一写入点，
/// 在那里同步落盘即可收口。
const String dictStyleRulesCssPrefKey = 'dict_style_rules_css';

/// 查词结果里可被单独调样式的部位。
///
/// 每个值对应一个**实测存在**的稳定选择器（见 [dictStylePartSelector]）。不提供
/// 「任意选择器」逃生口：那等于把手写 CSS 换个壳，可视化的意义就没了。
enum DictStylePart {
  /// 整张词条卡。
  entryCard,

  /// 词头。
  expression,

  /// 振假名（真正定位的盒子是 `.ruby-rt`，不是 `<rt>`）。
  ruby,

  /// 词性 / 词形标签。
  expressionTag,

  /// 去屈折链标签。
  deinflectionTag,

  /// 频率区。
  frequency,

  /// 音调区。
  pitch,

  /// 词典名行（分组标题）。
  dictionaryLabel,

  /// 释义正文。
  glossaryContent,

  /// 释义标签。
  glossaryTag,
}

/// 部位 → CSS 选择器（相对于弹窗文档根）。
String dictStylePartSelector(DictStylePart part) {
  switch (part) {
    case DictStylePart.entryCard:
      return '.entry';
    case DictStylePart.expression:
      return '.expression';
    case DictStylePart.ruby:
      return '.ruby-rt';
    case DictStylePart.expressionTag:
      return '.expr-tag';
    case DictStylePart.deinflectionTag:
      return '.deinflection-tag';
    case DictStylePart.frequency:
      return '.frequency-section';
    case DictStylePart.pitch:
      return '.pitch-section';
    case DictStylePart.dictionaryLabel:
      return 'summary.dict-label';
    case DictStylePart.glossaryContent:
      return '.glossary-content';
    case DictStylePart.glossaryTag:
      return '.glossary-tag';
  }
}

/// 该部位能否限定到单本词典。
///
/// 作用域锚点 `[data-dictionary="名"]` 只包住释义子树（`popup.js` 建 DOM 时它是
/// `.glossary-group` 的直接子节点，而词头/频率/音调/词典名行都在它**外面**）。
/// 所以只有释义系部位可以 per-dictionary；其余只能全局。
///
/// 这是 DOM 结构决定的硬约束，不是偷懒——一个词条的词头是所有词典共用的，
/// 「某本词典的词头」在语义上就不存在。
bool dictStylePartSupportsPerDictionary(DictStylePart part) {
  return part == DictStylePart.glossaryContent ||
      part == DictStylePart.glossaryTag;
}

/// 一个部位可调的属性集合。全部可空 = 未设置 = 不生成该声明。
class DictStyleProps {
  const DictStyleProps({
    this.textColor,
    this.backgroundColor,
    this.bold,
    this.italic,
    this.underline,
    this.fontScale,
    this.cornerRadius,
  });

  factory DictStyleProps.fromJson(Map<String, dynamic> json) {
    return DictStyleProps(
      textColor: _asInt(json['textColor']),
      backgroundColor: _asInt(json['backgroundColor']),
      bold: _asBool(json['bold']),
      italic: _asBool(json['italic']),
      underline: _asBool(json['underline']),
      fontScale: _asDouble(json['fontScale']),
      cornerRadius: _asDouble(json['cornerRadius']),
    );
  }

  /// 文字颜色，0xAARRGGBB。
  final int? textColor;

  /// 背景色（= 高亮），0xAARRGGBB。
  final int? backgroundColor;

  final bool? bold;
  final bool? italic;
  final bool? underline;

  /// 字号倍数（相对继承值），如 1.2。
  final double? fontScale;

  /// 圆角像素，配合 [backgroundColor] 用。
  final double? cornerRadius;

  /// 一条属性都没设 = 这条规则不产出任何 CSS。
  bool get isEmpty =>
      textColor == null &&
      backgroundColor == null &&
      bold == null &&
      italic == null &&
      underline == null &&
      fontScale == null &&
      cornerRadius == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (textColor != null) 'textColor': textColor,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        if (bold != null) 'bold': bold,
        if (italic != null) 'italic': italic,
        if (underline != null) 'underline': underline,
        if (fontScale != null) 'fontScale': fontScale,
        if (cornerRadius != null) 'cornerRadius': cornerRadius,
      };

  /// 逐属性覆写。**省略 = 保持原值，显式传 null = 清除该属性**。
  ///
  /// 普通 `copyWith` 在这里是坏的：null 既是「没传」又是「清空」，而「把颜色改回
  /// 默认」恰恰就是传 null。故用 [unset] 哨兵区分两者。
  DictStyleProps copyWith({
    Object? textColor = unset,
    Object? backgroundColor = unset,
    Object? bold = unset,
    Object? italic = unset,
    Object? underline = unset,
    Object? fontScale = unset,
    Object? cornerRadius = unset,
  }) {
    return DictStyleProps(
      textColor:
          identical(textColor, unset) ? this.textColor : textColor as int?,
      backgroundColor: identical(backgroundColor, unset)
          ? this.backgroundColor
          : backgroundColor as int?,
      bold: identical(bold, unset) ? this.bold : bold as bool?,
      italic: identical(italic, unset) ? this.italic : italic as bool?,
      underline:
          identical(underline, unset) ? this.underline : underline as bool?,
      fontScale:
          identical(fontScale, unset) ? this.fontScale : fontScale as double?,
      cornerRadius: identical(cornerRadius, unset)
          ? this.cornerRadius
          : cornerRadius as double?,
    );
  }

  /// [copyWith] 的「未传参」哨兵。公开的：调用方在别的库里也要能显式表达
  /// 「这个字段不动」。
  static const Object unset = Object();
}

/// 取某个部位 + 作用域下的当前属性；没设过就是全空。
DictStyleProps dictStylePropsFor(
  List<DictStyleRule> rules,
  DictStylePart part,
  String? dictionaryName,
) {
  for (final DictStyleRule rule in rules) {
    if (rule.part == part && rule.dictionaryName == dictionaryName) {
      return rule.props;
    }
  }
  return const DictStyleProps();
}

/// 写回某个部位 + 作用域的属性，返回新表。
///
/// 属性变空即整条移除——空规则不产 CSS，留着只会让「有没有设过」这个判断在
/// 后面每一处都要多带一个特例。
List<DictStyleRule> dictStyleRulesWith(
  List<DictStyleRule> rules,
  DictStylePart part,
  String? dictionaryName,
  DictStyleProps props,
) {
  final String? scope =
      dictStylePartSupportsPerDictionary(part) ? dictionaryName : null;
  final List<DictStyleRule> out = <DictStyleRule>[
    for (final DictStyleRule rule in rules)
      if (!(rule.part == part && rule.dictionaryName == scope)) rule,
  ];
  if (!props.isEmpty) {
    out.add(
      DictStyleRule(part: part, dictionaryName: scope, props: props),
    );
  }
  return out;
}

/// 一条可视化样式规则。
class DictStyleRule {
  const DictStyleRule({
    required this.part,
    this.dictionaryName,
    this.props = const DictStyleProps(),
  });

  factory DictStyleRule.fromJson(Map<String, dynamic> json) {
    final DictStylePart part = _partFromName(json['part']?.toString() ?? '');
    final String? rawDict = json['dictionaryName']?.toString();
    return DictStyleRule(
      part: part,
      // 非法组合在解码期就抹平：坏数据不该在渲染期变成一条打不中任何东西
      // （或者更糟：打中所有词典）的规则。
      dictionaryName: (rawDict == null || rawDict.isEmpty) ||
              !dictStylePartSupportsPerDictionary(part)
          ? null
          : rawDict,
      props: json['props'] is Map<String, dynamic>
          ? DictStyleProps.fromJson(json['props'] as Map<String, dynamic>)
          : const DictStyleProps(),
    );
  }

  final DictStylePart part;

  /// null = 全局；非 null = 仅该词典（仅释义系部位合法，见
  /// [dictStylePartSupportsPerDictionary]）。
  final String? dictionaryName;

  final DictStyleProps props;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'part': part.name,
        if (dictionaryName != null) 'dictionaryName': dictionaryName,
        'props': props.toJson(),
      };
}

/// 从偏好原始串解码规则表。
///
/// 空串 / 坏 JSON / 形状不对 / 未知部位名一律跳过该条（与 `customDictCSS` 同款
/// 容错——坏数据不该把编辑器炸掉，重新保存即自愈）。
List<DictStyleRule> decodeDictStyleRules(String raw) {
  if (raw.isEmpty) return const <DictStyleRule>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <DictStyleRule>[];
    return decoded
        .whereType<Map<String, dynamic>>()
        .where((Map<String, dynamic> m) => _isKnownPart(m['part']?.toString()))
        .map(DictStyleRule.fromJson)
        .where((DictStyleRule r) => !r.props.isEmpty)
        .toList();
  } on FormatException {
    return const <DictStyleRule>[];
  }
}

/// 编码规则表为偏好原始串。
///
/// 空表编码为空串（保持「从未用过」与「清空了」在偏好层同形，不留空数组残骸）。
/// 空属性的规则被丢弃——它不产出 CSS，留着只会在下次解码时再被过滤一遍。
String encodeDictStyleRules(List<DictStyleRule> rules) {
  final List<DictStyleRule> kept =
      rules.where((DictStyleRule r) => !r.props.isEmpty).toList();
  if (kept.isEmpty) return '';
  return jsonEncode(kept.map((DictStyleRule r) => r.toJson()).toList());
}

bool _isKnownPart(String? name) =>
    name != null &&
    DictStylePart.values.any((DictStylePart p) => p.name == name);

DictStylePart _partFromName(String name) => DictStylePart.values.firstWhere(
      (DictStylePart p) => p.name == name,
      orElse: () => DictStylePart.entryCard,
    );

int? _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
bool? _asBool(Object? v) => v is bool ? v : null;
double? _asDouble(Object? v) => v is num ? v.toDouble() : null;

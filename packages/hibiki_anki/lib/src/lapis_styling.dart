/// Lapis 卡片样式客制化的纯函数层：CSS 组合、字号缩放、漂移判定。
///
/// 设计（消除「覆盖用户改动」这个特殊情况）：推送到 Anki 的最终 styling 是
/// 三段拼接——vendored Lapis CSS + Hibiki delta（[LapisNoteType.template]，
/// 已有）+ **带标记的用户区段**（字号缩放变量覆写 + 用户自由 CSS）。用户客制化
/// 只存在于用户区段，基线升级时区段原样重拼，迁移不需要猜哪些是用户改的。
///
/// 全部纯函数，可单测；副作用（读写 Anki / 落盘备份）在 hibiki 应用层的
/// LapisTemplateService。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'lapis_note_type.dart';

/// 用户客制化区段起始标记。整段由 Hibiki 生成管理；用户在 Anki 里直接改
/// 标记内内容会在下次应用时被覆写（应用前有强制自动备份兜底）。
const String lapisUserCssBeginMarker = '/* HIBIKI-LAPIS-USER BEGIN */';

/// 用户客制化区段结束标记。
const String lapisUserCssEndMarker = '/* HIBIKI-LAPIS-USER END */';

/// 可视化编辑器写进 [AnkiSettings.lapisCustomCss] 的托管区段。自由 CSS 保留在
/// 区段外；编辑器只重写这一块，用户仍可在高级编辑器里写任意 Lapis CSS。
const String lapisVisualCssBeginMarker = '/* HIBIKI-LAPIS-VISUAL BEGIN */';
const String lapisVisualCssEndMarker = '/* HIBIKI-LAPIS-VISUAL END */';
const String _lapisVisualConfigPrefix = '/* HIBIKI-LAPIS-VISUAL-CONFIG ';

/// Lapis 预览中可直接点选、并由可视化编辑器生成稳定选择器的内容区域。
enum LapisVisualField {
  expression('expression'),
  reading('reading'),
  sentence('sentence'),
  definitionInfo('definition-info'),
  definitionBox('definition-box'),
  definitionContent('definition-content'),
  selectedDefinition('selected-definition'),
  primaryDefinition('primary-definition'),
  glossaries('glossaries'),
  dictionaryEntry('dictionary-entry'),
  dictionaryName('dictionary-name'),
  definitionExample('definition-example');

  const LapisVisualField(this.wireName);

  final String wireName;

  static LapisVisualField? fromWireName(String value) {
    for (final LapisVisualField field in values) {
      if (field.wireName == value) return field;
    }
    return null;
  }

  bool get backOnly => switch (this) {
        LapisVisualField.expression || LapisVisualField.sentence => false,
        _ => true,
      };

  bool get supportsBoxLayout => switch (this) {
        LapisVisualField.sentence ||
        LapisVisualField.definitionBox ||
        LapisVisualField.definitionContent ||
        LapisVisualField.selectedDefinition ||
        LapisVisualField.primaryDefinition ||
        LapisVisualField.glossaries ||
        LapisVisualField.dictionaryEntry =>
          true,
        _ => false,
      };
}

enum LapisVisualTextAlign {
  start('start'),
  center('center'),
  end('end');

  const LapisVisualTextAlign(this.cssValue);

  final String cssValue;

  static LapisVisualTextAlign? fromCssValue(String value) {
    for (final LapisVisualTextAlign alignment in values) {
      if (alignment.cssValue == value) return alignment;
    }
    return null;
  }
}

/// 单个 Lapis 内容区域的低风险样式参数。100% / 非粗体 / 默认对齐 / 默认颜色
/// 表示不生成覆盖，因而不会改变出厂 Lapis。
class LapisVisualRule {
  const LapisVisualRule({
    this.fontScalePercent = 100,
    this.bold = false,
    this.alignment,
    this.colorHex,
    this.lineHeightPercent,
    this.backgroundColorHex,
    this.borderWidthPx,
    this.borderColorHex,
    this.borderRadiusPx,
    this.paddingPx,
    this.marginBlockPx,
  });

  final int fontScalePercent;
  final bool bold;
  final LapisVisualTextAlign? alignment;
  final String? colorHex;
  final int? lineHeightPercent;
  final String? backgroundColorHex;
  final int? borderWidthPx;
  final String? borderColorHex;
  final int? borderRadiusPx;
  final int? paddingPx;
  final int? marginBlockPx;

  bool get isDefault =>
      fontScalePercent == 100 &&
      !bold &&
      alignment == null &&
      colorHex == null &&
      lineHeightPercent == null &&
      backgroundColorHex == null &&
      borderWidthPx == null &&
      borderColorHex == null &&
      borderRadiusPx == null &&
      paddingPx == null &&
      marginBlockPx == null;

  LapisVisualRule copyWith({
    int? fontScalePercent,
    bool? bold,
    Object? alignment = _lapisVisualUnset,
    Object? colorHex = _lapisVisualUnset,
    Object? lineHeightPercent = _lapisVisualUnset,
    Object? backgroundColorHex = _lapisVisualUnset,
    Object? borderWidthPx = _lapisVisualUnset,
    Object? borderColorHex = _lapisVisualUnset,
    Object? borderRadiusPx = _lapisVisualUnset,
    Object? paddingPx = _lapisVisualUnset,
    Object? marginBlockPx = _lapisVisualUnset,
  }) =>
      LapisVisualRule(
        fontScalePercent: fontScalePercent ?? this.fontScalePercent,
        bold: bold ?? this.bold,
        alignment: identical(alignment, _lapisVisualUnset)
            ? this.alignment
            : alignment as LapisVisualTextAlign?,
        colorHex: identical(colorHex, _lapisVisualUnset)
            ? this.colorHex
            : colorHex as String?,
        lineHeightPercent: identical(lineHeightPercent, _lapisVisualUnset)
            ? this.lineHeightPercent
            : lineHeightPercent as int?,
        backgroundColorHex: identical(backgroundColorHex, _lapisVisualUnset)
            ? this.backgroundColorHex
            : backgroundColorHex as String?,
        borderWidthPx: identical(borderWidthPx, _lapisVisualUnset)
            ? this.borderWidthPx
            : borderWidthPx as int?,
        borderColorHex: identical(borderColorHex, _lapisVisualUnset)
            ? this.borderColorHex
            : borderColorHex as String?,
        borderRadiusPx: identical(borderRadiusPx, _lapisVisualUnset)
            ? this.borderRadiusPx
            : borderRadiusPx as int?,
        paddingPx: identical(paddingPx, _lapisVisualUnset)
            ? this.paddingPx
            : paddingPx as int?,
        marginBlockPx: identical(marginBlockPx, _lapisVisualUnset)
            ? this.marginBlockPx
            : marginBlockPx as int?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'fontScalePercent': fontScalePercent,
        'bold': bold,
        if (alignment != null) 'alignment': alignment!.cssValue,
        if (colorHex != null) 'colorHex': colorHex,
        if (lineHeightPercent != null) 'lineHeightPercent': lineHeightPercent,
        if (backgroundColorHex != null)
          'backgroundColorHex': backgroundColorHex,
        if (borderWidthPx != null) 'borderWidthPx': borderWidthPx,
        if (borderColorHex != null) 'borderColorHex': borderColorHex,
        if (borderRadiusPx != null) 'borderRadiusPx': borderRadiusPx,
        if (paddingPx != null) 'paddingPx': paddingPx,
        if (marginBlockPx != null) 'marginBlockPx': marginBlockPx,
      };

  static LapisVisualRule? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final Object? rawScale = value['fontScalePercent'];
    final int scale = rawScale is int ? rawScale.clamp(50, 250).toInt() : 100;
    final Object? rawAlignment = value['alignment'];
    final LapisVisualTextAlign? alignment = rawAlignment is String
        ? LapisVisualTextAlign.fromCssValue(rawAlignment)
        : null;
    final Object? rawColor = value['colorHex'];
    final String? color = rawColor is String && _isCssHexColor(rawColor)
        ? rawColor.toUpperCase()
        : null;
    final int? lineHeight = _clampedOptionalInt(
      value['lineHeightPercent'],
      min: 100,
      max: 250,
    );
    final String? backgroundColor =
        _normalizedOptionalCssHex(value['backgroundColorHex']);
    final int? borderWidth = _clampedOptionalInt(
      value['borderWidthPx'],
      min: 0,
      max: 12,
    );
    final String? borderColor =
        _normalizedOptionalCssHex(value['borderColorHex']);
    final int? borderRadius = _clampedOptionalInt(
      value['borderRadiusPx'],
      min: 0,
      max: 48,
    );
    final int? padding = _clampedOptionalInt(
      value['paddingPx'],
      min: 0,
      max: 48,
    );
    final int? marginBlock = _clampedOptionalInt(
      value['marginBlockPx'],
      min: 0,
      max: 48,
    );
    return LapisVisualRule(
      fontScalePercent: scale,
      bold: value['bold'] == true,
      alignment: alignment,
      colorHex: color,
      lineHeightPercent: lineHeight,
      backgroundColorHex: backgroundColor,
      borderWidthPx: borderWidth,
      borderColorHex: borderColor,
      borderRadiusPx: borderRadius,
      paddingPx: padding,
      marginBlockPx: marginBlock,
    );
  }
}

const Object _lapisVisualUnset = Object();

/// 自由 CSS 与可视化托管规则的拆分结果。
class LapisVisualStyleSheet {
  const LapisVisualStyleSheet({
    required this.freeformCss,
    required this.rules,
    this.managedFirst = false,
  });

  final String freeformCss;
  final Map<LapisVisualField, LapisVisualRule> rules;

  /// 托管区段原本是否排在用户自由 CSS **之前**。托管区段全部带 `!important`
  /// （见 [_buildLapisVisualFieldCss]，必须压过 Lapis 自己的高特异性规则），
  /// 所以谁排在后面直接决定谁说了算。把这一位带出来、再由 [composeLapisVisualStyleSheet]
  /// 原样写回，用户刻意写在托管块之后的覆盖才不会被保存动作静默搬到前面去。
  final bool managedFirst;

  LapisVisualRule ruleFor(LapisVisualField field) =>
      rules[field] ?? const LapisVisualRule();
}

/// 托管区段与自由 CSS 之间的分隔符。[splitLapisVisualStyleSheet] 只剥掉**恰好
/// 一处**该分隔符，用户自己写的空行/缩进原样保留。
const String _lapisVisualBlockSeparator = '\n\n';

LapisVisualStyleSheet _lapisVisualAllFreeform(String customCss) =>
    LapisVisualStyleSheet(
      freeformCss: customCss,
      rules: const <LapisVisualField, LapisVisualRule>{},
    );

String _withoutLapisSeparatorSuffix(String value) =>
    value.endsWith(_lapisVisualBlockSeparator)
        ? value.substring(0, value.length - _lapisVisualBlockSeparator.length)
        : value;

String _withoutLapisSeparatorPrefix(String value) =>
    value.startsWith(_lapisVisualBlockSeparator)
        ? value.substring(_lapisVisualBlockSeparator.length)
        : value;

/// 从现有自定义 CSS 中拆出可视化托管区段。区段损坏时返回「全部是自由 CSS」，
/// 绝不因为打开编辑器就吞掉用户手写内容。
LapisVisualStyleSheet splitLapisVisualStyleSheet(String customCss) {
  // 取最后一个 BEGIN：若用户自由 CSS 里恰有残缺旧标记，后续新增的完整托管块
  // 仍能独立解析，不会把前面的手写内容一起误吃掉。
  final int begin = customCss.lastIndexOf(lapisVisualCssBeginMarker);
  if (begin < 0) return _lapisVisualAllFreeform(customCss);
  final int end = customCss.indexOf(
    lapisVisualCssEndMarker,
    begin + lapisVisualCssBeginMarker.length,
  );
  if (end < 0) return _lapisVisualAllFreeform(customCss);

  final String managedBody = customCss.substring(
    begin + lapisVisualCssBeginMarker.length,
    end,
  );
  final RegExpMatch? configMatch = RegExp(
    r'/\* HIBIKI-LAPIS-VISUAL-CONFIG (.*?) \*/',
    dotAll: true,
  ).firstMatch(managedBody);
  // fail-safe：区段有成对标记但没有 CONFIG 注释（旧版本残留 / 用户手改坏了）。
  // 宁可把整段当自由 CSS 留着长垃圾，也不能把用户手写内容吞掉。
  // 守卫见 lapis_styling_test.dart『CONFIG 注释缺失时整段原样保留』。
  if (configMatch == null) return _lapisVisualAllFreeform(customCss);

  try {
    final Object? decoded = jsonDecode(configMatch.group(1)!);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('visual config is not an object');
    }
    final Map<LapisVisualField, LapisVisualRule> rules =
        <LapisVisualField, LapisVisualRule>{};
    for (final MapEntry<String, dynamic> entry in decoded.entries) {
      final LapisVisualField? field = LapisVisualField.fromWireName(entry.key);
      final LapisVisualRule? rule = LapisVisualRule.fromJson(entry.value);
      if (field != null && rule != null && !rule.isDefault) {
        rules[field] = rule;
      }
    }
    final int afterEnd = end + lapisVisualCssEndMarker.length;
    final String before =
        _withoutLapisSeparatorSuffix(customCss.substring(0, begin));
    final String after =
        _withoutLapisSeparatorPrefix(customCss.substring(afterEnd));
    // 用户把 CSS 写在托管块之后 = 他要的就是「压过托管块」。记住这个位置，
    // 保存时原样写回。两侧都有内容时统一收到托管块之后——只会让用户的 CSS
    // 更靠后（优先级只升不降），不会把任何一条覆盖降级。
    final bool managedFirst = after.trim().isNotEmpty;
    final String freeform = <String>[
      if (before.trim().isNotEmpty) before,
      if (after.trim().isNotEmpty) after,
    ].join(_lapisVisualBlockSeparator);
    return LapisVisualStyleSheet(
      freeformCss: freeform,
      managedFirst: managedFirst,
      rules: Map<LapisVisualField, LapisVisualRule>.unmodifiable(rules),
    );
  } on FormatException {
    // fail-safe：CONFIG 里的 JSON 坏了（手改 / 旧格式 / 截断）。同上，整段留着。
    // 守卫见 lapis_styling_test.dart『CONFIG JSON 损坏时整段原样保留』。
    return _lapisVisualAllFreeform(customCss);
  }
}

/// 把可视化规则写回自定义 CSS。
///
/// [managedFirst] 由 [splitLapisVisualStyleSheet] 带出（新建时默认 false =
/// 自由 CSS 在前、托管区段在后）。**保存动作不得移动用户 CSS 相对托管区段的
/// 位置**：托管区段整块 `!important`，把用户写在后面的覆盖搬到前面就等于静默
/// 推翻他的改动。自由 CSS 本身逐字节原样写回，首尾空白不再被 trim。
String composeLapisVisualStyleSheet({
  required String freeformCss,
  required Map<LapisVisualField, LapisVisualRule> rules,
  bool managedFirst = false,
}) {
  final Map<String, Object?> config = <String, Object?>{};
  final List<String> cssRules = <String>[];
  for (final LapisVisualField field in LapisVisualField.values) {
    final LapisVisualRule rule = rules[field] ?? const LapisVisualRule();
    if (rule.isDefault) continue;
    config[field.wireName] = rule.toJson();
    cssRules.addAll(_buildLapisVisualFieldCss(field, rule));
  }
  if (config.isEmpty) return freeformCss;
  final String managed = <String>[
    lapisVisualCssBeginMarker,
    '$_lapisVisualConfigPrefix${jsonEncode(config)} */',
    ...cssRules,
    lapisVisualCssEndMarker,
  ].join('\n');
  if (freeformCss.trim().isEmpty) return managed;
  return managedFirst
      ? '$managed$_lapisVisualBlockSeparator$freeformCss'
      : '$freeformCss$_lapisVisualBlockSeparator$managed';
}

List<String> _buildLapisVisualFieldCss(
  LapisVisualField field,
  LapisVisualRule rule,
) {
  final String selector = lapisVisualSelector(field);
  final List<String> declarations = <String>[
    if (rule.bold) '  font-weight: 700 !important;',
    if (rule.alignment != null)
      '  text-align: ${rule.alignment!.cssValue} !important;',
    if (rule.colorHex != null) '  color: ${rule.colorHex} !important;',
    if (rule.lineHeightPercent != null)
      '  line-height: ${(rule.lineHeightPercent! / 100).toStringAsFixed(2)} !important;',
    if (rule.backgroundColorHex != null)
      '  background-color: ${rule.backgroundColorHex} !important;',
    if (rule.borderWidthPx != null) ...<String>[
      '  border-style: solid !important;',
      '  border-width: ${rule.borderWidthPx}px !important;',
    ],
    if (rule.borderColorHex != null)
      '  border-color: ${rule.borderColorHex} !important;',
    if (rule.borderRadiusPx != null)
      '  border-radius: ${rule.borderRadiusPx}px !important;',
    if (rule.paddingPx != null) '  padding: ${rule.paddingPx}px !important;',
    if (rule.marginBlockPx != null)
      '  margin-block: ${rule.marginBlockPx}px !important;',
  ];
  final List<String> result = <String>[];
  if (declarations.isNotEmpty) {
    result.add('$selector {\n${declarations.join('\n')}\n}');
  }
  if (rule.fontScalePercent != 100) {
    final String factor = (rule.fontScalePercent / 100).toStringAsFixed(2);
    for (final MapEntry<String, String> target
        in _lapisVisualFontTargets(field)) {
      result.add(
        '${target.key} {\n'
        '  font-size: calc(${target.value} * $factor) !important;\n'
        '}',
      );
    }
  }
  return result;
}

/// 可视化目标对应的真实 Lapis selector。
///
/// **判据是 Hibiki 自产卡的真实 DOM，不是预览里好看的 mock。** 释义字段由
/// `popup.js` 的 `constructGlossaryHtml` / `constructSingleGlossaryHtml` 产出，
/// 形状恒为：
/// `#glossaries > div.yomitan-glossary > ol > li[data-dictionary] > (i + span)`
/// （`#primary` 同形）。因此：
/// * `#primary > div` / `#glossaries > div` 命中的是 `.yomitan-glossary` **整块
///   外壳**，不是单条词典条目 —— 条目锚点只能是 `li[data-dictionary]`；
/// * `#primary > div > i` 是 Yomitan 老式「单词典无 ol」格式的路径，Hibiki 产物
///   永远匹配不到（`<i>` 在 `li` 里）；
/// * `li[data-details]` 是 JPMN 导入卡的特征（Lapis 模板脚本据此识别），Hibiki
///   从不产出；
/// * `dict-group__*` 全部只存在于 vendored Lapis CSS 与旧预览 mock 中，产出侧
///   零处 —— 「词性」在真实产物里是拼进词典名那个 `<i>` 的纯文本
///   （`(vt, 明鏡国語辞典)`），**没有独立元素可选**，所以不提供该字段。
///
/// 正面例句：Hibiki 卡型默认 `IsWordAndSentenceCard`，正面句子落在 `#hint`，
/// 只打 `.front-sentence` 会漏掉唯一的实际形态。
///
/// 守卫见 `lapis_styling_test.dart`『每个可视字段绑定真实 Lapis selector 与字号
/// 变量』——selector 与字号变量逐字面量登记，改错一个即红。
String lapisVisualSelector(LapisVisualField field) => switch (field) {
      LapisVisualField.expression => '.front-vocab, .vocab',
      LapisVisualField.reading => '.pitch',
      LapisVisualField.sentence =>
        '#hint, .front-sentence, .sentence, .sentence-alt',
      LapisVisualField.definitionInfo => '.def-info',
      LapisVisualField.definitionBox => '.main-def',
      LapisVisualField.definitionContent => '.main-def > .definition > div',
      LapisVisualField.selectedDefinition => '#selection',
      LapisVisualField.primaryDefinition => '#primary',
      LapisVisualField.glossaries => '#glossaries',
      LapisVisualField.dictionaryEntry =>
        '#primary li[data-dictionary], #glossaries li[data-dictionary]',
      LapisVisualField.dictionaryName => '.definition li[data-dictionary] > i',
      LapisVisualField.definitionExample =>
        '.definition [data-sc-content|="example-sentence"]',
    };

List<MapEntry<String, String>> _lapisVisualFontTargets(
  LapisVisualField field,
) =>
    switch (field) {
      LapisVisualField.expression => const <MapEntry<String, String>>[
          MapEntry<String, String>('.front-vocab', 'var(--vocab-font-size)'),
          MapEntry<String, String>('.vocab', 'var(--back-vocab-font-size)'),
        ],
      LapisVisualField.reading => const <MapEntry<String, String>>[
          MapEntry<String, String>('.pitch', 'var(--info-font-size)'),
        ],
      LapisVisualField.sentence => const <MapEntry<String, String>>[
          MapEntry<String, String>('#hint', 'var(--hint-font-size)'),
          MapEntry<String, String>(
            '.front-sentence',
            'var(--sentence-font-size)',
          ),
          MapEntry<String, String>(
            '.sentence, .sentence-alt',
            'var(--back-sentence-font-size)',
          ),
        ],
      LapisVisualField.definitionInfo => const <MapEntry<String, String>>[
          MapEntry<String, String>('.def-info', '0.9rem'),
        ],
      LapisVisualField.definitionBox => const <MapEntry<String, String>>[
          MapEntry<String, String>('.main-def', 'var(--main-def-size)'),
        ],
      LapisVisualField.definitionContent => const <MapEntry<String, String>>[
          MapEntry<String, String>(
            '.main-def > .definition > div',
            'var(--main-def-size)',
          ),
        ],
      LapisVisualField.selectedDefinition => const <MapEntry<String, String>>[
          MapEntry<String, String>('#selection', 'var(--main-def-size)'),
        ],
      LapisVisualField.primaryDefinition => const <MapEntry<String, String>>[
          MapEntry<String, String>('#primary', 'var(--main-def-size)'),
        ],
      LapisVisualField.glossaries => const <MapEntry<String, String>>[
          MapEntry<String, String>('#glossaries', 'var(--main-def-size)'),
        ],
      LapisVisualField.dictionaryEntry => <MapEntry<String, String>>[
          MapEntry<String, String>(
            lapisVisualSelector(LapisVisualField.dictionaryEntry),
            'var(--main-def-size)',
          ),
        ],
      LapisVisualField.dictionaryName => <MapEntry<String, String>>[
          MapEntry<String, String>(
            lapisVisualSelector(LapisVisualField.dictionaryName),
            'var(--main-def-size)',
          ),
        ],
      LapisVisualField.definitionExample => <MapEntry<String, String>>[
          MapEntry<String, String>(
            lapisVisualSelector(LapisVisualField.definitionExample),
            'var(--main-def-size)',
          ),
        ],
    };

bool _isCssHexColor(String value) =>
    RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value);

String? _normalizedOptionalCssHex(Object? value) =>
    value is String && _isCssHexColor(value) ? value.toUpperCase() : null;

int? _clampedOptionalInt(
  Object? value, {
  required int min,
  required int max,
}) =>
    value is int ? value.clamp(min, max).toInt() : null;

/// 从 vendored Lapis CSS 里提取全部字号变量并按 [percent]（百分比，100 = 原样）
/// 缩放，产出一个 `:root` 覆写块。基准值直接解析自 [LapisNoteType.css]（单一
/// 真相源），vendored 版本升级后无需改这里。[percent] == 100 或未解析到任何变量
/// 时返回空串。
///
/// 上游 Lapis 的字号变量命名**不统一**：多数叫 `--pc-*-font-size` /
/// `--mobile-*-font-size`，但释义字号叫 `--pc-main-def-size` /
/// `--mobile-main-def-size`（没有 `font-` 中缀）。所以判据只是「以 `-size`
/// 结尾」（`[a-z-]*` already 吃掉 `font-`，不需要额外分组）——只认 `font-size`
/// 会静默漏掉释义字号，界面缩放对释义不生效，与「Scales every Lapis font size」
/// 的文案不符（本函数原始缺陷）。
/// 守卫见 `lapis_styling_test.dart`：断言 vendored CSS 里**每一个** px 取值的
/// `--pc-*` / `--mobile-*` 变量都被本函数覆盖，vendored 升级新增变量即打红。
///
/// **上游同步须留意的前瞻风险**：本函数 + 守卫一起把「`pc-`/`mobile-` 前缀 +
/// px 取值 == 字号」制度化了。上游若新增 `--pc-main-picture-size: 240px` 这类
/// **非字号**变量，正则会误伤把它一起缩放，守卫还会反过来强制要求它被纳入。
/// 同步 vendored Lapis 时必须人工过一遍新增的 `--pc-*` / `--mobile-*` px 变量：
/// 真是字号就放行，不是字号就得给本函数加排除表，别顺手把守卫改绿。
String buildLapisFontScaleCss(int percent) {
  if (percent == 100) return '';
  final List<String> lines = <String>[
    for (final MapEntry<String, int> e in lapisBaseFontSizes())
      '  --${e.key}: ${(e.value * percent / 100).round().clamp(1, 4096)}px;',
  ];
  if (lines.isEmpty) return '';
  return ':root {\n${lines.join('\n')}\n}';
}

List<MapEntry<String, int>>? _cachedLapisBaseFontSizes;

/// vendored Lapis CSS 里全部 px 取值的 `--pc-*` / `--mobile-*` 变量及其基准值，
/// 按首次出现顺序去重。判据与 [buildLapisFontScaleCss] 文档一致（以 `-size`
/// 结尾）。解析一次缓存——[buildLapisFontScaleCss] 与
/// [splitLapisUserSectionBody] 共用同一真相源，且反解要穷举上百个百分比，
/// 每次重跑正则扫全量 CSS 没必要。
List<MapEntry<String, int>> lapisBaseFontSizes() {
  final List<MapEntry<String, int>>? cached = _cachedLapisBaseFontSizes;
  if (cached != null) return cached;
  final RegExp pattern = RegExp(r'--((?:pc|mobile)-[a-z-]*size):\s*(\d+)px');
  final List<MapEntry<String, int>> sizes = <MapEntry<String, int>>[];
  final Set<String> seen = <String>{};
  for (final RegExpMatch m in pattern.allMatches(LapisNoteType.css)) {
    final String name = m.group(1)!;
    if (!seen.add(name)) continue;
    sizes.add(MapEntry<String, int>(name, int.parse(m.group(2)!)));
  }
  return _cachedLapisBaseFontSizes =
      List<MapEntry<String, int>>.unmodifiable(sizes);
}

/// 设置页字号选择器提供的百分比档位（单一真相源）。[splitLapisUserSectionBody]
/// 反解时优先命中这些档位，避免相邻百分比因四舍五入产生同一份 CSS 时把选择器
/// 显示成一个档位表里根本没有的值。
const List<int> kLapisFontScalePresets = <int>[80, 90, 100, 110, 125, 150];

/// 反解的穷举范围（含端点）。选择器只给 [kLapisFontScalePresets]，但备份可能
/// 来自别的档位表或更早版本，范围放宽一点不增加实际成本（[lapisBaseFontSizes]
/// 已缓存）。
const int kLapisFontScaleMinPercent = 1;
const int kLapisFontScaleMaxPercent = 400;

/// 用户区段正文的拆分结果：Hibiki 生成的字号缩放块（还原成百分比）与其余
/// 用户自由 CSS。
class LapisUserSectionSplit {
  const LapisUserSectionSplit({
    required this.fontScalePercent,
    required this.customCss,
  });

  /// 反解出的字号百分比；正文开头不是 Hibiki 生成的缩放块时 = 100。
  final int fontScalePercent;

  /// 剥掉缩放块之后的用户自由 CSS（已 trim）。
  final String customCss;
}

/// 把用户区段正文拆回「字号百分比 + 自由 CSS」——[buildLapisUserSectionBody]
/// 的逆运算。
///
/// **为什么必须反解**（PR#457 审查 §10-2，用户拍板方案甲）：从备份恢复时若把
/// 整段正文（含 Hibiki 生成的缩放块）原样塞进 `lapisCustomCss` 并把百分比归
/// 100，之后用户再调字号，新缩放块排在正文**之前**、旧缩放块排在**之后**，
/// 两块特异性相同 → 后者胜出 → 字号选择器肉眼零效果。反解之后选择器显示的就是
/// 备份当时的字号，且 `lapisCustomCss` 里不再残留缩放块，后续调节立即生效。
///
/// 判据：正文开头逐字节等于某个 `buildLapisFontScaleCss(p)`，且其后要么到头、
/// 要么紧跟空白。命中不了（用户在 Anki 里手改过缩放块、或自己写的 CSS 排在
/// 前面）就返回 `(100, 整段正文)`——与修复前行为一致，不猜。
///
/// 相邻百分比可能因四舍五入产出**逐字节相同**的缩放块（基准值都很小时）。这种
/// 情况两个百分比不可区分，渲染结果也完全一样；先扫 [kLapisFontScalePresets]
/// 保证选择器显示的是档位里真有的值，再按升序穷举。
LapisUserSectionSplit splitLapisUserSectionBody(String body) {
  final String trimmed = body.trim();
  if (trimmed.isEmpty) {
    return const LapisUserSectionSplit(fontScalePercent: 100, customCss: '');
  }
  for (final int percent in <int>[
    ...kLapisFontScalePresets,
    for (int p = kLapisFontScaleMinPercent; p <= kLapisFontScaleMaxPercent; p++)
      p,
  ]) {
    if (percent == 100) continue;
    final String scale = buildLapisFontScaleCss(percent);
    if (scale.isEmpty || !trimmed.startsWith(scale)) continue;
    final String rest = trimmed.substring(scale.length);
    // 缩放块后面必须是区段边界（到头或空白），否则只是恰好前缀相同。
    if (rest.isNotEmpty && !RegExp(r'^\s').hasMatch(rest)) continue;
    return LapisUserSectionSplit(
      fontScalePercent: percent,
      customCss: rest.trim(),
    );
  }
  return LapisUserSectionSplit(fontScalePercent: 100, customCss: trimmed);
}

/// 组合用户区段正文：字号缩放覆写 + 自由 CSS。两者皆空时返回空串
/// （= 不产出用户区段）。
String buildLapisUserSectionBody({
  required int fontScalePercent,
  required String customCss,
}) {
  final String scale = buildLapisFontScaleCss(fontScalePercent);
  final String custom = customCss.trim();
  if (scale.isEmpty && custom.isEmpty) return '';
  return <String>[
    if (scale.isNotEmpty) scale,
    if (custom.isNotEmpty) custom,
  ].join('\n\n');
}

/// 组合最终推送到 Anki 的完整 Lapis styling：
/// [LapisNoteType.template].css（vendored + Hibiki delta）+ 用户区段。
/// 无客制化时逐字节等于现行 `createModel` 落下的出厂 CSS（零破坏）。
String composeLapisCss({
  required int fontScalePercent,
  required String customCss,
}) {
  final String base = LapisNoteType.template.css;
  final String body = buildLapisUserSectionBody(
    fontScalePercent: fontScalePercent,
    customCss: customCss,
  );
  if (body.isEmpty) return base;
  return '$base\n$lapisUserCssBeginMarker\n$body\n$lapisUserCssEndMarker\n';
}

/// 从一份完整 styling 里提取用户区段正文（标记之间的内容，已 trim）。
/// 没有成对标记时返回 null——调用方（备份恢复）据此把 Hibiki 侧客制化状态
/// 清空，而不是猜。
String? extractLapisUserSectionBody(String css) {
  final int begin = css.indexOf(lapisUserCssBeginMarker);
  if (begin < 0) return null;
  final int bodyStart = begin + lapisUserCssBeginMarker.length;
  final int end = css.indexOf(lapisUserCssEndMarker, bodyStart);
  if (end < 0) return null;
  return css.substring(bodyStart, end).trim();
}

/// 比较用 CSS 规范化：统一换行 + 去首尾空白。Anki 端存取可能改变行尾/尾部
/// 空白，不做规范化会把等价内容误判成外来手改。
String normalizeCssForCompare(String css) =>
    css.replaceAll('\r\n', '\n').trim();

/// 规范化后 CSS 的 sha256（hex）。用作「上次应用的 styling」指纹持久化。
String lapisCssSha256(String css) =>
    sha256.convert(utf8.encode(normalizeCssForCompare(css))).toString();

/// Hibiki 当前**出厂基线**（vendored Lapis + Hibiki delta）的指纹。
/// 启动自动迁移用它判断「基线是不是真的变了」。
String get currentLapisBaselineSha =>
    lapisCssSha256(LapisNoteType.template.css);

/// Anki 端 [ankiCss] 是否携带当前出厂基线。
///
/// [composeLapisCss] 的产物永远是「基线 + 可选用户区段」，所以「以基线开头」
/// 就等价于「Anki 上的内容建立在当前基线之上」。手改过头部的内容不满足——那
/// 属于 [LapisStylingDecision.foreignEdit]，本来也不会被自动迁移碰。
bool ankiCssCarriesCurrentLapisBaseline(String ankiCss) =>
    normalizeCssForCompare(ankiCss)
        .startsWith(normalizeCssForCompare(LapisNoteType.template.css));

/// 启动自动迁移的**基线闸门**（PR#457 审查 §10-3，用户拍板方案甲）。
///
/// 语义：「迁移」只该在 Hibiki 自己的基线变了时发生。用户改了字号/自定义 CSS
/// 却没点「应用样式到 Anki」，不构成迁移理由——**Apply 是用户内容写进 Anki 的
/// 唯一闸门**。
///
/// [migratedBaselineSha] == null（本机从未记录过，例如刚从旧版升级上来）时无法
/// 直接比对，改用 Anki 端实际内容判断：Anki 已经建立在当前基线之上 → 没有要
/// 迁移的东西；不是 → 基线确实落后，照迁。这样既不会因为「没有历史记录」就把
/// 一次真实的基线升级吞掉，也不会拿它当借口去推用户没确认的客制化。
bool shouldAutoMigrateLapisBaseline({
  required String? migratedBaselineSha,
  required String ankiCss,
}) =>
    migratedBaselineSha == null
        ? !ankiCssCarriesCurrentLapisBaseline(ankiCss)
        : migratedBaselineSha != currentLapisBaselineSha;

/// 对 Anki 端现有 Lapis styling 的处置判定。
enum LapisStylingDecision {
  /// 与期望完全一致，无需动作。
  upToDate,

  /// 可安全覆写：Anki 端内容是 Hibiki 已知的自有产物（上次应用的指纹，或
  /// 从未被动过的出厂基线）。自动迁移只在此态下写入。
  safeUpdate,

  /// Anki 端内容来历不明（用户手改过）：自动迁移不得写入，只有用户显式
  /// 确认的「应用」可以（应用前强制自动备份）。
  foreignEdit,
}

/// 判定 Anki 端现有 [ankiCss] 相对期望 [expectedCss] 的处置方式。
///
/// [lastAppliedSha] 是 Hibiki 上次成功推送的 styling 指纹
/// （[lapisCssSha256]），null = 本机从未推送过。
LapisStylingDecision decideLapisStylingAction({
  required String ankiCss,
  required String expectedCss,
  required String? lastAppliedSha,
}) {
  final String anki = normalizeCssForCompare(ankiCss);
  if (anki == normalizeCssForCompare(expectedCss)) {
    return LapisStylingDecision.upToDate;
  }
  if (lastAppliedSha != null && lapisCssSha256(anki) == lastAppliedSha) {
    return LapisStylingDecision.safeUpdate;
  }
  // 出厂基线（用户从未动过）：纯 vendored CSS（上游原版 Lapis），或
  // vendored + Hibiki delta（现行 createModel 落下的出厂态）。
  final Set<String> pristine = <String>{
    normalizeCssForCompare(LapisNoteType.css),
    normalizeCssForCompare(LapisNoteType.template.css),
  };
  if (pristine.contains(anki)) return LapisStylingDecision.safeUpdate;
  return LapisStylingDecision.foreignEdit;
}

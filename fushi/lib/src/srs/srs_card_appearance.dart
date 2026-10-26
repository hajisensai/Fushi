/// 复习卡面的外观设置（「Fushi 卡片」模板的可视化定制）与它到卡面的注入形式。
///
/// 外观不改模板正文：全部变成宿主注入的 CSS 变量（`--fushi-srs-*`）与 `.card` 上的宿主类名
/// （`fushi-srs-*`），模板（packages/fushi_anki/templates/fushi_card/）按它们取值，没注入时
/// 用自己的默认值（导出到 Anki 也能看）。注入只走外壳的 `__fushiSrsSetTheme`：换外观不重跑
/// 卡片脚本、不重排卡片（见 srs_card_face.dart）。
///
/// 存储：一个 JSON 偏好 `srs_card_appearance`（按 profile，随 Profile 快照 / 备份走，不是
/// 设备本地键）。字体不在这里：卡面字体是统一字体库的「复习卡片」用途
/// （`FontTarget.srsCard`），导入 / 下载 / 系统字体 / 同步都走字体库。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/srs/srs_card_media.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';

/// 卡面配色来源。
enum SrsCardColorSource {
  /// 跟随 app 主题（ColorScheme 原样注入）。
  app('app'),

  /// 自定义强调色：以它为种子生成一套 ColorScheme（明暗跟随 app）。
  custom('custom');

  const SrsCardColorSource(this.wire);

  final String wire;

  static SrsCardColorSource fromWire(Object? wire) => values.firstWhere(
    (SrsCardColorSource v) => v.wire == wire,
    orElse: () => SrsCardColorSource.app,
  );
}

/// 布局密度（间距与内边距的档位）。
enum SrsCardDensity {
  compact('compact'),
  standard('standard'),
  comfortable('comfortable');

  const SrsCardDensity(this.wire);

  final String wire;

  static SrsCardDensity fromWire(Object? wire) => values.firstWhere(
    (SrsCardDensity v) => v.wire == wire,
    orElse: () => SrsCardDensity.standard,
  );
}

/// 卡面外观设置。默认值 = 模板默认外观（不注入任何覆盖时的样子）。
@immutable
class SrsCardAppearance {
  const SrsCardAppearance({
    this.textScale = 1.0,
    this.termScale = 1.0,
    this.lineSpacing = 1.0,
    this.colorSource = SrsCardColorSource.app,
    this.customAccent = 0xFF386A58,
    this.density = SrsCardDensity.standard,
    this.dictUnified = true,
    this.showPicture = true,
    this.showTranslation = true,
    this.showFrequency = true,
    this.showSource = true,
    this.glossaryExpanded = false,
    this.frontReading = false,
    this.frontFrequency = false,
    this.sentenceFurigana = false,
    this.compactPhone = true,
    this.designSkin = true,
    this.aggregateFrequency = true,
  });

  /// 字号缩放的取值范围（正文 / 词条 / 行距共用夹取）。
  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.4;
  static const double minTermScale = 0.75;
  static const double maxTermScale = 1.35;
  static const double minLineSpacing = 0.85;
  static const double maxLineSpacing = 1.3;

  /// 正文（例句、释义、读音）字号倍率。
  final double textScale;

  /// 词条（正反面大字）字号倍率。
  final double termScale;

  /// 行距倍率（乘在模板各区块的基准行高上）。
  final double lineSpacing;

  final SrsCardColorSource colorSource;

  /// 自定义强调色（ARGB），[colorSource] 为 custom 时生效。
  final int customAccent;

  final SrsCardDensity density;

  /// 统一词典样式（M3E）：把各词典自带的颜色按语义换成卡面配色。
  final bool dictUnified;

  final bool showPicture;
  final bool showTranslation;
  final bool showFrequency;
  final bool showSource;

  /// 「全部释义」默认展开（关 = 只展开主释义，其余收在「全部释义」里）。
  final bool glossaryExpanded;

  /// 正面显示读音与音调。
  final bool frontReading;

  /// 正面显示词频序位。
  final bool frontFrequency;

  /// 例句注音常显（关 = 悬停 / 点按时显示）。
  final bool sentenceFurigana;

  /// 手机精简背面：窄屏时长主释义收到约半屏（点「展开全文」看全）。关掉 = 主释义
  /// 全文。宽屏不受影响。「全部释义」里的词典两种都是与查词弹窗同形的逐部折叠卡。
  final bool compactPhone;

  /// 其它卡片类型（Anki 导入牌组、Lapis、用户自建）跟随设计系统：开 = 用当前设计系统
  /// （MD3 = M3E 色板与形状令牌，Apple = iOS 系统样式）覆盖模板的外观类样式（底色、边框、
  /// 圆角、文字 / 链接颜色、字体），布局与内容不动；关 = 模板原样渲染、零注入
  /// （见 srs_card_design_skin.dart）。内置 Fushi 卡片本身就按设计系统画，不受它影响。
  ///
  /// 默认开：判定只换中性色（纸底、灰框、黑灰字），承载语义的有彩色原样保留，绝大多数牌组
  /// 开着只会更协调；个别依赖整页配色的牌组可在外观页 / 复习页 ⋯ 里关掉。
  final bool designSkin;

  /// 词频按聚合（调和平均）显示，否则按词典列明细。**不是卡面自己的设置**：跟随查词的
  /// 「词频聚合」（偏好 `harmonic_frequency`，由 `AppModel.srsCardAppearance` 每次读时
  /// 叠上），所以不进 [toJson] / 不从 JSON 读，只参与相等判断（切换后卡面要重建）。
  final bool aggregateFrequency;

  SrsCardAppearance copyWith({
    double? textScale,
    double? termScale,
    double? lineSpacing,
    SrsCardColorSource? colorSource,
    int? customAccent,
    SrsCardDensity? density,
    bool? dictUnified,
    bool? showPicture,
    bool? showTranslation,
    bool? showFrequency,
    bool? showSource,
    bool? glossaryExpanded,
    bool? frontReading,
    bool? frontFrequency,
    bool? sentenceFurigana,
    bool? compactPhone,
    bool? designSkin,
    bool? aggregateFrequency,
  }) => SrsCardAppearance(
    textScale: textScale ?? this.textScale,
    termScale: termScale ?? this.termScale,
    lineSpacing: lineSpacing ?? this.lineSpacing,
    colorSource: colorSource ?? this.colorSource,
    customAccent: customAccent ?? this.customAccent,
    density: density ?? this.density,
    dictUnified: dictUnified ?? this.dictUnified,
    showPicture: showPicture ?? this.showPicture,
    showTranslation: showTranslation ?? this.showTranslation,
    showFrequency: showFrequency ?? this.showFrequency,
    showSource: showSource ?? this.showSource,
    glossaryExpanded: glossaryExpanded ?? this.glossaryExpanded,
    frontReading: frontReading ?? this.frontReading,
    frontFrequency: frontFrequency ?? this.frontFrequency,
    sentenceFurigana: sentenceFurigana ?? this.sentenceFurigana,
    compactPhone: compactPhone ?? this.compactPhone,
    designSkin: designSkin ?? this.designSkin,
    aggregateFrequency: aggregateFrequency ?? this.aggregateFrequency,
  );

  static double _num(Object? v, double fallback, double min, double max) =>
      v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;

  static bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;

  /// 从偏好 JSON 读；坏值 / 缺项一律按默认值，绝不抛。
  factory SrsCardAppearance.fromJson(Object? json) {
    if (json is! Map) return const SrsCardAppearance();
    const SrsCardAppearance d = SrsCardAppearance();
    final Object? accent = json['customAccent'];
    return SrsCardAppearance(
      textScale: _num(
        json['textScale'],
        d.textScale,
        minTextScale,
        maxTextScale,
      ),
      termScale: _num(
        json['termScale'],
        d.termScale,
        minTermScale,
        maxTermScale,
      ),
      lineSpacing: _num(
        json['lineSpacing'],
        d.lineSpacing,
        minLineSpacing,
        maxLineSpacing,
      ),
      colorSource: SrsCardColorSource.fromWire(json['colorSource']),
      customAccent: accent is int ? accent : d.customAccent,
      density: SrsCardDensity.fromWire(json['density']),
      dictUnified: _bool(json['dictUnified'], d.dictUnified),
      showPicture: _bool(json['showPicture'], d.showPicture),
      showTranslation: _bool(json['showTranslation'], d.showTranslation),
      showFrequency: _bool(json['showFrequency'], d.showFrequency),
      showSource: _bool(json['showSource'], d.showSource),
      glossaryExpanded: _bool(json['glossaryExpanded'], d.glossaryExpanded),
      frontReading: _bool(json['frontReading'], d.frontReading),
      frontFrequency: _bool(json['frontFrequency'], d.frontFrequency),
      sentenceFurigana: _bool(json['sentenceFurigana'], d.sentenceFurigana),
      compactPhone: _bool(json['compactPhone'], d.compactPhone),
      designSkin: _bool(json['designSkin'], d.designSkin),
    );
  }

  /// 从偏好字符串读（空串 / 坏 JSON = 默认值）。
  static SrsCardAppearance decode(String raw) {
    if (raw.isEmpty) return const SrsCardAppearance();
    try {
      return SrsCardAppearance.fromJson(jsonDecode(raw));
    } on FormatException {
      return const SrsCardAppearance();
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'textScale': textScale,
    'termScale': termScale,
    'lineSpacing': lineSpacing,
    'colorSource': colorSource.wire,
    'customAccent': customAccent,
    'density': density.wire,
    'dictUnified': dictUnified,
    'showPicture': showPicture,
    'showTranslation': showTranslation,
    'showFrequency': showFrequency,
    'showSource': showSource,
    'glossaryExpanded': glossaryExpanded,
    'frontReading': frontReading,
    'frontFrequency': frontFrequency,
    'sentenceFurigana': sentenceFurigana,
    'compactPhone': compactPhone,
    'designSkin': designSkin,
  };

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is SrsCardAppearance &&
      encode() == other.encode() &&
      aggregateFrequency == other.aggregateFrequency;

  @override
  int get hashCode => Object.hash(encode(), aggregateFrequency);
}

/// 卡面里由宿主按界面语言注入的标签文字。
@immutable
class SrsCardLabels {
  const SrsCardLabels({
    required this.allDefinitions,
    required this.frequency,
    required this.source,
    this.showMore = 'Show more',
  });

  final String allDefinitions;
  final String frequency;
  final String source;

  /// 窄屏长释义收起后的「展开全文」按钮。
  final String showMore;
}

// ---------------------------------------------------------------- 注入形式

/// 卡面配色：由 ColorScheme 角色一一映射到 `--fushi-srs-*`（命名对齐模板的令牌表）；
/// 表面三档取当前设计系统的表面色阶（[SrsCardTokens.surface1] 等：MD3 = M3 表面容器、
/// Apple = 分组背景）。
@visibleForTesting
Map<String, Color> srsCardPaletteVars(
  ColorScheme s,
  SrsCardTokens tokens, {
  required bool dark,
}) => <String, Color>{
  '--fushi-srs-bg': s.surface,
  '--fushi-srs-fg': s.onSurface,
  '--fushi-srs-fg-muted': s.onSurfaceVariant,
  '--fushi-srs-accent': s.primary,
  '--fushi-srs-on-accent': s.onPrimary,
  '--fushi-srs-accent-container': s.primaryContainer,
  '--fushi-srs-on-accent-container': s.onPrimaryContainer,
  '--fushi-srs-secondary-container': s.secondaryContainer,
  '--fushi-srs-on-secondary-container': s.onSecondaryContainer,
  '--fushi-srs-surface-container': tokens.surface1(s),
  '--fushi-srs-surface-container-high': tokens.surface2(s),
  '--fushi-srs-surface-container-highest': tokens.surface3(s),
  '--fushi-srs-outline': s.outline,
  '--fushi-srs-outline-variant': s.outlineVariant,
  '--fushi-srs-highlight': s.primary.withValues(alpha: dark ? 0.34 : 0.26),
};

/// 外观实际用的 ColorScheme：跟随 app 时就是 [appScheme]，自定义强调色时以它为种子生成。
ColorScheme srsCardColorScheme(SrsCardAppearance a, ColorScheme appScheme) =>
    a.colorSource == SrsCardColorSource.custom
    ? ColorScheme.fromSeed(
        seedColor: Color(a.customAccent),
        brightness: appScheme.brightness,
      )
    : appScheme;

/// 颜色 → CSS 值（不透明 `#rrggbb`，否则 `rgba()`）。
String srsCardCssColor(Color c) {
  final int argb = c.toARGB32();
  final int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  final int alpha = (argb >> 24) & 0xFF;
  if (alpha == 0xFF) {
    return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }
  return 'rgba($r,$g,$b,${(alpha / 255).toStringAsFixed(3)})';
}

/// CSS 字符串字面量（双引号；转义反斜杠、引号与换行）。
String srsCssString(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\A ')}"';

String _fmt(double v) =>
    v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');

/// 模板默认字体链（与 styling.css 里 `--fc-font-*` 的默认值同一份；注入用户字体时把它们
/// 接在后面，选的字体缺字时照常回落）。
const String kSrsCardDefaultFontJa =
    '"Hiragino Sans", "Hiragino Kaku Gothic ProN", "Yu Gothic UI", "Yu Gothic", '
    '"Meiryo", "Noto Sans CJK JP", "Noto Sans JP", sans-serif';
const String kSrsCardDefaultFontZh =
    '"PingFang SC", "Heiti SC", "Microsoft YaHei UI", "Microsoft YaHei", '
    '"Noto Sans CJK SC", "Noto Sans SC", sans-serif';
const String kSrsCardDefaultFontUi =
    'system-ui, -apple-system, "Segoe UI", "Roboto", $kSrsCardDefaultFontJa';

/// 卡面字体文件的 URL 路径前缀（与媒体同域：`https://srs.local/fonts/…` 或
/// `fushi-srs://srs.local/fonts/…`）。
const String kSrsFontPath = '/fonts/';

/// 字体文件 → 卡面虚拟域上的 URL（路径整段 percent-encode）。
String srsCardFontUrl(String path, {required bool customScheme}) =>
    '${customScheme ? kSrsMediaScheme : 'https'}://$kSrsMediaHost$kSrsFontPath'
    '${Uri.encodeComponent(path)}';

/// 拦截到的 URL 是不是卡面字体请求；是则返回解码后的本机路径，否则 null。
String? srsFontPathFromUrl(Uri url) {
  if (url.host != kSrsMediaHost) return null;
  if (url.scheme != 'https' && url.scheme != kSrsMediaScheme) return null;
  if (!url.path.startsWith(kSrsFontPath)) return null;
  final String rest = url.path.substring(kSrsFontPath.length);
  if (rest.isEmpty) return null;
  try {
    return Uri.decodeComponent(rest);
  } on ArgumentError {
    return null;
  }
}

/// 卡面字体链里导入字体文件的路径（规范化；拦截器的白名单）。只认启用的、落在
/// [fontRoot]（字体库目录）内的文件。
Set<String> srsCardFontWhitelist(
  Iterable<Map<String, dynamic>> fonts, {
  required String? fontRoot,
}) {
  if (fontRoot == null) return const <String>{};
  return <String>{
    for (final Map<String, dynamic> f in fonts)
      if ((f['enabled'] as bool? ?? true) && f['path'] is String)
        ?ReaderCustomFontCss.safeFontPath(
          f['path'] as String,
          allowedRoots: <String>[fontRoot],
        ),
  }.map(p.canonicalize).toSet();
}

/// 外观 → 注入外壳主题样式里的 CSS（`:root` 变量 + 字体库字体的 @font-face）。
///
/// [fonts] 是字体库里「复习卡片」用途（`FontTarget.srsCard`）的有序字体链
/// （`[{name, path, enabled}]`，与阅读器正文同一机制）：整链排在模板默认的日文 /
/// 中文 / 界面字体链之前，浏览器按字形逐个回落（西文字体放在前面就只作用于拉丁字母）。
/// [fontUrl] 把字体文件路径换成卡面虚拟域 URL；[fontRoot] 之外的文件不出 @font-face。
///
/// [tokens] 是当前设计系统的卡面令牌（[SrsCardTokens]）：表面色阶、圆角、字阶倍率与
/// 间距都从它生成，切换设计系统时卡面跟着变。
String srsCardAppearanceCss({
  required SrsCardAppearance appearance,
  required ColorScheme appScheme,
  required SrsCardTokens tokens,
  required bool dark,
  required SrsCardLabels labels,
  required String Function(String path) fontUrl,
  Iterable<Map<String, dynamic>> fonts = const <Map<String, dynamic>>[],
  String? fontRoot,
}) {
  final SrsCardAppearance a = appearance;
  // 没有字体目录时只认系统字体（不带路径的条目）：build 在根为空时不做目录校验。
  final ({String fontFamily, String fontFaces}) chain =
      ReaderCustomFontCss.build(
        fontRoot == null
            ? fonts.where((Map<String, dynamic> f) => f['path'] == null)
            : fonts,
        allowedDirectories: <String>[?fontRoot],
        fontUrlBuilder: fontUrl,
      );
  String withChain(String defaults) =>
      chain.fontFamily.isEmpty ? defaults : '${chain.fontFamily}, $defaults';

  final StringBuffer vars = StringBuffer(':root{');
  srsCardPaletteVars(
    srsCardColorScheme(a, appScheme),
    tokens,
    dark: dark,
  ).forEach(
    (String name, Color c) => vars.write('$name:${srsCardCssColor(c)};'),
  );
  srsCardShapeVars(
    tokens,
  ).forEach((String name, double px) => vars.write('$name:${_fmt(px)}px;'));
  if (chain.fontFamily.isNotEmpty) {
    final String zh = withChain(kSrsCardDefaultFontZh);
    vars
      ..write('--fushi-srs-font-ja:${withChain(kSrsCardDefaultFontJa)};')
      ..write('--fushi-srs-font-zh:$zh;')
      ..write('--fushi-srs-font-zh-hant:$zh;')
      ..write('--fushi-srs-font-ui:${withChain(kSrsCardDefaultFontUi)};');
  }
  vars
    ..write(
      '--fushi-srs-text-scale:'
      '${_fmt(a.textScale * tokens.templateTextRatio)};',
    )
    ..write(
      '--fushi-srs-term-scale:'
      '${_fmt(a.termScale * tokens.templateTermRatio)};',
    )
    ..write('--fushi-srs-line-scale:${_fmt(a.lineSpacing)};')
    ..write('--fushi-srs-label-more:${srsCssString(labels.allDefinitions)};')
    ..write('--fushi-srs-label-frequency:${srsCssString(labels.frequency)};')
    ..write('--fushi-srs-label-source:${srsCssString(labels.source)};')
    ..write('--fushi-srs-label-show-more:${srsCssString(labels.showMore)};')
    ..write('}');
  // 区块间距 / 内边距按设计系统间距令牌与密度档生成。模板把它们写在 `.card` 与
  // `.card.fushi-srs-density-*` 上（不读宿主变量），这里用更高优先级的选择器覆盖。
  final String spacing =
      ':root .card.card{--fc-gap:${_fmt(tokens.gap(a.density))}px;'
      '--fc-pad:${_fmt(tokens.pad(a.density))}px;}';
  return '${chain.fontFaces}$vars$spacing';
}

/// 卡面圆角：模板 `--fc-radius` / `--fc-radius-small` / `--fc-radius-inner` 由当前设计系统的
/// 形状令牌生成（MD3 = M3E 卡 / 小件档，Apple = inset grouped / 内嵌块）。
@visibleForTesting
Map<String, double> srsCardShapeVars(SrsCardTokens tokens) => <String, double>{
  '--fushi-srs-radius': tokens.radius,
  '--fushi-srs-radius-small': tokens.radiusSmall,
  '--fushi-srs-radius-inner': tokens.radiusInner,
};

/// 外观 → `.card` 上的宿主类名（空格分隔，不含 `card` 本身与夜间类名）。
String srsCardAppearanceClasses(SrsCardAppearance a) => <String>[
  if (a.frontReading) 'fushi-srs-front-reading',
  if (a.frontFrequency) 'fushi-srs-front-freq',
  if (a.sentenceFurigana) 'fushi-srs-sentence-furigana',
  if (a.glossaryExpanded) 'fushi-srs-gloss-expanded',
  if (a.dictUnified) 'fushi-srs-dict-unified',
  if (!a.showPicture) 'fushi-srs-hide-picture',
  if (!a.showTranslation) 'fushi-srs-hide-translation',
  if (!a.showFrequency) 'fushi-srs-hide-frequency',
  if (a.aggregateFrequency) 'fushi-srs-freq-aggregate',
  if (!a.showSource) 'fushi-srs-hide-source',
  if (!a.compactPhone) 'fushi-srs-full-gloss',
  if (a.density != SrsCardDensity.standard)
    'fushi-srs-density-${a.density.wire}',
].join(' ');

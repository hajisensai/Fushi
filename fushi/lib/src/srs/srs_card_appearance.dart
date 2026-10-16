/// 复习卡面的外观设置（「Fushi 卡片」模板的可视化定制）与它到卡面的注入形式。
///
/// 外观不改模板正文：全部变成宿主注入的 CSS 变量（`--fushi-srs-*`）与 `.card` 上的宿主类名
/// （`fushi-srs-*`），模板（packages/fushi_anki/templates/fushi_card/）按它们取值，没注入时
/// 用自己的默认值（导出到 Anki 也能看）。注入只走外壳的 `__fushiSrsSetTheme`：换外观不重跑
/// 卡片脚本、不重排卡片（见 srs_card_face.dart）。
///
/// 存储：一个 JSON 偏好 `srs_card_appearance`（按 profile，随 Profile 快照 / 备份走，不是
/// 设备本地键）。字体文件路径是本机路径：换到另一台设备时那台没有这个文件，拦截器按白名单 +
/// 存在性检查拒掉，卡面回落到默认字体链，不报错。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/srs/srs_card_media.dart';

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

/// 一个字体选择：系统字体只有族名（[path] 为空）；导入的字体文件带本机路径。
@immutable
class SrsCardFontChoice {
  const SrsCardFontChoice({required this.name, this.path});

  /// 字体族名（系统字体 = CSS 族名；导入文件 = 字体自报的家族名，同时作 @font-face 族名）。
  final String name;

  /// 导入字体文件的绝对路径；系统字体为 null。
  final String? path;

  bool get isFile => path != null;

  static SrsCardFontChoice? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? name = json['name'];
    final Object? path = json['path'];
    if (name is! String || name.trim().isEmpty) return null;
    return SrsCardFontChoice(name: name, path: path is String ? path : null);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (path != null) 'path': path,
  };

  @override
  bool operator ==(Object other) =>
      other is SrsCardFontChoice && other.name == name && other.path == path;

  @override
  int get hashCode => Object.hash(name, path);
}

/// 字体槽：日文、中文、西文（拉丁字母与数字）。
enum SrsCardFontSlot { ja, zh, latin }

/// 卡面外观设置。默认值 = 模板默认外观（不注入任何覆盖时的样子）。
@immutable
class SrsCardAppearance {
  const SrsCardAppearance({
    this.fontJa,
    this.fontZh,
    this.fontLatin,
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
  });

  /// 字号缩放的取值范围（正文 / 词条 / 行距共用夹取）。
  static const double minTextScale = 0.85;
  static const double maxTextScale = 1.4;
  static const double minTermScale = 0.75;
  static const double maxTermScale = 1.35;
  static const double minLineSpacing = 0.85;
  static const double maxLineSpacing = 1.3;

  final SrsCardFontChoice? fontJa;
  final SrsCardFontChoice? fontZh;
  final SrsCardFontChoice? fontLatin;

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

  SrsCardFontChoice? font(SrsCardFontSlot slot) => switch (slot) {
    SrsCardFontSlot.ja => fontJa,
    SrsCardFontSlot.zh => fontZh,
    SrsCardFontSlot.latin => fontLatin,
  };

  /// 换某个字体槽（[font] 为 null = 恢复默认）。
  SrsCardAppearance withFont(SrsCardFontSlot slot, SrsCardFontChoice? font) =>
      SrsCardAppearance(
        fontJa: slot == SrsCardFontSlot.ja ? font : fontJa,
        fontZh: slot == SrsCardFontSlot.zh ? font : fontZh,
        fontLatin: slot == SrsCardFontSlot.latin ? font : fontLatin,
        textScale: textScale,
        termScale: termScale,
        lineSpacing: lineSpacing,
        colorSource: colorSource,
        customAccent: customAccent,
        density: density,
        dictUnified: dictUnified,
        showPicture: showPicture,
        showTranslation: showTranslation,
        showFrequency: showFrequency,
        showSource: showSource,
        glossaryExpanded: glossaryExpanded,
        frontReading: frontReading,
        frontFrequency: frontFrequency,
        sentenceFurigana: sentenceFurigana,
      );

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
  }) => SrsCardAppearance(
    fontJa: fontJa,
    fontZh: fontZh,
    fontLatin: fontLatin,
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
      fontJa: SrsCardFontChoice.fromJson(json['fontJa']),
      fontZh: SrsCardFontChoice.fromJson(json['fontZh']),
      fontLatin: SrsCardFontChoice.fromJson(json['fontLatin']),
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
    if (fontJa != null) 'fontJa': fontJa!.toJson(),
    if (fontZh != null) 'fontZh': fontZh!.toJson(),
    if (fontLatin != null) 'fontLatin': fontLatin!.toJson(),
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
  };

  String encode() => jsonEncode(toJson());

  /// 导入字体文件的路径（拦截器的白名单）。
  Set<String> get fontFilePaths => <String>{
    for (final SrsCardFontChoice? f in <SrsCardFontChoice?>[
      fontJa,
      fontZh,
      fontLatin,
    ])
      if (f?.path != null) p.canonicalize(f!.path!),
  };

  @override
  bool operator ==(Object other) =>
      other is SrsCardAppearance && encode() == other.encode();

  @override
  int get hashCode => encode().hashCode;
}

/// 卡面里由宿主按界面语言注入的标签文字。
@immutable
class SrsCardLabels {
  const SrsCardLabels({
    required this.allDefinitions,
    required this.frequency,
    required this.source,
  });

  final String allDefinitions;
  final String frequency;
  final String source;
}

// ---------------------------------------------------------------- 注入形式

/// 卡面配色：由 ColorScheme 角色一一映射到 `--fushi-srs-*`（命名对齐模板的令牌表）。
@visibleForTesting
Map<String, Color> srsCardPaletteVars(ColorScheme s, {required bool dark}) =>
    <String, Color>{
      '--fushi-srs-bg': s.surface,
      '--fushi-srs-fg': s.onSurface,
      '--fushi-srs-fg-muted': s.onSurfaceVariant,
      '--fushi-srs-accent': s.primary,
      '--fushi-srs-on-accent': s.onPrimary,
      '--fushi-srs-accent-container': s.primaryContainer,
      '--fushi-srs-on-accent-container': s.onPrimaryContainer,
      '--fushi-srs-secondary-container': s.secondaryContainer,
      '--fushi-srs-on-secondary-container': s.onSecondaryContainer,
      '--fushi-srs-surface-container': s.surfaceContainer,
      '--fushi-srs-surface-container-high': s.surfaceContainerHigh,
      '--fushi-srs-surface-container-highest': s.surfaceContainerHighest,
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

String _cssColorValue(Color c) {
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

/// 一个字体选择的 CSS 族名（与 @font-face 声明一致）。
String _familyOf(SrsCardFontChoice f) =>
    ReaderCustomFontCss.cssFontFamilyName(f.name);

/// 外观 → 注入外壳主题样式里的 CSS（`:root` 变量 + 导入字体的 @font-face）。
///
/// [fontUrl] 把字体文件路径换成卡面虚拟域 URL；[fontRoot] 是允许供给的字体目录
/// （不在其内的路径不出 @font-face，等于没选）。
String srsCardAppearanceCss({
  required SrsCardAppearance appearance,
  required ColorScheme appScheme,
  required bool dark,
  required SrsCardLabels labels,
  required String Function(String path) fontUrl,
  String? fontRoot,
}) {
  final SrsCardAppearance a = appearance;
  final StringBuffer faces = StringBuffer();
  final Set<String> declared = <String>{};
  String? familyFor(SrsCardFontChoice? f) {
    if (f == null) return null;
    final String family = _familyOf(f);
    final String? path = f.path;
    if (path == null) return family;
    final String? safe = ReaderCustomFontCss.safeFontPath(
      path,
      allowedRoots: <String>[?fontRoot],
    );
    if (safe == null) return null;
    if (declared.add('$family\u0000$safe')) {
      faces.write(
        '@font-face{font-family:$family;src:url("${fontUrl(safe)}");'
        'font-display:swap;}',
      );
    }
    return family;
  }

  final String? latin = familyFor(a.fontLatin);
  final String? ja = familyFor(a.fontJa);
  final String? zh = familyFor(a.fontZh);
  // 西文字体放在链首：它不含汉字 / 假名，CJK 字形自然回落到后面的日文 / 中文字体。
  String chain(List<String?> picked, String defaults) =>
      <String>[...picked.whereType<String>(), defaults].join(', ');

  final StringBuffer vars = StringBuffer(':root{');
  srsCardPaletteVars(srsCardColorScheme(a, appScheme), dark: dark).forEach(
    (String name, Color c) => vars.write('$name:${_cssColorValue(c)};'),
  );
  if (latin != null || ja != null) {
    vars.write(
      '--fushi-srs-font-ja:${chain(<String?>[latin, ja], kSrsCardDefaultFontJa)};',
    );
  }
  if (latin != null || zh != null) {
    final String zhChain = chain(<String?>[latin, zh], kSrsCardDefaultFontZh);
    vars
      ..write('--fushi-srs-font-zh:$zhChain;')
      ..write('--fushi-srs-font-zh-hant:$zhChain;');
  }
  if (latin != null) {
    vars.write(
      '--fushi-srs-font-ui:${chain(<String?>[latin], kSrsCardDefaultFontUi)};',
    );
  }
  vars
    ..write('--fushi-srs-text-scale:${_fmt(a.textScale)};')
    ..write('--fushi-srs-term-scale:${_fmt(a.termScale)};')
    ..write('--fushi-srs-line-scale:${_fmt(a.lineSpacing)};')
    ..write('--fushi-srs-label-more:${srsCssString(labels.allDefinitions)};')
    ..write('--fushi-srs-label-frequency:${srsCssString(labels.frequency)};')
    ..write('--fushi-srs-label-source:${srsCssString(labels.source)};')
    ..write('}');
  return '$faces$vars';
}

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
  if (!a.showSource) 'fushi-srs-hide-source',
  if (a.density != SrsCardDensity.standard)
    'fushi-srs-density-${a.density.wire}',
].join(' ');

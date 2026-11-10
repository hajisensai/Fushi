/// 复习卡面「这张卡用哪套渲染器」的**唯一判据**（复习页、浏览预览、笔记 / 模板 / 字段说明编辑
/// 预览、外观页预览共用）。三套渲染器：
///
/// - [SrsFushiHybridSurface]：Fushi 原生混合卡面（原生区块 + 释义 WebView，`SrsFushiCardView`）。
///   引擎认出区块布局（`srsFushiCardNative` → [SrsRenderedCard.fushiCardDefinitions]），且字段区块 /
///   HTML 区块原生画得全（[srsFushiCardItemsNative]）。
/// - [SrsHtmlNativeSurface]：Dart HTML / CSS 排版引擎画的整面原生卡（`SrsHtmlCardView`）。只给非内置
///   Fushi 卡片类型，两面都在原生认得的子集里（[srsHtmlCardOf]）。内置 Fushi 卡片画不了混合卡面时
///   模板本身带脚本、媒体查询与定位，原生 HTML 子集也画不了，仍走 WebView 外壳（它还要注入外观设置：
///   `--fushi-srs-*` 变量、类名、字体）。
/// - [SrsWebViewSurface]：整面 WebView（`srsCardFaceBuilderProvider`）。
///
/// 优先级固定：混合 > 原生 HTML > WebView。站点只负责把手头的输入交进来，再按返回的
/// [SrsCardSurface] 建对应视图、取能力（[SrsCardSurface.flutterDrawn]）；不得自己再判一遍——
/// BUG-3732 / BUG-3706 / BUG-3707 / BUG-4059 都是判据各写一份、改一处漏一处。源码守卫
/// `test/srs/srs_card_surface_single_source_guard_test.dart` 咬住这一点。
///
/// 纯 Dart（不依赖 Flutter）；底下两个探测都按内容记忆，同一张卡重复判不重复解析。
library;

import 'package:fushi_anki/fushi_anki_core.dart'
    show
        AnkiCardSpecialFields,
        AnkiTemplateError,
        FushiCardItem,
        templateIdsToNames;
import 'package:fushi_engine/srs/srs_builtin.dart' show kSrsBuiltinFushiCardKey;
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart'
    show SrsFushiCardNative, srsFushiCardNative;
import 'package:fushi_srs/fushi_srs.dart'
    show SrsFieldDef, SrsNoteTypeView, SrsTemplateDef;

import 'package:fushi/src/srs/srs_fushi_card_items.dart'
    show srsFushiCardItemsNative;
import 'package:fushi/src/srs/srs_html_card.dart'
    show SrsHtmlCard, srsHtmlCardOf;

/// 选中的渲染器。
enum SrsCardSurfaceKind { fushiHybrid, htmlNative, webView }

/// 引擎认出区块布局的 Fushi 卡片：混合渲染的候选（还要过区块探测才算选中）。
final class SrsFushiCardLayout {
  const SrsFushiCardLayout({
    required this.definitionsHtml,
    required this.fields,
    this.front,
    this.back,
    this.blockProbeLanguageCode,
  });

  /// 只含释义区的背面 HTML（交给释义 WebView）。
  final String definitionsHtml;

  /// 笔记字段（按字段名）。
  final Map<String, String> fields;

  /// 正面 / 背面区块布局（HTML 区块已按字段展开）；null = 内置默认布局（不探测）。
  final List<FushiCardItem>? front;
  final List<FushiCardItem>? back;

  /// 探测字段区块 / HTML 区块时用的卡面语言。笔记 / 模板编辑预览历来不带语言探测
  /// （`srsFushiCardLayoutOfTemplate` 给 null），复习页 / 浏览 / 外观页带默认内容语言。
  final String? blockProbeLanguageCode;

  /// 引擎渲染好的卡 [r] 的候选；引擎没认出区块布局（[SrsRenderedCard.fushiCardDefinitions] 为
  /// null）时为 null。
  static SrsFushiCardLayout? ofRendered(
    SrsRenderedCard r, {
    String? languageCode,
  }) {
    final String? defs = r.fushiCardDefinitions;
    if (defs == null) return null;
    return SrsFushiCardLayout(
      definitionsHtml: defs,
      fields: r.fields,
      front: r.fushiCardFront,
      back: r.fushiCardBack,
      blockProbeLanguageCode: languageCode,
    );
  }
}

/// 一张卡渲染出的两面与样式表（原生 HTML 卡面的输入）。
typedef SrsCardSides = ({String question, String answer, String css});

/// 判据的结果：选中的渲染器及其能力。
sealed class SrsCardSurface {
  const SrsCardSurface();

  SrsCardSurfaceKind get kind;

  /// 卡面由 Flutter 原生画（混合或原生 HTML）：铺到浮动页头 / 底栏底下、把它们的高度当滚动
  /// 内边距；这一面看得见的发音键现成可得，不靠页面上报。WebView 卡面二者都不成立。
  bool get flutterDrawn => kind != SrsCardSurfaceKind.webView;
}

/// Fushi 原生混合卡面。
final class SrsFushiHybridSurface extends SrsCardSurface {
  const SrsFushiHybridSurface(this.layout);

  final SrsFushiCardLayout layout;

  @override
  SrsCardSurfaceKind get kind => SrsCardSurfaceKind.fushiHybrid;
}

/// Dart HTML / CSS 排版引擎画的整面原生卡。
final class SrsHtmlNativeSurface extends SrsCardSurface {
  const SrsHtmlNativeSurface(this.card);

  /// 两面解析好的原生渲染源。
  final SrsHtmlCard card;

  @override
  SrsCardSurfaceKind get kind => SrsCardSurfaceKind.htmlNative;
}

/// 整面 WebView。
final class SrsWebViewSurface extends SrsCardSurface {
  const SrsWebViewSurface();

  @override
  SrsCardSurfaceKind get kind => SrsCardSurfaceKind.webView;
}

String? _lang(String? code) => code == null || code.isEmpty ? null : code;

/// 唯一判据：[fushiCardType] = 笔记类型是内置 Fushi 卡片；[fushiLayout] = 引擎认出的区块布局
/// （没有为 null）；[sides] = 渲染出的两面（没有为 null，例如字段说明页要往卡面 HTML 注入高亮框，
/// 只能用 WebView）；[languageCode] = 卡面默认内容语言（'' 视同 null）。
SrsCardSurface srsCardSurfaceOf({
  required bool fushiCardType,
  SrsFushiCardLayout? fushiLayout,
  SrsCardSides? sides,
  String? languageCode,
}) {
  if (fushiLayout != null &&
      srsFushiCardItemsNative(
        front: fushiLayout.front ?? const <FushiCardItem>[],
        back: fushiLayout.back ?? const <FushiCardItem>[],
        fields: fushiLayout.fields,
        languageCode: _lang(fushiLayout.blockProbeLanguageCode),
      )) {
    return SrsFushiHybridSurface(fushiLayout);
  }
  if (!fushiCardType && sides != null) {
    final SrsHtmlCard? html = srsHtmlCardOf(
      question: sides.question,
      answer: sides.answer,
      css: sides.css,
      languageCode: _lang(languageCode),
    );
    if (html != null) return SrsHtmlNativeSurface(html);
  }
  return const SrsWebViewSurface();
}

/// 引擎渲染好的卡（[SrsDbStore.renderCard]）的判据入口：null（还没读到）= 整面 WebView。
SrsCardSurface srsCardSurfaceOfRendered(
  SrsRenderedCard? rendered, {
  required bool fushiCardType,
  String? languageCode,
}) {
  if (rendered == null) return const SrsWebViewSurface();
  return srsCardSurfaceOf(
    fushiCardType: fushiCardType,
    fushiLayout: SrsFushiCardLayout.ofRendered(
      rendered,
      languageCode: languageCode,
    ),
    sides: (
      question: rendered.question,
      answer: rendered.answer,
      css: rendered.css,
    ),
    languageCode: languageCode,
  );
}

/// 笔记类型 [builtinKey] 是不是内置 Fushi 卡片。
bool srsIsFushiCardType(String? builtinKey) =>
    builtinKey == kSrsBuiltinFushiCardKey;

/// 编辑中（未保存）的笔记 / 模板的混合渲染候选：与复习页同一个引擎判据（`srsFushiCardNative`：
/// 内置 Fushi 卡片、样式没改、正背面认得出区块布局、媒体原生画得全）。填空类型、模板写坏了
/// 为 null。区块探测不带语言（[SrsFushiCardLayout.blockProbeLanguageCode] 为 null，沿用收口前
/// 编辑预览的行为）。
SrsFushiCardLayout? srsFushiCardLayoutOfTemplate({
  required SrsNoteTypeView type,
  required SrsTemplateDef template,
  required Map<String, String> valuesById,
  List<String> tags = const <String>[],
}) {
  if (type.isCloze) return null;
  final Map<String, String> idToName = <String, String>{
    for (final SrsFieldDef f in type.fields) f.id: f.name,
  };
  final Map<String, String> fieldsByName = <String, String>{
    for (final SrsFieldDef f in type.fields) f.name: valuesById[f.id] ?? '',
  };
  final int ord = type.templates.indexWhere(
    (SrsTemplateDef x) => x.id == template.id,
  );
  final SrsFushiCardNative? native;
  try {
    native = srsFushiCardNative(
      builtinKey: type.builtinKey,
      front: templateIdsToNames(template.front, idToName),
      back: templateIdsToNames(template.back, idToName),
      css: type.css,
      fieldsByName: fieldsByName,
      cardOrd: ord < 0 ? 0 : ord,
      specials: AnkiCardSpecialFields(
        tags: tags,
        noteTypeName: type.name,
        cardName: template.name,
      ),
    );
  } on AnkiTemplateError {
    return null;
  }
  if (native == null) return null;
  return SrsFushiCardLayout(
    definitionsHtml: native.definitions,
    fields: fieldsByName,
    front: native.front,
    back: native.back,
  );
}

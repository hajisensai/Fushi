/// 原生 Fushi 卡面里的自定义区块（字段区块、HTML 区块）交给原生 HTML 渲染器
/// （srs_html_card.dart）画：这里给出每一块的 HTML、解析结果，以及整张卡画不画得全的判据。
///
/// 引擎只判模板认不认得出区块布局（`srsFushiCardNative`）；HTML 区块里写了原生 HTML 子集
/// 画不了的东西（脚本、表格、定位……）由这里再判一次，画不了就整张卡回退 WebView。复习页、
/// 浏览预览、笔记 / 模板编辑预览、外观页预览共用这一处判据。
library;

import 'package:fushi_anki/fushi_anki_core.dart'
    show
        FushiCardFieldItem,
        FushiCardFieldStyle,
        FushiCardHtmlItem,
        FushiCardItem;
import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;

import 'package:fushi/src/srs/srs_html_card.dart';

/// 片段没有卡片外壳的 16px 页边距：区块之间的间距由原生卡面统一给。
const String kSrsHtmlFragmentHostCss = 'body{padding:0;}';

final Map<String, ({SrsHtmlCardFace? face, String? reason})> _memo =
    <String, ({SrsHtmlCardFace? face, String? reason})>{};

/// 一段 HTML 片段的原生渲染源，带画不了时的原因（第一句画不了的写法）。按内容记忆最近 48 段。
///
/// 片段不带卡片样式表：原生只认片段里的行内样式与 `<style>`。明暗两种主题都要排得出来。
({SrsHtmlCardFace? face, String? reason}) srsHtmlFragmentProbe(
  String html, {
  String? languageCode,
}) {
  final String key = '${languageCode ?? ''}\u0000$html';
  final ({SrsHtmlCardFace? face, String? reason})? hit = _memo.remove(key);
  if (hit != null) {
    _memo[key] = hit;
    return hit;
  }
  ({SrsHtmlCardFace? face, String? reason}) result;
  try {
    final SrsHtmlCardFace face = SrsHtmlCardFace.parse(
      html,
      '',
      languageCode: languageCode,
    );
    face.layout(
      dark: false,
      foreground: 0xFF000000,
      hostCss: kSrsHtmlFragmentHostCss,
    );
    face.layout(
      dark: true,
      foreground: 0xFFFFFFFF,
      hostCss: kSrsHtmlFragmentHostCss,
    );
    result = (face: face, reason: null);
  } on SrsHtmlUnsupported catch (e) {
    result = (face: null, reason: e.reason);
  }
  _memo[key] = result;
  if (_memo.length > 48) _memo.remove(_memo.keys.first);
  return result;
}

/// 布局项 [item] 交给原生 HTML 渲染器的 HTML：字段区块（标签样式以外）是字段值（小字套一层
/// 字号），HTML 区块是展开后的 HTML；内置区块与标签样式（纯文字胶囊）为 null。
String? srsFushiItemHtml(
  FushiCardItem item,
  Map<String, String> fields,
) => switch (item) {
  FushiCardFieldItem(style: FushiCardFieldStyle.tag) => null,
  // 小字：与模板 `.fc-field--small` 同字号、同行高。
  FushiCardFieldItem(style: FushiCardFieldStyle.small, :final String field) =>
    '<div style="font-size:13px;line-height:1.5">${fields[field] ?? ''}</div>',
  FushiCardFieldItem(:final String field) => fields[field] ?? '',
  FushiCardHtmlItem(:final String html) => html,
  _ => null,
};

/// 正背面布局（[front] / [back]）里的字段区块 / HTML 区块原生都画得了吗。
bool srsFushiCardItemsNative({
  required List<FushiCardItem> front,
  required List<FushiCardItem> back,
  required Map<String, String> fields,
  String? languageCode,
}) {
  for (final FushiCardItem x in <FushiCardItem>[...front, ...back]) {
    final String? html = srsFushiItemHtml(x, fields);
    if (html == null || html.trim().isEmpty) continue;
    if (srsHtmlFragmentProbe(html, languageCode: languageCode).face == null) {
      return false;
    }
  }
  return true;
}

/// 引擎渲染好的卡 [r] 走不走原生 Fushi 卡面（混合渲染）：引擎认得出区块布局
/// （[SrsRenderedCard.fushiCardDefinitions] 非 null），且自定义区块原生画得全。
bool srsFushiCardRenderedNative(SrsRenderedCard r, {String? languageCode}) =>
    r.fushiCardDefinitions != null &&
    srsFushiCardItemsNative(
      front: r.fushiCardFront,
      back: r.fushiCardBack,
      fields: r.fields,
      languageCode: languageCode == null || languageCode.isEmpty
          ? null
          : languageCode,
    );

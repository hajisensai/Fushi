/// 一张渲染好的卡走哪种卡面：原生 Fushi 混合卡面、原生 HTML 卡面，还是整面 WebView（带原因）。
///
/// 复习页、浏览预览、笔记 / 模板编辑预览、外观页预览**只**经这一处判（反馈 O5YDP27Xko：
/// 以前四处各拼一遍 `srsFushiCardRenderedNative` + `srsNativeHtmlCardFor`，判据参数不一，
/// 回退时也不留原因，复习卡整面 WebView 查不出卡在哪一道）。
///
/// 判定顺序：
/// 1. 引擎认得出 Fushi 卡片布局（[SrsRenderedCard.fushiCardDefinitions] 非 null）：字段区块 /
///    HTML 区块原生 HTML 子集画得全就 [SrsCardFaceFushiNative]，否则 [SrsCardFaceWeb]
///    （[SrsCardNativeFallbackCode.block]）。
/// 2. 内置 Fushi 卡片但引擎没给布局：[SrsCardFaceWeb]，原因取引擎的
///    [SrsRenderedCard.nativeFallback]（远程老主机没带原因时为
///    [SrsCardNativeFallbackCode.remoteUnknown]）。Fushi 卡片模板带脚本、媒体查询与定位，
///    原生 HTML 子集画不了，不再试。
/// 3. 其余卡片：两面都在原生 HTML 子集里就 [SrsCardFaceHtmlNative]，否则 [SrsCardFaceWeb]
///    （[SrsCardNativeFallbackCode.html]）。
library;

import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;
import 'package:fushi_engine/srs/srs_fushi_card_native_media.dart'
    show SrsCardNativeFallback, SrsCardNativeFallbackCode;

import 'package:fushi/src/srs/srs_fushi_card_items.dart';
import 'package:fushi/src/srs/srs_html_card.dart';

/// 卡面路线（见文件头）。
sealed class SrsCardFaceRoute {
  const SrsCardFaceRoute();

  /// 卡面由 Flutter 原生画（Fushi 混合卡面或原生 HTML 卡面）。
  bool get isNative => this is! SrsCardFaceWeb;
}

/// 原生 Fushi 混合卡面（原生区块 + 释义 WebView）。
final class SrsCardFaceFushiNative extends SrsCardFaceRoute {
  const SrsCardFaceFushiNative();
}

/// 原生 HTML 卡面（非 Fushi 卡片，两面都在原生子集里）。
final class SrsCardFaceHtmlNative extends SrsCardFaceRoute {
  const SrsCardFaceHtmlNative(this.card);

  final SrsHtmlCard card;
}

/// 整面 WebView，[fallback] 是没走原生的原因。
final class SrsCardFaceWeb extends SrsCardFaceRoute {
  const SrsCardFaceWeb(this.fallback);

  final SrsCardNativeFallback fallback;
}

/// [rendered] 走哪种卡面（见文件头）。[fushiCard] = 笔记类型是内置 Fushi 卡片；
/// [languageCode] 是内容语言（空串按没有）。结果按内容记忆（区块与 HTML 判据各自记忆）。
SrsCardFaceRoute srsCardFaceRoute(
  SrsRenderedCard rendered, {
  required bool fushiCard,
  String? languageCode,
}) {
  final String? lang = languageCode == null || languageCode.isEmpty
      ? null
      : languageCode;
  if (rendered.fushiCardDefinitions != null) {
    final String? block = srsFushiCardItemsFallback(
      front: rendered.fushiCardFront,
      back: rendered.fushiCardBack,
      fields: rendered.fields,
      languageCode: lang,
    );
    return block == null
        ? const SrsCardFaceFushiNative()
        : SrsCardFaceWeb(
            SrsCardNativeFallback(SrsCardNativeFallbackCode.block, block),
          );
  }
  if (fushiCard) {
    return SrsCardFaceWeb(
      rendered.nativeFallback ??
          const SrsCardNativeFallback(SrsCardNativeFallbackCode.remoteUnknown),
    );
  }
  final ({SrsHtmlCard? card, String? reason}) html = srsHtmlCardProbe(
    question: rendered.question,
    answer: rendered.answer,
    css: rendered.css,
    languageCode: lang,
  );
  final SrsHtmlCard? card = html.card;
  return card != null
      ? SrsCardFaceHtmlNative(card)
      : SrsCardFaceWeb(
          SrsCardNativeFallback(
            SrsCardNativeFallbackCode.html,
            html.reason ?? '',
          ),
        );
}

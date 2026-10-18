import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// 阅读器下发章节 HTML / 书内 CSS 前的清洗链。
///
/// 实现只有一份，在 `native/fushi_compute/src/parse/sanitize.rs`（经
/// [ReaderSanitizeNative] 调用），输出与原 Dart 正则实现逐字节一致；这里只是门面。生产路径
/// （`webview.part.dart`）走字节入口 [buildChapterHtmlBytes] / [sanitizeCssBytes]，整条链
/// 一次 FFI。下面的 String 入口是同一份原生实现的单步视图，供测试与零散调用（String 先编成
/// UTF-8 再过界，孤立代理会变成 U+FFFD——生产路径的输入是磁盘字节，不受影响）。
///
/// 各步语义（规则记在这里，正则 / 回溯等价性写在 Rust 侧）：
///
/// - **XHTML 自闭合**（[sanitizeXhtml]）：XHTML 当 text/html 下发时，HTML5 分词器忽略非 void
///   元素的自闭合斜杠，`<tag …/>` 变成未闭合的开标签。BUG-079：`<script/>` / `<style/>` /
///   `<title/>` 等 raw-text 元素吞掉后续全部内容、整页空白；BUG-737：`<a id="toc-N"/>` 经
///   adoption agency 把后面整章正文包进 `<a>`，点按查词在 `closest('a')` 处放弃。所以把每个
///   自闭合非 void 元素改写成显式成对标签（在 XHTML 里是同一个空元素），void 元素
///   （`<br/>`、`<img/>`…）保留自闭合。属性里的引号串整段当一个 token，属性值内的字面 `/>`
///   （`<a href="a/>b"/>`）不会被当成标签结尾。
/// - **插图 lazy**（[markImagesLazy]，TODO-perf 跨章·图片）：阅读器 JS 给 `<img>` 挂 lazy 的
///   那段跑在 `load` 之后，来不及影响本次加载，所以在生成 HTML 时就写 `loading="lazy"
///   decoding="async"`。eager 例外与 JS 侧同款且更保守（Dart 侧 eager 集合是 JS 侧的超集）：
///   纯图片章整章 eager（TODO-1349，分页几何要靠插图真实撑开）；`class` 含 `gaiji` 的内联小图
///   参与文字排版几何；已显式写了 `loading=` 的标签尊重原书——合并前导插图自带
///   `loading="eager"`（TODO-1339），因此不依赖与注入步的先后顺序。
/// - **合并前导插图**（[injectImagesAfterBodyOpen]，TODO-1174）：插到 `<body…>` 之后（独立
///   插图属于它引出的那章的开头）；没有 `<body>` 时前置到整篇之前。
/// - **head 注入**（[injectReaderHead]）：`headStart` 紧跟 `<head>`（FOUC 遮罩必须先于书内 CSS
///   生效），`headEnd` 紧贴 `</head>` 之前（阅读器样式在 `!important` 平局中胜出，阅读器
///   viewport meta 排在书自带的之后——WebKit 取最后一个）。没有 `</head>` 时两段都放 `<head>`
///   后；没有 `<head>` 时前置到整篇之前。
/// - **CSS**（[sanitizeCss]）：行首的 `-epub-*` 前缀属性改写成标准 / `-webkit-` 写法，
///   `-epub-writing-mode` 删掉（书写方向由阅读器统一控制）。
abstract final class ReaderResourceSanitizer {
  static ReaderSanitizeNative get _native => ReaderSanitizeNative.instance;

  /// 章节 HTML 整条链：[raw] 是磁盘上的原始字节（非 UTF-8 字节按 U+FFFD 容忍，
  /// HBK-AUDIT-118），返回下发给 WebView 的最终 UTF-8 字节。顺序固定为 XHTML 自闭合 →
  /// 插图 lazy（[eagerAll] 时跳过）→ 合并前导插图 [mergedImagesHtml] → head 注入。
  /// 文档里 `</head>` 早于 `<head…>` 结束时抛 [RangeError]（与旧实现相同）。
  static Uint8List buildChapterHtmlBytes(
    Uint8List raw, {
    required bool eagerAll,
    required String mergedImagesHtml,
    required String headStart,
    required String headEnd,
  }) {
    return _native.chapterHtml(
      raw,
      steps:
          ReaderSanitizeNative.stepXhtml |
          (eagerAll ? 0 : ReaderSanitizeNative.stepLazyImages) |
          ReaderSanitizeNative.stepBodyImages |
          ReaderSanitizeNative.stepReaderHead,
      images: _utf8(mergedImagesHtml),
      headStart: _utf8(headStart),
      headEnd: _utf8(headEnd),
    );
  }

  /// 书内 CSS 整条链：原始字节进、最终 UTF-8 字节出（非 UTF-8 字节容忍，HBK-AUDIT-118）。
  static Uint8List sanitizeCssBytes(Uint8List raw) => _native.css(raw);

  /// 单步：自闭合非 void 元素展开成成对标签。
  static String sanitizeXhtml(String html) =>
      _step(html, ReaderSanitizeNative.stepXhtml);

  /// 单步：给 `<img>` 写 lazy / async；[eagerAll] 时原样返回。
  static String markImagesLazy(String html, {bool eagerAll = false}) {
    if (eagerAll) return html;
    return _step(html, ReaderSanitizeNative.stepLazyImages);
  }

  /// 单步：[imagesHtml] 插到 `<body…>` 之后（前后各加一个换行）；为空时原样返回。
  static String injectImagesAfterBodyOpen(String html, String imagesHtml) {
    if (imagesHtml.isEmpty) return html;
    return _step(html, ReaderSanitizeNative.stepBodyImages, images: imagesHtml);
  }

  /// 单步：阅读器 head 注入。
  static String injectReaderHead(
    String html, {
    required String headStart,
    required String headEnd,
  }) => _step(
    html,
    ReaderSanitizeNative.stepReaderHead,
    headStart: headStart,
    headEnd: headEnd,
  );

  /// 单步：书内 CSS 改写。
  static String sanitizeCss(String css) => utf8.decode(
    _native.css(_utf8(css), flags: ReaderSanitizeNative.inputIsText),
  );

  static String _step(
    String html,
    int steps, {
    String images = '',
    String headStart = '',
    String headEnd = '',
  }) {
    return utf8.decode(
      _native.chapterHtml(
        _utf8(html),
        steps: steps | ReaderSanitizeNative.inputIsText,
        images: _utf8(images),
        headStart: _utf8(headStart),
        headEnd: _utf8(headEnd),
      ),
    );
  }

  static Uint8List _utf8(String s) => s.isEmpty ? Uint8List(0) : utf8.encode(s);
}

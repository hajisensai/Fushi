import 'package:flutter_test/flutter_test.dart';

import 'reader_hibiki_page_source_corpus.dart';

/// TODO-1074 守卫（根因 B）：EPUB 图片响应带 `max-age` 缓存，不再 `no-cache`。
///
/// _interceptRequest 命中 `/epub/` 分支时 `await file.readAsBytes()` 全量读盘原样返回，
/// 旧实现响应头恒 `Cache-Control: no-cache` → WebView 每次都重读盘 + 全分辨率重解码。
/// 「文本—图片—文本」来回切同一图片，每次换章都重复读盘重解码 → 卡。
///
/// 修复：图片 mime（`image/*`）响应改 `max-age=3600`（与字体的 max-age=3600 先例一致），
/// 让 WebView 复用解码后的位图；HTML/CSS 仍 no-cache（它们随阅读器样式变化被逐次
/// 重 sanitize + 注入 styleTag，缓存会串旧样式）。
///
/// _interceptRequest 走 WebView2/inappwebview，headless CI 跑不到真实响应，故源码守卫锁死
/// 「图片走 max-age、HTML/CSS 走 no-cache」的分支不回退。
void main() {
  group('TODO-1074：EPUB 图片响应缓存策略', () {
    late String src;
    late String interceptBody;

    setUpAll(() {
      src = readReaderPageSource();
      // macOS/iOS 稳定化重构后，资源服务体从 _interceptRequest 移进
      // _readerResourcePayload（返回 _ReaderResourceResponse DTO，供拦截 +
      // Apple 自定义 scheme 两条路径复用）。图片 max-age / HTML-CSS no-cache
      // 的缓存分支现在住在 payload 函数里，守卫据此扫 payload 函数体。
      final int interceptIdx =
          src.indexOf('_readerResourcePayload(WebUri url) async {');
      final int end = src.indexOf(
          'Future<WebResourceResponse?> _interceptRequest(', interceptIdx);
      expect(interceptIdx, greaterThan(0));
      expect(end, greaterThan(interceptIdx));
      interceptBody = src.substring(interceptIdx, end);
    });

    test('图片 mime 判定 + max-age 缓存头存在', () {
      expect(
        interceptBody.contains("mime.startsWith('image/')"),
        isTrue,
        reason: '必须按 image/* mime 区分图片响应，给它可缓存的 max-age',
      );
      expect(
        interceptBody.contains("'max-age=3600'"),
        isTrue,
        reason: '图片响应必须带 max-age，让 WebView 复用解码位图，'
            '消除来回切章重复读盘重解码',
      );
    });

    test('HTML/CSS 等非图片仍 no-cache（缓存会串旧 styleTag）', () {
      expect(
        interceptBody.contains("? 'max-age=3600' : 'no-cache'"),
        isTrue,
        reason: '只有图片走 max-age；HTML/CSS 因随样式变化必须保持 no-cache',
      );
    });

    test('EPUB 拦截分支不再硬编码恒定 no-cache 头', () {
      // 旧实现：headers 里恒 'Cache-Control': 'no-cache'。修复后改为变量 cacheControl。
      expect(
        interceptBody.contains("'Cache-Control': cacheControl"),
        isTrue,
        reason: 'Cache-Control 必须按 mime 动态取值，不得对所有资源恒 no-cache',
      );
    });
  });
}

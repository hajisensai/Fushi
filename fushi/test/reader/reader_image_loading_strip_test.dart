import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';

/// 正文插图不得懒加载：分页是横向多列排版，`loading="lazy"` 的图在远列永远进不了
/// 懒加载视口、保持 0 尺寸，章节几何（maxScroll / 章末判定）被算短，用户还没翻完
/// 一串插图就被判到章末跨到下一章（《志乃と恋 Future》封面后的插图章）。阅读器统一
/// 去掉 `<img>` 上的 `loading` 属性，连原书自带的 lazy 一起去掉。
void main() {
  group('ReaderResourceSanitizer.stripImageLoadingAttributes', () {
    test('原书自带的 loading="lazy" 被去掉', () {
      const String html =
          '<body><img loading="lazy" src="images/a.png" alt="a"/></body>';
      expect(
        ReaderResourceSanitizer.stripImageLoadingAttributes(html),
        '<body><img src="images/a.png" alt="a"/></body>',
      );
    });

    test('单引号 / 无引号 / 大小写 / 属性在中间都能去掉', () {
      expect(
        ReaderResourceSanitizer.stripImageLoadingAttributes(
          "<IMG src='a.png' LOADING='lazy' class='x'/>",
        ),
        "<IMG src='a.png' class='x'/>",
      );
      expect(
        ReaderResourceSanitizer.stripImageLoadingAttributes(
          '<img src="a.png" loading=lazy>',
        ),
        '<img src="a.png">',
      );
    });

    test('属性值里的 > 与 loading 字样不被误伤', () {
      const String html = '<img alt="x loading=lazy>" src="a.png"/>';
      expect(ReaderResourceSanitizer.stripImageLoadingAttributes(html), html);
    });

    test('没有 loading 的图、非 img 标签原样保留', () {
      const String html =
          '<body><img src="a.png"/><p>文</p>'
          '<image href="b.png" loading="lazy"/>'
          '<iframe loading="lazy"></iframe></body>';
      expect(ReaderResourceSanitizer.stripImageLoadingAttributes(html), html);
    });

    test('多张图逐一处理', () {
      const String html =
          '<img loading="lazy" src="a.png"/>'
          '<img src="b.png" loading="eager"/><img loading="lazy" src="c.png"/>';
      expect(
        ReaderResourceSanitizer.stripImageLoadingAttributes(html),
        '<img src="a.png"/><img src="b.png"/><img src="c.png"/>',
      );
    });
  });
}

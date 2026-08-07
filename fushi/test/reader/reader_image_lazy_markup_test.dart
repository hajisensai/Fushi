import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';

/// TODO-perf（跨章·图片）：`loading="lazy"` 必须在**生成 HTML 时**写进标签才对本次加载
/// 生效（JS 侧那次跑在 `load` 之后，来不及）。这条规则跑在每次跨章的热路径上，标错一张
/// 图就是分页几何塌缩或首屏空白，故把判定钉死。
void main() {
  group('ReaderResourceSanitizer.markImagesLazy', () {
    test('普通插图挂 lazy + async 解码', () {
      const String html = '<body><p>本文</p><img src="images/a.png"/></body>';
      final String out = ReaderResourceSanitizer.markImagesLazy(html);
      expect(out, contains('<img loading="lazy" decoding="async" src='));
      expect(out, contains('images/a.png'));
    });

    test('纯图片章整章 eager（分页几何要靠插图真实撑开）', () {
      const String html = '<body><img src="images/p1.png"/></body>';
      expect(
        ReaderResourceSanitizer.markImagesLazy(html, eagerAll: true),
        html,
      );
    });

    test('gaiji 内联小图保持 eager（参与文字排版几何）', () {
      const String html = '<p>文<img class="gaiji" src="g.png"/>字</p>';
      expect(ReaderResourceSanitizer.markImagesLazy(html), html);
      const String html2 = "<p><img class='gaiji-line' src='g.png'/></p>";
      expect(ReaderResourceSanitizer.markImagesLazy(html2), html2);
    });

    test('原书已写 loading= 的标签尊重原值', () {
      const String html = '<img loading="eager" src="a.png"/>';
      expect(ReaderResourceSanitizer.markImagesLazy(html), html);
    });

    test('多张图逐一处理，非 img 标签不受影响', () {
      const String html = '<body><img src="a.png"/><p>文</p>'
          '<image href="b.png"/><img src="c.png"/></body>';
      final String out = ReaderResourceSanitizer.markImagesLazy(html);
      expect('loading="lazy"'.allMatches(out).length, 2);
      expect(out, contains('<image href="b.png"/>'));
    });

    test('幂等：再跑一次不会重复加属性', () {
      const String html = '<img src="a.png"/>';
      final String once = ReaderResourceSanitizer.markImagesLazy(html);
      final String twice = ReaderResourceSanitizer.markImagesLazy(once);
      expect(twice, once);
    });

    test('属性值里的字面 > 不会被当成标签结束', () {
      const String html = '<img alt="a>b" src="a.png"/>';
      expect(
        ReaderResourceSanitizer.markImagesLazy(html),
        '<img loading="lazy" decoding="async" alt="a>b" src="a.png"/>',
      );
    });

    test('单引号属性同样按整串处理', () {
      const String html = "<img alt='x>y' src='b.png'/>";
      expect(
        ReaderResourceSanitizer.markImagesLazy(html),
        '<img loading="lazy" decoding="async" alt=\'x>y\' src=\'b.png\'/>',
      );
    });
  });
}

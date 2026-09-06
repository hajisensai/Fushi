// 词典自带 CSS 里 `@font-face` 的相对 url() 必须在产出 dictionaryStyles 时内联成
// data:（BUG-2147）。
//
// 词典包的样式表被**内联成 <style>** 注入弹窗文档，所以里面的相对 URL 相对**弹窗
// 文档**解析（Android 是 file:///android_asset/.../popup/，Windows/iOS 是
// initialData 的 opaque origin），与词典目录毫无关系 —— 字节永远取不到。
// 字体这一半只能内联：字体是强制 CORS 模式的子资源，而弹窗媒体通道走
// CustomSchemeResponse 带不了 Access-Control-Allow-Origin，换成 URL 只是把 404
// 换成「被 CORS 静默拒绝」。
//
// 放在 FushiDicts 的样式产出点而不是某个宿主里，是因为 in-app 弹窗 / 悬浮窗 /
// 浏览器扩展 / 样式预览四个表面读的是同一个 dictionaryStyles。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

void main() {
  // 剑桥发音词典的真实形状：@font-face 用裸名 url()，别处用带 ?version 的雪碧图，
  // 另有绝对路径与远程 URL 两种必须原样保留的形态。
  const String kCss = '@font-face{font-family:\'ico-c\';font-display:swap;'
      'src:url(cdoicons.woff) format(\'woff\')}\n'
      '.sp{background:url("sprite.gif?version=5.0.287")}\n'
      '.abs{background:url(/external/images/cdo-sprite.png)}\n'
      '.remote{background:url(\'https://dictionary.cambridge.org/x.png\')}\n';

  final Uint8List woff = Uint8List.fromList(
    <int>[0x77, 0x4F, 0x46, 0x46, 0x00, 0x01, 0x00, 0x00, 1, 2, 3],
  );

  Uint8List? reader(String dict, String path) {
    if (dict != 'CamPron') return null;
    if (path == 'cdoicons.woff') return woff;
    if (path == 'sprite.gif') return Uint8List.fromList(<int>[1, 2, 3]);
    return null;
  }

  test('@font-face 的裸名 url() 被内联成 data:，MIME 按扩展名', () {
    final String out = FushiDicts.inlineDictionaryFontFaceUrls(
      kCss,
      'CamPron',
      reader,
    );
    expect(
      out,
      contains('url("data:font/woff;base64,${base64Encode(woff)}")'),
      reason: '字体没内联 = 图标渲染成豆腐块，且换成 URL 也会被 CORS 拒绝',
    );
    expect(out, isNot(contains('url(cdoicons.woff)')));
  });

  test('只动 @font-face 块；雪碧图/背景图留给 popup 侧重写成 media URL', () {
    final String out = FushiDicts.inlineDictionaryFontFaceUrls(
      kCss,
      'CamPron',
      reader,
    );
    expect(
      out,
      contains('url("sprite.gif?version=5.0.287")'),
      reason: '图片不受 CORS 约束，保留 URL 形态才能共享 WebView 的 HTTP 缓存',
    );
  });

  test('带 scheme 的与协议相对的 URL 原样保留', () {
    final String out = FushiDicts.inlineDictionaryFontFaceUrls(
      '@font-face{src:url(https://example.com/y.woff)}'
      '@font-face{src:url(data:font/woff;base64,AAA)}'
      '@font-face{src:url(//cdn.example.com/z.woff)}',
      'CamPron',
      reader,
    );
    expect(out, contains('url(https://example.com/y.woff)'));
    expect(out, contains('url(data:font/woff;base64,AAA)'));
    expect(out, contains('url(//cdn.example.com/z.woff)'));
  });

  test('前导 `/` 是 .mdd 根相对，要剥掉后再查 —— 与 popup 侧同解', () {
    // <img src="/x.png"> 走 normalizeDictMediaPath 剥前导 `/`；CSS 这一侧必须
    // 解出**同一个** media key，否则同一份资源在两条通道上指向两个 key。
    final String out = FushiDicts.inlineDictionaryFontFaceUrls(
      '@font-face{src:url(/cdoicons.woff)}',
      'CamPron',
      reader,
    );
    expect(out, contains('url("data:font/woff;base64,'));
  });

  test('取不到字节时原样保留，不产出坏的 data:', () {
    final String out = FushiDicts.inlineDictionaryFontFaceUrls(
      '@font-face{src:url(missing.woff)}',
      'CamPron',
      reader,
    );
    expect(out, contains('url(missing.woff)'));
    expect(out, isNot(contains('data:')));
  });

  test('超过上限的字体不内联（BUG-1868：内联字节会随每个嵌套弹窗整份重发）', () {
    final Uint8List huge = Uint8List(FushiDicts.kMaxInlinedDictFontBytes + 1);
    final String out = FushiDicts.inlineDictionaryFontFaceUrls(
      '@font-face{src:url(huge.woff)}',
      'D',
      (String d, String p) => p == 'huge.woff' ? huge : null,
    );
    expect(
      out,
      contains('url(huge.woff)'),
      reason: '整套 CJK 字体内联进去等于把已修好的性能灾难换个入口放回来',
    );
  });

  test('没有 @font-face 的 CSS 原样返回（热路径早退）', () {
    const String plain = '.a{color:red}';
    expect(
      FushiDicts.inlineDictionaryFontFaceUrls(plain, 'D', reader),
      same(plain),
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_web_core/fushi_web_core.dart';

import 'package:fushi/src/web_browser/features/reader_mode/web_reader_mode_document.dart';
import 'package:fushi/src/web_browser/features/reader_mode/web_reader_mode_feature.dart';

WebArticle article({
  String title = '第一章',
  String xhtml = '<p>本文</p>',
  int chars = 100,
  List<String> images = const <String>[],
  String? author,
  String? workTitle,
}) => WebArticle(
  url: 'https://example.com/1',
  title: title,
  workKey: 'k',
  images: images,
  excerpt: '',
  paragraphs: 1,
  chars: chars,
  method: 'readability',
  charset: 'utf-8',
  contentHash: 'h',
  xhtml: xhtml,
  author: author,
  workTitle: workTitle,
);

void main() {
  test('图片占位换回真实地址；越界 / 非 http(s) 置空', () {
    const String x =
        '<img src="${kWebArticleImagePlaceholderPrefix}0"/>'
        "<img src='${kWebArticleImagePlaceholderPrefix}1'/>"
        '<img src="${kWebArticleImagePlaceholderPrefix}5"/>';
    final String out = resolveWebArticleImages(x, <String>[
      'https://img.example.com/a.png?x=1&y="2"',
      'javascript:alert(1)',
    ]);
    expect(
      out,
      '<img src="https://img.example.com/a.png?x=1&amp;y=&quot;2&quot;"/>'
      '<img src=""/>'
      '<img src=""/>',
    );
  });

  test('正文页头转义标题 / 站点 / 作者', () {
    final String body = buildWebReaderModeBody(
      article(title: '<b>章</b>', author: 'A&B', workTitle: '作品'),
      siteName: 'example.com',
    );
    expect(body, contains('<h1>&lt;b&gt;章&lt;/b&gt;</h1>'));
    expect(body, contains('<p class="fushi-reader-site">作品</p>'));
    expect(body, contains('<p class="fushi-reader-byline">A&amp;B</p>'));
    expect(body, contains('<section class="fushi-reader-body"><p>本文</p>'));
  });

  test('正文太短 / 空不进阅读模式', () {
    expect(webReaderModeAccepts(article()), isTrue);
    expect(webReaderModeAccepts(article(chars: 10)), isFalse);
    expect(webReaderModeAccepts(article(xhtml: '  ')), isFalse);
  });

  test('安装脚本：正文 / 样式按 JSON 字面量嵌入，剥可执行内容，留 fushi- 样式', () {
    final String js = webReaderModeInstallScript(
      bodyHtml: '<p>"</script> </p>',
      css: 'a{color:red}',
    );
    expect(js, contains(r'"<p>\"</script>'));
    expect(js, contains('"a{color:red}"'));
    expect(js, contains("indexOf('fushi-') !== 0"));
    expect(js, contains("n.indexOf('on') === 0"));
    expect(js, contains('replaceChildren'));
  });

  test('样式表带主题色', () {
    final String css = buildWebReaderModeCss(
      const WebReaderModeTheme(
        background: '#000000',
        text: '#ffffff',
        muted: '#888888',
        accent: '#ff0000',
        dark: true,
      ),
    );
    expect(css, contains('background:#000000!important'));
    expect(css, contains('color-scheme:dark'));
    expect(css, contains('.fushi-reader a{color:#ff0000;}'));
  });

  test('只对 http(s) 页面开放', () {
    expect(webReaderModeSupportsUrl(Uri.parse('https://a.jp/x')), isTrue);
    expect(webReaderModeSupportsUrl(Uri.parse('about:blank')), isFalse);
    expect(webReaderModeSupportsUrl(null), isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';

/// BUG-2017 回归：EPUB 章节是 XML（`application/xhtml+xml`），WebView 按该 MIME
/// 走 XML 解析，`<script src="…"/>` 是合法空元素；而 Dart 侧的 HTML5 解析器把
/// raw-text 元素的自闭合写法当成**永不闭合的开标签**，会把 `<body>` 连同整章
/// 正文吞成该元素的文本。kobo 处理过的日文 EPUB 正是这种形态（head 一行自闭合
/// `<script src="../../js/kobo.js"/>`、全文无 `</script>`），后果是每章纯文本为
/// 空 —— 有声书对齐匹配率 0、每章字数落库 0、每章都被判成纯图片章。

/// 复刻 kobo 化日文 EPUB 的章节形态：自闭合 script，全文无 `</script>`。
String _koboChapter(String bodyInner) {
  return '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html>'
      '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja" class="vrtl">\n'
      '<head>\n'
      '<meta charset="UTF-8"/>\n'
      '<script xmlns="http://www.w3.org/1999/xhtml" type="text/javascript" '
      'src="../../js/kobo.js"/>\n'
      '<style type="text/css" id="koboSpanStyle">.koboSpan { }</style>\n'
      '</head>\n'
      '<body class="p-text">\n$bodyInner\n</body>\n</html>';
}

EpubBook _bookWith(String html) {
  return EpubBook(
    title: 'T',
    chapters: <EpubChapter>[
      EpubChapter(
        id: 'c1',
        href: 'xhtml/p-003.xhtml',
        mediaType: 'application/xhtml+xml',
        html: html,
      ),
    ],
  );
}

void main() {
  group('normalizeSelfClosingRawTextTags', () {
    test('自闭合 script 被补成显式闭合', () {
      expect(
        normalizeSelfClosingRawTextTags('<script src="a.js"/>'),
        '<script src="a.js"></script>',
      );
    });

    test('每个 raw-text 标签都覆盖', () {
      for (final String tag in kRawTextTags) {
        expect(
          normalizeSelfClosingRawTextTags('<$tag/>'),
          '<$tag></$tag>',
          reason: '$tag 是 raw-text 元素，自闭合会吞掉后文',
        );
      }
    });

    test('大小写不敏感', () {
      expect(
        normalizeSelfClosingRawTextTags('<SCRIPT SRC="a.js"/>'),
        '<SCRIPT SRC="a.js"></script>',
      );
    });

    test('空元素不动 —— 自闭合的 br/img/meta 在两种解析器下等价', () {
      const String s = '<br/><img src="a.png"/><meta charset="UTF-8"/>';
      expect(normalizeSelfClosingRawTextTags(s), s);
    });

    test('已显式闭合的 raw-text 标签不动', () {
      const String s = '<script src="a.js"></script><style>.a{}</style>';
      expect(normalizeSelfClosingRawTextTags(s), s);
    });

    test('属性值里的 > 不被当作标签边界', () {
      expect(
        normalizeSelfClosingRawTextTags('<script data-x="a>b"/>'),
        '<script data-x="a>b"></script>',
      );
      // 单引号同样成立。
      expect(
        normalizeSelfClosingRawTextTags("<script data-x='a>b'/>"),
        "<script data-x='a>b'></script>",
      );
    });

    test('注释 / CDATA / DOCTYPE / XML 声明整段原样透传', () {
      const String s = '<?xml version="1.0"?><!DOCTYPE html>'
          '<!-- <script src="x"/> --><![CDATA[ <script/> ]]>';
      expect(normalizeSelfClosingRawTextTags(s), s);
    });

    test('无 /> 的输入是恒等变换', () {
      const String s = '<p>本文</p>';
      expect(normalizeSelfClosingRawTextTags(s), s);
    });
  });

  group('kobo 化 EPUB 章节（BUG-2017 原始失败路径）', () {
    test('chapterPlainText 拿到正文而不是空串', () {
      final EpubBook book = _bookWith(
        _koboChapter('<div class="main"><p><span class="koboSpan" '
            'id="kobo.2.1">一月二十二日、午後七時二十分頃、</span></p></div>'),
      );
      expect(book.chapterPlainText(0), '一月二十二日、午後七時二十分頃、');
    });

    test('振假名 rt 仍被剥掉，ruby 基文保留', () {
      final EpubBook book = _bookWith(
        _koboChapter('<p><ruby>野<rt>の</rt>口<rt>ぐち</rt></ruby>さん</p>'),
      );
      expect(book.chapterPlainText(0), '野口さん');
    });

    test('每章字数不再恒为 0', () {
      final EpubBook book = _bookWith(
        _koboChapter('<p>一月二十二日、午後七時二十分頃、</p>'),
      );
      expect(book.chapterCharacterCount(0), greaterThan(0));
    });

    test('正文章不再被误判成纯图片章', () {
      final EpubBook book = _bookWith(
        _koboChapter('<p><img src="i.png"/></p>'
            '<p>${'あ' * 200}</p>'),
      );
      expect(book.isImageOnlyChapter(0), isFalse);
    });

    test('body 里的图片引用仍能取到', () {
      final EpubBook book = _bookWith(
        _koboChapter('<p><img src="i.png"/></p>'),
      );
      expect(book.chapterImageSrcs(0), contains('i.png'));
    });
  });

  group('全书搜索走同一解析入口（BUG-2017 第二条失败路径）', () {
    test('kobo 化章节仍能被 searchBook 命中', () async {
      final EpubBook book = _bookWith(
        _koboChapter('<p>一月二十二日、午後七時二十分頃、</p>'),
      );
      final List<BookSearchResult> hits =
          await AudiobookBridge.searchBook(book, '午後七時');
      expect(hits, isNotEmpty,
          reason: '搜索与 chapterPlainText 必须共用 EpubBook.parseChapterHtml，'
              '否则这类书全书搜索恒零结果');
      expect(hits.first.sectionIndex, 0);
    });
  });
}

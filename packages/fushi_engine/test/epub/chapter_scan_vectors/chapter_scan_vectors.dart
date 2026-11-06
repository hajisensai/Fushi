// 章节 DOM 派生量（`ffc_parse_epub_chapter`）的回归向量：转储格式与固定种子语料。
//
// 期望值全部由**删除前的 Dart 实现**（`package:html` 0.15.6 建树 + Dart 遍历）生成：
// 同一份转储代码只用 EpubBook 的公共 API，旧实现编一份、跑同一语料，输出即期望。
// 改动这里的格式或生成器会让期望全部失效——那时只能拿旧实现（git 历史里
// `packages/fushi_engine/lib/epub/epub_book.dart` 删除前的版本）重新生成。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fushi_engine/epub/epub_book.dart';

String _h(String s) => sha1.convert(utf8.encode(s)).toString().substring(0, 16);

final RegExp _idPattern = RegExp(r'''\bid\s*=\s*["']([^"']*)["']''');

Iterable<String> _ids(String html) sync* {
  for (final RegExpMatch m in _idPattern.allMatches(html)) {
    yield m.group(1)!;
  }
}

/// 纯文本 / 读音轨 / 字数 / 锚点 / 纯图片章 / 图片引用 / 插图索引的逐章转储。
String chapterScanVectorDump(List<String> htmls) {
  final EpubBook book = EpubBook(
    title: 'synthetic',
    chapters: <EpubChapter>[
      for (int i = 0; i < htmls.length; i++)
        EpubChapter(
          id: 'c$i',
          href: 'OEBPS/text/c$i.xhtml',
          mediaType: 'application/xhtml+xml',
          html: htmls[i],
        ),
    ],
  );
  final StringBuffer out = StringBuffer()
    ..writeln('BOOK synthetic chapters=${book.chapters.length}');
  for (int i = 0; i < book.chapters.length; i++) {
    final String html = book.chapters[i].html;
    final String plain = book.chapterPlainText(i);
    final EpubPlainTextWithRuby r = book.chapterPlainTextWithRuby(i);
    final List<String> ids = _ids(html).toList();
    final Map<String, int> anchors = book.chapterAnchorCharOffsets(i, ids);
    final String rubies = r.rubies
        .map((EpubRubyAnnotation x) => '${x.start}:${x.end}:${x.reading}')
        .join('|');
    out
      ..writeln(
        'ch$i plain=${_h(plain)}/${plain.length} '
        'count=${book.chapterCharacterCount(i)} '
        'rubyText=${r.text == plain} '
        'rubies=${_h(rubies)}/${r.rubies.length} '
        'blockEnds=${_h(r.blockEnds.join(','))}/${r.blockEnds.length} '
        'scene=${r.sceneBreaks.join(',')} '
        'imageOnly=${book.isImageOnlyChapter(i)} '
        'refs=${book.chapterImageSrcs(i).join('|')}',
      )
      ..writeln(
        '  anchors=${<String>[for (final String id in ids)
          if (anchors.containsKey(id)) '$id=${anchors[id]}'].join(',')}',
      );
  }
  for (final EpubImageRef img in book.images) {
    out.writeln(
      'img ${img.chapterIndex} ${img.orderInBook} ${img.src} k=${img.revealKey} '
      'off=${img.charOffset} norm=${img.normCharOffset} '
      'lead=${img.leadingAnchorIds.join('|')} line=${img.sharesLineWithText}',
    );
  }
  out.writeln('END');
  return out.toString();
}

/// 全书搜索坐标系文本（[EpubBook.chapterSearchText]）的逐章转储。
String chapterSearchVectorDump(List<String> htmls) {
  final EpubBook book = EpubBook(
    title: 's',
    chapters: <EpubChapter>[
      for (int i = 0; i < htmls.length; i++)
        EpubChapter(id: '$i', href: '$i', mediaType: 'x', html: htmls[i]),
    ],
  );
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < book.chapters.length; i++) {
    final String t = book.chapterSearchText(i);
    out.writeln('ch$i ${_h(t)}/${t.length}');
  }
  out.writeln('END');
  return out.toString();
}

/// 整份转储的 SHA-256（固定种子语料只入库摘要）。
String vectorDigest(String dump) =>
    sha256.convert(utf8.encode(dump)).toString();

const List<String> _tags = <String>[
  'p',
  'div',
  'span',
  'ruby',
  'rb',
  'rt',
  'rp',
  'rtc',
  'b',
  'i',
  'a',
  'table', //
  'tr', 'td', 'th', 'tbody', 'caption', 'li', 'ul', 'ol', 'dl', 'dt', 'dd', //
  'img', 'svg', 'image', 'select', 'option', 'h1', 'h2', 'br', 'hr', 'pre', //
  'form', 'button', 'head', 'body', 'html', 'style', 'title', 'math', 'mi', //
  'textarea', 'nobr', 'font', 'em', 'section', 'figure', 'figcaption', //
  'listing',
  'object',
  'iframe',
  'noscript',
  'template',
  'frameset',
  'script', //
  'u', 's', 'center', 'blockquote', 'address', 'main', 'xmp', 'embed', //
  'param',
  'col',
  'colgroup',
  'foreignObject',
  'desc',
  'annotation-xml',
  'mo', //
  'video', 'header', 'footer', 'nav', 'article', 'aside', 'h3', 'h6', //
];

const List<String> _texts = <String>[
  '漢字', 'かな', 'abc', '　', '\n', ' ', '「台詞」', '◇', 'x y', '&amp;', //
  '&nbsp;', '&#x3042;', '々', 'A1', '\t', '\r\n', '\r', '\u0085', '﻿', //
  ' ', ' ', '&#13;', '&#x85;', '◇◇◇', '＊　＊', '※', '・・・', //
  'café', '𠀋', 'ｶﾀｶﾅ', '１２３', '……', '――', '&copy', '&notit;', '&#128;', //
  '&#0;', '&lt', '<!-- c -->', '<![CDATA[x]]>', '\u0000', '<', '&', '</', //
];

const List<String> _attrs = <String>[
  '', ' id="a"', ' id="b"', " id='c'", ' id=""', ' src="p.png"', //
  ' src="  ../img/sp.jpg "', ' src=""', ' style="background:url(q.png)"', //
  ' style="background-image : URL( \'../i/q2.png\' ) ; color:red"', //
  ' xlink:href="r.png"', ' href="s.png"', ' class="c"', //
  ' xmlns:xlink="http://www.w3.org/1999/xlink"', ' id="a" id="b"', //
  ' encoding="text/html"', ' lang="ja"', //
];

/// 段落 / 插图页式的成块片段，让语料里有真书常见的结构（不只是标签汤）。
const List<String> _blocks = <String>[
  '<p>本文<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>です。</p>',
  '<p><ruby><rb>東京</rb><rp>（</rp><rt>とうきょう</rt><rp>）</rp></ruby>へ</p>',
  '<p><ruby>無<rtc><rt>む</rt></rtc></ruby>理</p>',
  '<p class="center">◇　◇　◇</p>',
  '<p><br/></p>',
  '<p></p>',
  '<hr/>',
  '<div class="illus"><img src="../image/p001.jpg" alt=""/></div>',
  '<p>「<img src="../image/gaiji.png"/>」と言った。</p>',
  '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><image width="10" height="10" xlink:href="../image/p002.jpg"/></svg>',
  '<div style="background-image:url(../image/bg.jpg)"></div>',
  '<h2 id="toc_1">第一章</h2>',
  '<p id="p1">　彼は言った。</p>',
  '<style>p{background-image:url( "../img/bg.png" )}</style>',
  '<title/>',
  '<script src="../js/kobo.js"/>',
  '<span class="koboSpan" id="kobo.1.1">一文。</span>',
  '<table><tr><td>セル</td></tr></table>',
  '<pre>  前置き\n  整形済み</pre>',
];

const String _prologue =
    '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html>'
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>t</title></head><body>';

/// xorshift64（固定种子，跨平台确定）。
final class _Rng {
  _Rng(int seed) : _x = seed * 0x9E3779B1 + 0x7F4A7C15;

  int _x;

  int next(int n) {
    _x ^= _x << 13;
    _x ^= _x >>> 7;
    _x ^= _x << 17;
    return (_x >>> 1) % n;
  }

  T pick<T>(List<T> list) => list[next(list.length)];
}

/// 种子 [seed] 的 [count] 份章节 HTML。
List<String> chapterScanFuzzCorpus(int seed, int count) {
  final _Rng r = _Rng(seed);
  final List<String> docs = <String>[];
  for (int d = 0; d < count; d++) {
    final StringBuffer b = StringBuffer();
    if (r.next(3) == 0) b.write(_prologue);
    final int parts = 3 + r.next(30);
    for (int k = 0; k < parts; k++) {
      final int roll = r.next(100);
      final String tag = r.pick(_tags);
      if (roll < 6) {
        // 带编号的图片引用：插图索引按 revealKey 去重，固定文件名只会留下几张。
        final int n = r.next(400);
        b.write(
          r.pick(<String>[
            '<img src="../image/i$n.jpg"/>',
            '<image xlink:href="../image/s$n.jpg"/>',
            '<span style="background-image:url(b$n.png)">',
          ]),
        );
      } else if (roll < 30) {
        b.write('<$tag${r.pick(_attrs)}>');
      } else if (roll < 45) {
        b.write('</$tag>');
      } else if (roll < 52) {
        b.write('<$tag${r.pick(_attrs)}/>');
      } else if (roll < 64) {
        b.write(r.pick(_blocks));
      } else {
        b.write(r.pick(_texts));
      }
    }
    if (r.next(4) == 0) b.write('</body></html>');
    docs.add(b.toString());
  }
  return docs;
}

/// 入库语料文件的分隔（`\n=====\n`，与生成期望时的工具相同）。
List<String> splitCorpus(String text) => text.split('\n=====\n');

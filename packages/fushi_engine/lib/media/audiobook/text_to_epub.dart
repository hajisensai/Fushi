import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:fushi_engine/epub/epub_book.dart' show EpubBook;
import 'package:fushi_engine/epub/epub_importer.dart' show EpubImporter;
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;

/// Converts plain text files (TXT, HTML, MD, etc.) into valid EPUB 3 bytes
/// suitable for import via [EpubImporter].
///
/// Container assembly (ZIP/OPF/NCX/nav) is shared with [CuesToEpub] via
/// [EpubBuilder]; only the input parsing and chapter body generation live
/// here.
class TextToEpub {
  static const int kMaxCharsPerChapter = 30000;

  static const Set<String> supportedExtensions = {
    'txt',
    'html',
    'htm',
    'xhtml',
    'md',
    'markdown',
    'rst',
    'org',
    'csv',
    'tsv',
    'log',
    'json',
    'xml',
  };

  static bool isSupported(String path) {
    final ext = path.split('.').last.toLowerCase();
    return supportedExtensions.contains(ext);
  }

  /// Reads [file], detects encoding, converts content to EPUB bytes.
  ///
  /// 解码留在调用方 isolate（平台字符集检测器只装配在主 isolate；超过 8 KB 的
  /// 本地编码解码自己会进后台 isolate），切章 + XHTML 拼装 + ZIP 压缩这段与输入
  /// 大小成正比的同步重活交给 [convertTextInBackground]，几 MB 的 TXT 导入时
  /// UI isolate 不再整段卡住。
  static Future<Uint8List> convert({
    required File file,
    required String title,
    String? author,
  }) async {
    final String content = await readTextWithEncoding(file);
    final String ext = file.path.split('.').last.toLowerCase();
    return convertTextInBackground(
      content: content,
      title: title,
      author: author,
      extension: ext,
    );
  }

  /// [convertText] 放到一次性后台 isolate 里跑。输出与 [convertText] 逐字节
  /// 相同（同一个函数），产物经 `Isolate.exit` 交回、不再复制一遍。
  static Future<Uint8List> convertTextInBackground({
    required String content,
    required String title,
    String? author,
    String extension = 'txt',
  }) => Isolate.run<Uint8List>(
    () => convertText(
      content: content,
      title: title,
      author: author,
      extension: extension,
    ),
    debugName: 'TextToEpub.convert',
  );

  /// Converts in-memory [content] (already decoded, e.g. pasted from the
  /// clipboard) to EPUB bytes. [extension] picks the parser exactly like the
  /// file path's extension does in [convert] (`txt` = plain text paragraphs).
  static Uint8List convertText({
    required String content,
    required String title,
    String? author,
    String extension = 'txt',
  }) {
    final List<String> chapters = _splitIntoChapters(
      content,
      extension.toLowerCase(),
    );

    final List<String> chapterXhtmls = <String>[
      for (int i = 0; i < chapters.length; i++)
        _chapterXhtml(
          title: title,
          chapterIndex: i,
          totalChapters: chapters.length,
          bodyHtml: chapters[i],
        ),
    ];

    return EpubBuilder.assemble(
      title: title,
      author: author,
      uidPrefix: 'fushi-text-',
      chapterXhtmls: chapterXhtmls,
    );
  }

  // ── Content splitting ─────────────────────────────────────────────────────
  //
  // 三种输入（纯文本 / Markdown / HTML）先各自解析成同一棵小块树（[_BodyNode]），
  // 再由同一个打包器 [_packInner] 按 [kMaxCharsPerChapter] 切章。切点优先级：
  // 块之间 > 块内的换行（`<br/>`，切点处的换行并入块边界、不留在块首）> 行内
  // 子节点之间 > 文本内的字素簇之间。超长块按原标签重新包成若干块，标签始终成对，
  // 每章都是良构 XHTML。旧实现只在 `<p` 前切，单换行 / 无换行的 TXT、Markdown
  // 以及只有一个巨大块的 HTML 都会整本落进一章（BUG-5057）。

  static List<String> _splitIntoChapters(String content, String ext) {
    final List<_BodyNode> blocks;
    switch (ext) {
      case 'html':
      case 'htm':
      case 'xhtml':
        blocks = _htmlBlocks(content);
        break;
      case 'md':
      case 'markdown':
        blocks = _markdownBlocks(content);
        break;
      default:
        blocks = _plainTextBlocks(content);
        break;
    }
    final List<String> chapters = _packInner(blocks, kMaxCharsPerChapter);
    return chapters.isEmpty ? <String>['<p></p>'] : chapters;
  }

  static String _stripBom(String text) =>
      text.startsWith('﻿') ? text.substring(1) : text;

  static String _normalizeNewlines(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// 一段文字的若干行包成一个块：行与行之间是 `<br/>`。
  static _BodyElement _lineBlock(
    String open,
    String close,
    List<String> lines,
  ) {
    final List<_BodyNode> children = <_BodyNode>[];
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const _BodyAtom('<br/>', isLineBreak: true));
      children.add(_BodyText(lines[i]));
    }
    return _BodyElement(open, close, children);
  }

  static List<_BodyNode> _plainTextBlocks(String text) {
    text = _stripBom(_normalizeNewlines(text));
    final List<_BodyNode> blocks = <_BodyNode>[];
    for (final String para in text.split(RegExp(r'\n{2,}'))) {
      final String trimmed = para.trim();
      if (trimmed.isEmpty) continue;
      // Preserve single newlines as <br/>
      blocks.add(_lineBlock('<p>', '</p>\n', trimmed.split('\n')));
    }
    return blocks;
  }

  static List<_BodyNode> _markdownBlocks(String md) {
    md = _stripBom(_normalizeNewlines(md));
    final List<_BodyNode> blocks = <_BodyNode>[];
    final List<String> paraLines = <String>[];

    void flushPara() {
      if (paraLines.isEmpty) return;
      paraLines[0] = paraLines[0].trimLeft();
      paraLines[paraLines.length - 1] = paraLines.last.trimRight();
      blocks.add(_lineBlock('<p>', '</p>\n', List<String>.of(paraLines)));
      paraLines.clear();
    }

    final RegExp heading = RegExp(r'^(#{1,6})\s+(.+)$');
    for (final String line in md.split('\n')) {
      final RegExpMatch? hMatch = heading.firstMatch(line);
      if (hMatch != null) {
        flushPara();
        final int level = hMatch.group(1)!.length;
        blocks.add(
          _BodyElement('<h$level>', '</h$level>\n', <_BodyNode>[
            _BodyText(hMatch.group(2)!),
          ]),
        );
        continue;
      }
      // Blank line = paragraph break
      if (line.trim().isEmpty) {
        flushPara();
        continue;
      }
      paraLines.add(line);
    }
    flushPara();
    return blocks;
  }

  /// HTML / XHTML 只取 `<body>` 的内容。良构的（X）HTML 按 XML 解析，保住
  /// `<a id="x"/>` 这类非空元素自闭合的写法；不良构的再交给 HTML5 解析器
  /// （与浏览器同一套容错），两条路都重新序列化成良构 XHTML 再切章。
  static List<_BodyNode> _htmlBlocks(String content) {
    content = _stripBom(content);
    final xml.XmlDocument? document = _tryParseXml(content);
    if (document != null) {
      final xml.XmlElement? body = document.descendants
          .whereType<xml.XmlElement>()
          .where((xml.XmlElement e) => e.name.local.toLowerCase() == 'body')
          .firstOrNull;
      final Iterable<xml.XmlNode> nodes = body != null
          ? body.children
          : document.rootElement.name.local.toLowerCase() == 'html'
          ? const <xml.XmlNode>[]
          : <xml.XmlNode>[document.rootElement];
      return _trimEdgeWhitespace(<_BodyNode>[
        for (final xml.XmlNode n in nodes) ?_fromXml(n),
      ]);
    }
    // 不良构输入同样可能带 kobo 式自闭合 <script/>：走章节解析入口先归一化，否则
    // HTML5 tokenizer 会把整个 <body> 吞成脚本文本（BUG-2017）。
    final dom.Element? body = EpubBook.parseChapterHtml(content).body;
    if (body == null) return const <_BodyNode>[];
    return _trimEdgeWhitespace(<_BodyNode>[
      for (final dom.Node n in body.nodes) ?_fromDom(n),
    ]);
  }

  /// 输入是否良构 XML：是就返回文档，不是返回 null（由调用方改走 HTML5 解析）。
  /// [xml.XmlException] 在这里就是「不是良构 XML」这个判定结果本身。
  static xml.XmlDocument? _tryParseXml(String content) {
    try {
      return xml.XmlDocument.parse(
        content,
        entityMapping: const xml.XmlDefaultEntityMapping.html5(),
      );
    } on xml.XmlException {
      return null;
    }
  }

  /// 去掉 body 首尾纯空白文本节点（等价旧实现对 body 内容的 trim）。
  static List<_BodyNode> _trimEdgeWhitespace(List<_BodyNode> nodes) {
    bool blank(_BodyNode n) => n is _BodyText && n.text.trim().isEmpty;
    int start = 0;
    int end = nodes.length;
    while (start < end && blank(nodes[start])) {
      start++;
    }
    while (end > start && blank(nodes[end - 1])) {
      end--;
    }
    return nodes.sublist(start, end);
  }

  static const Set<String> _voidElements = <String>{
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', //
    'link', 'meta', 'param', 'source', 'track', 'wbr',
  };

  static String _attrs(Iterable<MapEntry<String, String>> attributes) {
    final StringBuffer buf = StringBuffer();
    for (final MapEntry<String, String> a in attributes) {
      buf.write(' ${a.key}="${_esc(a.value)}"');
    }
    return buf.toString();
  }

  static _BodyNode _element(
    String name,
    String attrs,
    List<_BodyNode> children,
  ) {
    if (_voidElements.contains(name.toLowerCase())) {
      return _BodyAtom(
        '<$name$attrs/>',
        isLineBreak: name.toLowerCase() == 'br',
      );
    }
    return _BodyElement('<$name$attrs>', '</$name>', children);
  }

  static _BodyNode? _fromXml(xml.XmlNode node) {
    if (node is xml.XmlText) return _BodyText(node.value);
    if (node is xml.XmlCDATA) return _BodyText(node.value);
    if (node is! xml.XmlElement) return null; // 注释 / 处理指令不进正文
    return _element(
      node.name.qualified,
      _attrs(<MapEntry<String, String>>[
        for (final xml.XmlAttribute a in node.attributes)
          MapEntry<String, String>(a.name.qualified, a.value),
      ]),
      <_BodyNode>[for (final xml.XmlNode c in node.children) ?_fromXml(c)],
    );
  }

  static _BodyNode? _fromDom(dom.Node node) {
    if (node is dom.Text) return _BodyText(node.data);
    if (node is! dom.Element) return null; // 注释等不进正文
    return _element(
      node.localName!,
      _attrs(<MapEntry<String, String>>[
        for (final MapEntry<Object, String> a in node.attributes.entries)
          MapEntry<String, String>(a.key.toString(), a.value),
      ]),
      <_BodyNode>[for (final dom.Node c in node.nodes) ?_fromDom(c)],
    );
  }

  /// 把 [children] 打包成若干段内层 HTML，每段不超过 [budget] 个 UTF-16 码元
  /// （单个空元素本身超长时除外，它无法再切）。先按 `<br/>` 把子节点分成行，
  /// 整行装箱；落在切点上的 `<br/>` 丢弃（行尾由块 / 章边界承担，下一段不以
  /// `<br/>` 开头）。单行本身装不下时才在行内子节点之间切，子节点仍装不下就
  /// 递归切开它（元素按原标签重新包裹，文本按字素簇切）。
  static List<String> _packInner(List<_BodyNode> children, int budget) {
    final List<List<_BodyNode>> lines = <List<_BodyNode>>[<_BodyNode>[]];
    for (final _BodyNode child in children) {
      if (child is _BodyAtom && child.isLineBreak) {
        lines.add(<_BodyNode>[]);
      } else {
        lines.last.add(child);
      }
    }

    final List<String> pieces = <String>[];
    final StringBuffer cur = StringBuffer();
    // 当前段里是否已经开始过一行：决定下一行前面要不要补回 `<br/>`。
    bool lineOpen = false;

    void flush() {
      if (cur.isNotEmpty) pieces.add(cur.toString());
      cur.clear();
      lineOpen = false;
    }

    void append(String html) {
      if (cur.isNotEmpty && cur.length + html.length > budget) {
        pieces.add(cur.toString());
        cur.clear();
      }
      cur.write(html);
    }

    for (final List<_BodyNode> line in lines) {
      final int lineLength = line.fold<int>(
        0,
        (int sum, _BodyNode n) => sum + n.html.length,
      );
      final String sep = lineOpen ? '<br/>' : '';
      if (cur.length + sep.length + lineLength > budget) {
        flush();
      } else {
        cur.write(sep);
      }
      // 切点之后紧跟的空行（连续 `<br/>`）也并入边界，段首不留空行。
      if (lineLength == 0 && cur.isEmpty && pieces.isNotEmpty) continue;
      lineOpen = true;
      if (cur.length + lineLength <= budget) {
        for (final _BodyNode n in line) {
          cur.write(n.html);
        }
        continue;
      }
      // 单行超过整段预算：在行内子节点之间切，必要时递归切开子节点。
      for (final _BodyNode n in line) {
        if (n.html.length <= budget) {
          append(n.html);
        } else {
          _splitNode(n, budget).forEach(append);
        }
      }
    }
    flush();
    return pieces;
  }

  /// 把单个超长节点切成若干段，每段不超过 [budget]（空元素无法切，原样返回）。
  static List<String> _splitNode(_BodyNode node, int budget) {
    switch (node) {
      case final _BodyAtom atom:
        return <String>[atom.html];
      case final _BodyText text:
        final List<String> pieces = <String>[];
        final StringBuffer cur = StringBuffer();
        for (final String cluster in text.text.characters) {
          final String escaped = _esc(cluster);
          if (cur.isNotEmpty && cur.length + escaped.length > budget) {
            pieces.add(cur.toString());
            cur.clear();
          }
          cur.write(escaped);
        }
        if (cur.isNotEmpty) pieces.add(cur.toString());
        return pieces;
      case final _BodyElement element:
        final int inner = budget - element.open.length - element.close.length;
        if (inner <= 0) return <String>[element.html];
        return <String>[
          for (final String piece in _packInner(element.children, inner))
            '${element.open}$piece${element.close}',
        ];
    }
  }

  // ── Chapter XHTML (pre-rendered body; unique to this converter) ───────────

  static String _chapterXhtml({
    required String title,
    required int chapterIndex,
    required int totalChapters,
    required String bodyHtml,
  }) {
    final label = totalChapters > 1 ? 'Chapter ${chapterIndex + 1}' : title;
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">\n'
        '<head>\n'
        '  <meta charset="utf-8"/>\n'
        '  <title>${_esc(label)}</title>\n'
        '  <style type="text/css">body{margin:1em 1.5em;line-height:1.8;}p{margin:0.5em 0;}</style>\n'
        '</head>\n'
        '<body>\n'
        '$bodyHtml'
        '</body>\n'
        '</html>\n';
  }

  static String _esc(String s) => EpubBuilder.escXml(s);
}

// ── Body tree (input-independent; what the chapter packer splits) ───────────

/// 章节正文的一个节点。[html] 是它序列化后的良构 XHTML，打包器按其长度装箱。
sealed class _BodyNode {
  const _BodyNode();

  String get html;
}

/// 原样输出、不可再切的节点（空元素）。[isLineBreak] 标出 `<br/>`：打包器优先在
/// 它所在处切，并且切点上的这一个换行并入块边界。
final class _BodyAtom extends _BodyNode {
  const _BodyAtom(this.html, {this.isLineBreak = false});

  @override
  final String html;
  final bool isLineBreak;
}

/// 未转义的文本；超长时按字素簇切，实体与代理对都不会被拆开。
final class _BodyText extends _BodyNode {
  _BodyText(this.text);

  final String text;

  @override
  late final String html = EpubBuilder.escXml(text);
}

/// 成对标签包着的子节点；被切开时每段都用同一对 [open] / [close] 重新包裹。
final class _BodyElement extends _BodyNode {
  _BodyElement(this.open, this.close, this.children);

  final String open;
  final String close;
  final List<_BodyNode> children;

  @override
  late final String html =
      '$open${children.map((_BodyNode c) => c.html).join()}$close';
}

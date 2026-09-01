import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// BUG-2017 源码守卫：**章节 XHTML 只能经 `EpubBook.parseChapterHtml` 进 DOM**。
///
/// EPUB 章节是 XML（`application/xhtml+xml`），WebView 按该 MIME 走 XML 解析，
/// `<script src="…"/>` 是合法空元素；而 package:html 的 HTML5 解析器不认 raw-text
/// 元素的自闭合写法，会把 `<body>` 连同整章正文吞成 script 文本。`parseChapterHtml`
/// 先归一化再交给 HTML 解析器，是两侧结果一致的**唯一**入口。
///
/// 这条不变式没法用行为测试钉住：漏网的消费方各自私有（`_chapterDomText` 是顶层
/// 私有函数），行为测试只能证明「我测到的那条路是对的」，证明不了「没有第 N 条路」。
/// BUG-2017 首轮修复就漏了 `audiobook_bridge.dart` 的全书搜索——文档写着「四处全部
/// 收敛」，实际第五处仍是裸解析，用户在这类书上搜索恒零结果。所以改成正向枚举：
/// 扫全部源码树里对 package:html `parse()` 的调用，白名单之外一律红。
///
/// 白名单只放两类，且必须写明理由：入口实现本体，以及**本来就在解析真 HTML5 文档**
/// 的调用点（网页抓取），后者与 XHTML 自闭合语义无关。
const Map<String, String> kAllowedRawHtmlParseFiles = <String, String>{
  'lib/src/epub/epub_book.dart':
      '入口实现本体：parseChapterHtml 就是「归一化 + html_parser.parse」这一句，'
          '它自己必须调裸解析，否则无处落地。',
  'lib/src/media/torrent/nyaa_client.dart':
      'nyaa 种子站返回的是真正的 HTML5 页面（text/html），不是 EPUB 章节 XHTML；'
          '自闭合 raw-text 标签在那里既不合法也不会出现，走归一化只会平添开销。',
};

const String _kSelfPath = 'test/tools/epub_chapter_parse_entry_guard_test.dart';

/// 扫描面：app 与全部内部包的 `lib/`。测试目录不扫——测试里直接调裸解析构造
/// 「未归一化」的对照输入是正当用法（BUG-2017 的行为测试就要这么做）。
const List<String> _kRoots = <String>[
  'lib',
  '../packages',
];

List<File> _scannedDartFiles() {
  final List<File> files = <File>[];
  for (final String root in _kRoots) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = e.path.replaceAll(r'\', '/');
      if (rel.endsWith('.g.dart') || rel.endsWith('.freezed.dart')) continue;
      if (rel.endsWith(_kSelfPath)) continue;
      // 只看包自身的 lib/，不看各包的 test/ 与 example/。
      if (rel.startsWith('../packages/') &&
          !RegExp(r'^\.\./packages/[^/]+/lib/').hasMatch(rel)) {
        continue;
      }
      files.add(e);
    }
  }
  return files;
}

/// 该文件把 `package:html/parser.dart` 导成了什么名字（`as x` 或裸导入）。
/// 没导入返回 null。
String? _htmlParserPrefix(String maskedSource) {
  final RegExp aliased = RegExp(
    r'''import\s+['"]package:html/parser\.dart['"]\s+as\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*;''',
  );
  final Match? m = aliased.firstMatch(maskedSource);
  if (m != null) return m.group(1);
  final RegExp bare =
      RegExp(r'''import\s+['"]package:html/parser\.dart['"]\s*;''');
  return bare.hasMatch(maskedSource) ? '' : null;
}

List<String> _rawParseHits() {
  final List<String> hits = <String>[];
  for (final File file in _scannedDartFiles()) {
    final String rel = file.path.replaceAll(r'\', '/');
    // 掩掉注释（等长空白，行号不变），否则注释里讲这条规则的文字会自己命中。
    final String masked = maskComments(file.readAsStringSync());
    final String? prefix = _htmlParserPrefix(masked);
    if (prefix == null) continue;
    final RegExp call = prefix.isEmpty
        ? RegExp(r'(?<![A-Za-z0-9_$.])parse\s*\(')
        : RegExp(r'(?<![A-Za-z0-9_$.])' +
            RegExp.escape(prefix) +
            r'\s*\.\s*parse\s*\(');
    final List<String> lines = masked.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (!call.hasMatch(lines[i])) continue;
      final String key = kAllowedRawHtmlParseFiles.keys.firstWhere(
        rel.endsWith,
        orElse: () => '',
      );
      if (key.isNotEmpty) continue;
      hits.add('$rel:${i + 1}');
    }
  }
  return hits;
}

void main() {
  test('扫描规模哨兵：app 与内部包的 lib/ 确实被枚举到了', () {
    expectScanScale(
      _scannedDartFiles().length,
      what: 'fushi/lib + packages/*/lib 下的 .dart（已排除生成物）',
      atLeast: 1050,
      measured: 1342,
    );
  });

  test('白名单每一条都仍然存在且确实还在调裸解析', () {
    for (final MapEntry<String, String> entry
        in kAllowedRawHtmlParseFiles.entries) {
      final File file = File(entry.key);
      expect(file.existsSync(), isTrue,
          reason: '白名单里的 ${entry.key} 已不存在——删掉这条豁免，别留着放行整个目录');
      final String masked = maskComments(file.readAsStringSync());
      expect(_htmlParserPrefix(masked), isNotNull,
          reason: '${entry.key} 已经不再导入 package:html/parser.dart，'
              '这条豁免是死条目，删掉');
      expect(entry.value.length, greaterThanOrEqualTo(20),
          reason: '豁免必须写明理由，不接受占位符');
    }
  });

  test('章节 XHTML 的 DOM 解析只有 EpubBook.parseChapterHtml 一个入口', () {
    expect(
      _rawParseHits(),
      isEmpty,
      reason: '这些位置直接调了 package:html 的 parse()。EPUB 章节是 XHTML，'
          'HTML5 解析器会被自闭合的 <script/> 吞掉整个 <body>（BUG-2017）。'
          '改走 EpubBook.parseChapterHtml；如果它解析的确实是真 HTML5 页面，'
          '把文件加进 kAllowedRawHtmlParseFiles 并写清理由。',
    );
  });
}

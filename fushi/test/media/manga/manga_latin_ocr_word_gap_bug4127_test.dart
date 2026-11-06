import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_text_join.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-4170（反馈 vXYKPudf7U）：英文漫画（全大写对白）OCR 后点词，查词浮层「未找到搜索
/// 结果」，同一个词在查词页查得到；只有紧跟标点的词（`WELL?`）查得到。
///
/// 根因：叠加层按字格逐字输出 `<span class="ocr-char">`，OCR 区域不覆盖空格、各行直接
/// 拼接，DOM 正文成了 `BEENSOLONGSINCE…`。阅读器取词一路扫过词界，引擎不在两个拉丁字母
/// 之间切词，整串查不到。
///
/// ① 行为级：用 node 真执行阅读器注入脚本的 `selectFromPosition`，DOM 序列取自真实的
///    [mangaOcrBoxesHtml] 输出。无 node 时 skip。
/// ② 生成器级：拉丁文行界 / 词间补空白节点，日文不补；整句文本同一规则。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MangaOcrTextRegion region(int index, int start, int end) =>
      MangaOcrTextRegion(
        rectangle: MokuroRect.fromLTWH(index * 10.0, 0, 10, 10),
        utf16Start: start,
        utf16End: end,
      );

  /// 引擎（Lens）给的字级区域：每个非空白字一个，空白不覆盖。
  List<MangaOcrTextRegion> perCharRegions(List<String> lines) {
    final String sentence = lines.join();
    final List<MangaOcrTextRegion> regions = <MangaOcrTextRegion>[];
    for (int i = 0; i < sentence.length; i++) {
      if (sentence[i].trim().isEmpty) continue;
      regions.add(region(i, i, i + 1));
    }
    return regions;
  }

  MokuroBlock blockOf(List<String> lines, {bool supplyRegions = true}) =>
      MokuroBlock(
        rectangle: const MokuroRect.fromLTWH(0, 0, 600, 60),
        isVertical: false,
        fontSize: 10,
        zIndex: 0,
        lines: lines,
        regions: supplyRegions ? perCharRegions(lines) : null,
      );

  String htmlOf(MokuroBlock block) => mangaOcrBoxesHtml(
    MokuroImage(
      url: 'p.jpg',
      size: const MokuroSize(1000, 1000),
      blocks: <MokuroBlock>[block],
    ),
  );

  /// `<p class="ocr-box">` 内部的子节点序列：字格 span 的文字 / 字格之间的裸文本。
  List<Map<String, String>> itemsOf(String html) {
    final int open = html.indexOf('>', html.indexOf('<p class="ocr-box"')) + 1;
    final String inner = html.substring(open, html.indexOf('</p>', open));
    return <Map<String, String>>[
      for (final RegExpMatch m in RegExp(
        r'<span class="ocr-char"[^>]*>([^<]*)</span>|([^<]+)',
      ).allMatches(inner))
        m.group(1) != null
            ? <String, String>{'char': m.group(1)!}
            : <String, String>{'gap': m.group(2)!},
    ];
  }

  int charIndexOf(List<Map<String, String>> items, String visibleText, int at) {
    // [at] 是 [visibleText]（去掉空白的整块文字）里的下标 = 第几个字格。
    expect(
      items.where((Map<String, String> i) => i.containsKey('char')).length,
      visibleText.length,
    );
    return at;
  }

  group('BUG-4170 overlay word gaps', () {
    test('拉丁文：词间与行界补纯空白节点，日文不补', () {
      final List<Map<String, String>> english = itemsOf(
        htmlOf(blockOf(<String>['IT IS BEEN SO', 'LONG SINCE'])),
      );
      final String joined = english
          .map((Map<String, String> i) => i['char'] ?? '|')
          .join();
      expect(joined, 'IT|IS|BEEN|SO|LONG|SINCE');
      expect(
        english.where((Map<String, String> i) => i.containsKey('gap')),
        everyElement(<String, String>{'gap': ' '}),
      );

      // 行几何回退（本地模型 / 旧 mokuro 不带区域）走同一条路径。
      final List<Map<String, String>> geometry = itemsOf(
        htmlOf(
          blockOf(<String>['HAVE YOU', 'BEEN WELL?'], supplyRegions: false),
        ),
      );
      expect(
        geometry.map((Map<String, String> i) => i['char'] ?? '|').join(),
        'HAVE|YOU|BEEN|WELL?',
      );

      final List<Map<String, String>> japanese = itemsOf(
        htmlOf(blockOf(<String>['日本語の', '勉強です。'])),
      );
      expect(
        japanese.any((Map<String, String> i) => i.containsKey('gap')),
        isFalse,
      );

      // 断字连字符不补空格。
      final List<Map<String, String>> hyphen = itemsOf(
        htmlOf(blockOf(<String>['A LET-', 'TER'])),
      );
      expect(
        hyphen.map((Map<String, String> i) => i['char'] ?? '|').join(),
        'A|LET-TER',
      );
    });

    test('整句文本：拉丁文行界补空格，日文无缝', () {
      expect(
        mangaJoinOcrText(<String>['IT IS BEEN SO', 'LONG SINCE']),
        'IT IS BEEN SO LONG SINCE',
      );
      expect(
        mangaJoinOcrText(<String>['A LETTER.', 'HAVE YOU']),
        'A LETTER. HAVE YOU',
      );
      expect(mangaJoinOcrText(<String>['LET-', 'TER']), 'LET-TER');
      expect(mangaJoinOcrText(<String>['日本語の', '勉強です。']), '日本語の勉強です。');
      expect(mangaJoinOcrText(<String>['。', 'OK']), '。OK');

      final String html = htmlOf(
        blockOf(<String>['IT IS BEEN SO', 'LONG SINCE']),
      );
      expect(html, contains('data-manga-sentence="IT IS BEEN SO LONG SINCE"'));
    });

    test('点词只扫到被点的词（executes reader selection script via node）', () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped('node not found on PATH; skipping JS behavior');
        return;
      }
      final List<Map<String, String>> english = itemsOf(
        htmlOf(blockOf(<String>['IT IS BEEN SO', 'LONG SINCE'])),
      );
      const String visible = 'ITISBEENSOLONGSINCE';
      final List<Map<String, String>> geometry = itemsOf(
        htmlOf(
          blockOf(<String>['HAVE YOU', 'BEEN WELL?'], supplyRegions: false),
        ),
      );
      final List<Map<String, String>> japanese = itemsOf(
        htmlOf(blockOf(<String>['日本語の', '勉強です。'])),
      );
      final List<Map<String, Object>> cases = <Map<String, Object>>[
        <String, Object>{
          'name': 'lens regions',
          'items': english,
          'cases': <Map<String, Object>>[
            // 点 BEEN 的 B：修复前是 BEENSOLONGSINCE。
            <String, Object>{
              'char': charIndexOf(english, visible, 4),
              'expect': 'BEEN',
            },
            // 行尾词 SO 不与下一行的 LONG 粘连。
            <String, Object>{
              'char': charIndexOf(english, visible, 8),
              'expect': 'SO',
            },
            <String, Object>{
              'char': charIndexOf(english, visible, 10),
              'expect': 'LONG',
            },
          ],
        },
        <String, Object>{
          'name': 'line geometry',
          'items': geometry,
          'cases': <Map<String, Object>>[
            <String, Object>{'char': 4, 'expect': 'YOU'},
            <String, Object>{'char': 7, 'expect': 'BEEN'},
            // 阅读器 scanDelimiters 不含 ASCII '?'；引擎 scan_candidates 会在 L 与 ? 之间再切出 WELL。
            <String, Object>{'char': 11, 'expect': 'WELL?'},
          ],
        },
        <String, Object>{
          'name': 'japanese unchanged',
          'items': japanese,
          'cases': <Map<String, Object>>[
            <String, Object>{'char': 0, 'expect': '日本語の勉強です'},
          ],
        },
      ];

      final Directory tmp = Directory.systemTemp.createTempSync(
        'fushi_bug4127_',
      );
      // 用例与阅读器脚本拼在 harness 前面（见 .js 文件头）：脚本原样包进函数体，
      // 每次点击在新的 fake DOM 上重新求值一遍。
      final String harness = File(
        'test/media/manga/manga_latin_ocr_word_gap_bug4127_test.js',
      ).readAsStringSync();
      final File program = File('${tmp.path}/bug4127_program.js')
        ..writeAsStringSync(
          'const MANGA_OCR_CASES = ${jsonEncode(cases)};\n'
          'function loadReaderSelection(window, document, Node, NodeFilter, '
          'CSS) {\n${ReaderSelectionScripts.source()}\n'
          ';return window.fushiSelection;\n}\n$harness',
        );
      try {
        final ProcessResult result = await Process.run(nodeExe, <String>[
          program.path,
        ], workingDirectory: Directory.current.path);
        expect(
          result.exitCode,
          0,
          reason:
              'BUG-4170 behavior test failed.\n'
              'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        );
        expect(result.stdout.toString(), contains('all assertions passed (7)'));
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });

  group('BUG-4170 empty state names the term', () {
    test('有查询词时空态写明查的词，空串退回通用文案', () {
      LocaleSettings.setLocale(AppLocale.en);
      expect(dictionaryPopupNoResultsMessage('BEENSO'), contains('BEENSO'));
      expect(
        dictionaryPopupNoResultsMessage('BEENSO'),
        isNot(t.no_search_results),
      );
      expect(dictionaryPopupNoResultsMessage(''), t.no_search_results);
      expect(dictionaryPopupNoResultsMessage(null), t.no_search_results);
    });
  });
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}

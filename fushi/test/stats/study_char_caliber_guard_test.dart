import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// BUG-2058 的**结构性**守卫：口径统一这件事本身此前零护栏。
///
/// 这条 PR 把「学习字数」从四种各写各的口径（视频字幕裸 `runes.length`、EPUB/漫画/
/// galgame 各自一套）收敛到一个原语上：Dart 侧 `countStudyChars`、JS 侧
/// `window.fushiStudyUnits`。但收敛完之后，**把任何一条路径改回旧口径，全套测试照绿**：
///
///   · `video_watch_tracker.dart` 的 `countStudyChars(_pendingCueText)` 改回
///     `_pendingCueText.runes.length` → 3262 例全绿（实测）；
///   · `reader_selection_scripts.dart` 里的调用点漏改一个（`fushiStudyUnits.isUnitEnd`
///     换回 `fushiReader.isMatchableChar`）→ 1445 例全绿（实测）。
///
/// 第二条的症状正是这条 PR 要防的那一个：`charOffset` 用错口径写进 DB，**续读位置静默
/// 偏移，不崩不报错**。行为测试抓不到它，因为每条路径单看都自洽——错的是「四条路径之间
/// 是否同源」，那是结构不变式，只有源码扫描能钉。
///
/// 三组断言，各防一个方向：
///   A. 四条 Dart 写入路径都必须调 `countStudyChars`，且自己不得再出现裸码点计数；
///   B. 全仓兜底：`.runes.length` / `.characters.length` 只许出现在白名单里那几处
///      **非学习字数**用途（日志截断 / 排版 / 查词索引 / 输入校验 / 富文本区间）；
///   C. JS 侧做**计数/偏移**的函数一律走 `fushiStudyUnits`，做 **cue 匹配/归一化**的
///      一律留 `isMatchableChar`——按行为分组，不按行号。两个方向都断言，避免「一刀切
///      全换成 fushiStudyUnits」把有声书 cue 匹配也顺手换掉。
void main() {
  // ── A. 四条学习字数写入路径 ──
  //
  // 每个域一条，路径写死是**故意**的：这四条就是全部的记账入口，新增第五条属于设计
  // 变更，应该由改动者显式把它加进这张表（顺带被 B 组的全仓兜底逼着表态）。
  // 文件不存在直接红（重命名不许静默放行）。
  const Map<String, String> studyCharWritePaths = <String, String>{
    'EPUB 阅读器（每章 characters）': 'lib/src/epub/epub_book.dart',
    '漫画（每页 charsRead）': 'lib/src/media/manga/manga_reading_stats.dart',
    '视频字幕（StudyClock.addChars）': 'lib/src/media/video/video_watch_tracker.dart',
    'galgame（活动累加器）': 'lib/src/mining/galgame_char_count.dart',
  };

  group('A. 四条学习字数写入路径同源', () {
    studyCharWritePaths.forEach((String domain, String path) {
      test('[$domain] 走 countStudyChars，且自己不再裸数码点', () {
        final File f = File(path);
        expect(f.existsSync(), isTrue,
            reason: '$path 不在了。学习字数写入路径重命名/删除必须同步改这张表，'
                '否则守卫会静默退化成零断言。');
        // 剥注释：video_watch_tracker.dart 的注释里就写着「此前是裸 runes.length」，
        // 不剥的话反向断言会被自己的迁移说明命中。
        final String src = maskComments(f.readAsStringSync());
        expect(src.contains('countStudyChars('), isTrue,
            reason: '$path 不再调 countStudyChars —— $domain 这一条又自己算了一套口径。\n'
                '四个域的字数进的是同一列（study_segments.chars），口径不同源时'
                '跨媒体的每日目标与热力图本身就不成立。');
        for (final String naked in const <String>[
          '.runes.length',
          '.characters.length',
        ]) {
          expect(src.contains(naked), isFalse,
              reason: '$path 里出现了 $naked —— 学习字数写入路径不许裸数码点/字素，'
                  '一律走 countStudyChars（lib/src/stats/study_char_count.dart）。');
        }
      });
    });
  });

  // ── B. 全仓兜底：裸码点计数只许留在白名单里那几处非学习字数用途 ──
  //
  // A 组只钉住已知的四条路径；新加的第五条写入路径（新媒体类型）不会出现在那张表里。
  // 这一组反过来扫全树，逼任何新的 `.runes.length` / `.characters.length` 显式表态：
  // 要么它是学习字数（那就该用 countStudyChars），要么它是普通长度（那就登记进来）。
  group('B. 裸码点/字素计数的全仓白名单', () {
    test('lib/ 与 packages/*/lib 下没有未登记的裸码点计数', () {
      // 路径（正斜杠、相对本测试的扫描根）→ 允许出现的**次数**。数量也钉住：同一文件
      // 里多冒出一处同样要表态，这正是「漏改一个」的形状。
      const Map<String, int> allowed = <String, int>{
        // 超时兜底日志里报文本长度，不进统计。
        'lib/src/media/audiobook/audiobook_clip_text_render.dart': 1,
        // 有声书片段排版：决定字号/换行的文本长度，不进统计。
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart': 1,
        // 判断是否「逐字 cue」（per-character cue），不是计数。
        'lib/src/media/video/video_subtitle_jump_panel.dart': 1,
        // BUG-442：词典查询输入长度上限保护，是校验不是记账。
        'lib/src/models/app_model.dart': 1,
        // 词典查词高亮索引带（indexTape）构建时的码点遍历。
        'packages/fushi_dictionary/lib/src/language/language.dart': 1,
        // 字幕富文本 span 的 grapheme 偏移区间计算。
        'packages/fushi_audio/lib/src/parsers/subtitle_markup.dart': 1,
      };

      final RegExp naked = RegExp(r'\.(runes|characters)\.length\b');
      final Map<String, int> found = <String, int>{};
      int scanned = 0;

      void scan(Directory root, String prefix) {
        if (!root.existsSync()) return;
        for (final FileSystemEntity e in root.listSync(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          if (e.path.endsWith('.g.dart')) continue;
          scanned++;
          final String src = maskComments(e.readAsStringSync());
          final int n = naked.allMatches(src).length;
          if (n == 0) continue;
          final String norm = e.path.replaceAll(r'\', '/');
          found['$prefix${norm.substring(norm.indexOf('lib/'))}'] = n;
        }
      }

      scan(Directory('lib'), '');
      final Directory pkgs = Directory('../packages');
      expect(pkgs.existsSync(), isTrue,
          reason: '../packages 不存在——测试的工作目录不是 fushi/，扫描面塌了');
      for (final FileSystemEntity pkg in pkgs.listSync()) {
        if (pkg is! Directory) continue;
        final String name = pkg.path.replaceAll(r'\', '/').split('/').last;
        scan(Directory('${pkg.path}/lib'), 'packages/$name/');
      }
      expectScanScale(scanned,
          what: 'fushi/lib + packages/*/lib 下的 .dart',
          atLeast: 900,
          measured: 1210);

      final List<String> offenders = <String>[];
      found.forEach((String path, int n) {
        final int? cap = allowed[path];
        if (cap == null) {
          offenders.add('$path: $n 处（未登记）');
        } else if (n != cap) {
          offenders.add('$path: $n 处（白名单登记的是 $cap 处）');
        }
      });
      // 白名单里登记了、实际却一处都没有 = 那处被删了或被改成 countStudyChars 了；
      // 不清理白名单，它就会一直替某个不存在的用途留着口子。
      for (final String path in allowed.keys) {
        if (!found.containsKey(path)) {
          offenders.add('$path: 白名单登记了但一处都没扫到（白名单该清了）');
        }
      }
      expect(offenders, isEmpty,
          reason: '`.runes.length` / `.characters.length` 的白名单对不上：\n'
              '${offenders.join('\n')}\n\n'
              '如果它是**学习字数**，改用 countStudyChars'
              '（lib/src/stats/study_char_count.dart）；\n'
              '如果它是普通字符串长度（日志/排版/校验/索引），把它登记进本测试的白名单'
              '并写清用途。');
    });
  });

  // ── C. JS 侧：计数走 fushiStudyUnits，cue 匹配留 isMatchableChar ──
  //
  // 判据按**行为分组**（函数名），不按行号——行号会随任何编辑漂移，漂移后的守卫要么
  // 假红要么假绿。两个方向都断言：
  //   · 计数函数里出现 isMatchableChar = 「调用点漏改一个」，charOffset 静默偏移；
  //   · cue 匹配函数里出现 fushiStudyUnits = 「一刀切全换」，有声书高亮对不上音频。
  const String paginationPath = 'lib/src/reader/reader_pagination_scripts.dart';
  const String selectionPath = 'lib/src/reader/reader_selection_scripts.dart';
  const String vnPath = 'lib/src/reader/reader_visual_novel_scripts.dart';

  // `<文件>|<JS 函数头>` → **逐个出现**必须命中的证据串（按文件出现顺序）。
  //
  // 列表长度即「这个函数在文件里有几份实现」：分页 shell 与连续 shell 各有一份
  // `getFirstVisibleCharOffset` / `scrollToCharOffset`，VN 有一份真实现加一份转发。
  // 长度也是断言的一部分——多冒出一份没登记的实现就红，这正是「漏改一个」的形状。
  //
  // 证据串两种：
  //   · `fushiStudyUnits` —— 自己就在数，必须走学习单位原语；
  //   · 某个**已被本表钉住**的计数函数名 —— 它只是转发，被转发方已在表里。
  //     转发是合法的，但转发目标必须自己也在本表内，否则等于开了后门。
  const Map<String, List<String>> countingFns = <String, List<String>>{
    '$paginationPath|countChars: function(text) {': <String>['fushiStudyUnits'],
    '$paginationPath|countCharsBeforeViewport: function(': <String>[
      'fushiStudyUnits'
    ],
    '$paginationPath|countCharsBeforeViewportPaged: function(': <String>[
      'fushiStudyUnits'
    ],
    // 分页 shell（2512）与连续 shell（3080）各一份，两份都自己数。
    '$paginationPath|getFirstVisibleCharOffset: function() {': <String>[
      'fushiStudyUnits',
      'fushiStudyUnits'
    ],
    // 分页版自己数；连续版转发给 collapsedRangeAtCharOffset（下一条已钉）。
    '$paginationPath|scrollToCharOffset: function(': <String>[
      'fushiStudyUnits',
      'collapsedRangeAtCharOffset'
    ],
    '$paginationPath|collapsedRangeAtCharOffset: function(': <String>[
      'fushiStudyUnits'
    ],
    '$selectionPath|getNormalizedOffset: function(': <String>[
      'fushiStudyUnits'
    ],
    // 87 行是真实现；143 行是 ReaderVnContentStream 里的转发。
    '$vnPath|countChars(text) {': <String>[
      'fushiStudyUnits',
      'textSemantics().countChars'
    ],
    '$vnPath|textItems: function() {': <String>['fushiStudyUnits'],
  };
  const List<List<String>> cueMatchingFns = <List<String>>[
    <String>[paginationPath, 'buildSentenceAudioNormIndex: function() {'],
    <String>[vnPath, 'collectMatchableSegments: function('],
  ];

  /// 按**缩进**取 JS 函数体：从函数头那一行起，到第一条「与函数头同缩进的收口行」
  /// （`}` / `},` / `};`）为止。
  ///
  /// 不用花括号配对：这些 JS 活在 Dart 三引号原始串里，跨词法边界配对是已知的踩雷点
  /// （串里的花括号会把配对带偏）。这三份文件的 JS 缩进稳定，行锚点确定。
  /// 同名函数（分页 shell 与连续 shell 各有一个 `getFirstVisibleCharOffset`）**全部**
  /// 取出来逐个断言，不许只看第一个。
  ///
  /// [source] **必须**是 [maskCommentsAndScriptLines] 掩过的：这些 JS 活在 Dart 三引号
  /// 原始串里，光用 [maskComments]（Dart 词法器，按设计保留串内容）会把串里的 JS 注释
  /// 原样留下 —— 于是 `textItems` 里那句「有声书 cue 的 collectMatchableSegments 仍走
  /// isMatchableChar」注释会先被 `contains` 命中，把一条本该绿的反向断言变成恒红。
  /// 共享掩码是**等长**的（注释字符换空白、不删行），行数与缩进都不漂移，所以下面
  /// 按缩进取收口行的锚点照旧成立。手写剥注释是全仓禁用形态（守卫
  /// `test/tools/source_guard_adoption_test.dart`）：它放过块注释与行尾注释，
  /// 删行还会让下标与原文错位。
  List<String> jsFunctionBodies(String source, String header) {
    final List<String> lines = source.split('\n');
    final List<String> bodies = <String>[];
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final int at = line.indexOf(header);
      if (at < 0) continue;
      // 注释行里的同名文本不算（这三份文件的注释里确实反复提到这些函数名）。
      if (line.substring(0, at).contains('//')) continue;
      final String indent = RegExp(r'^\s*').firstMatch(line)!.group(0)!;
      final StringBuffer body = StringBuffer();
      bool closed = false;
      for (int j = i + 1; j < lines.length; j++) {
        final String trimmedRight = lines[j].trimRight();
        if (trimmedRight == '$indent}' ||
            trimmedRight == '$indent},' ||
            trimmedRight == '$indent};') {
          closed = true;
          break;
        }
        body.writeln(lines[j]);
      }
      expect(closed, isTrue,
          reason: '取不到 `$header` 的函数体收口行（缩进 ${indent.length} 空格）。'
              '缩进变了就换锚点，别把守卫留在恒不匹配的状态上——那等于零断言。');
      bodies.add(body.toString());
    }
    return bodies;
  }

  group('C. JS 计数口径按行为分组', () {
    countingFns.forEach((String key, List<String> evidence) {
      final int bar = key.indexOf('|');
      final String path = key.substring(0, bar);
      final String header = key.substring(bar + 1);
      test('[计数] ${path.split('/').last} · $header 走学习单位口径', () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 不在了');
        // Dart 注释 + 三引号串内的 JS 注释一起掩（等长掩码，下标不漂移）。
        final List<String> bodies = jsFunctionBodies(
            maskCommentsAndScriptLines(f.readAsStringSync()), header);
        expect(bodies.length, evidence.length,
            reason: '$path 里 `$header` 有 ${bodies.length} 份实现，本表登记了 '
                '${evidence.length} 份。\n'
                '多出来的那份没被任何断言盯着 —— 这正是「调用点漏改一个」的形状；'
                '少了则是函数改名/删除，同步改表。');
        for (int i = 0; i < bodies.length; i++) {
          final String body = bodies[i];
          expect(body.contains(evidence[i]), isTrue,
              reason: '$path 的 `$header`（第 ${i + 1} 处）里找不到 '
                  '`${evidence[i]}`。\n'
                  '这是**计数/偏移**函数，口径必须与 Dart countStudyChars 同源'
                  '（自己数就走 window.fushiStudyUnits，转发就转给本表里的另一条）；'
                  '换回逐码点判据会让 charOffset 用错口径写进 DB —— '
                  '续读位置静默偏移，不崩不报错。');
          expect(body.contains('isMatchableChar'), isFalse,
              reason: '$path 的 `$header`（第 ${i + 1} 处）里出现了 isMatchableChar。\n'
                  'isMatchableChar 是**有声书 cue 匹配/归一化**的白名单判据，'
                  '不是学习单位判据；拿它做计数就是「调用点漏改一个」的形状。');
        }
      });
    });

    for (final List<String> entry in cueMatchingFns) {
      final String path = entry[0];
      final String header = entry[1];
      test('[cue 匹配] ${path.split('/').last} · $header 保留 isMatchableChar', () {
        final File f = File(path);
        expect(f.existsSync(), isTrue, reason: '$path 不在了');
        final List<String> bodies = jsFunctionBodies(
            maskCommentsAndScriptLines(f.readAsStringSync()), header);
        expect(bodies, isNotEmpty, reason: '$path 里找不到 `$header`');
        for (final String body in bodies) {
          expect(body.contains('isMatchableChar'), isTrue,
              reason: '$path 的 `$header` 丢了 isMatchableChar。\n'
                  '这是有声书 cue 与 DOM 文本的**归一化匹配**，口径必须与音频侧的'
                  'AudioTextNormalizer 一致，不是学习单位口径。');
          expect(body.contains('fushiStudyUnits'), isFalse,
              reason: '$path 的 `$header` 改用了 fushiStudyUnits。\n'
                  '把 cue 匹配也一刀切换成学习单位判据，会让有声书高亮与音频对不上。');
        }
      });
    }

    test('取函数体的锚点自身可信（不会把相邻函数一起吞进来）', () {
      final String src =
          maskCommentsAndScriptLines(File(selectionPath).readAsStringSync());
      final List<String> bodies =
          jsFunctionBodies(src, 'getNormalizedOffset: function(');
      expect(bodies.length, 1);
      final String body = bodies.single;
      expect(body.contains('fushiStudyUnits.isUnitEnd'), isTrue);
      // 紧邻的下一个函数不得被吞进来——否则「这个函数里有没有 X」的断言就没意义了。
      expect(body.contains('clearHighlightWrappers: function'), isFalse,
          reason: '函数体收口失败，把下一个方法也吞进来了');
    });
  });
}

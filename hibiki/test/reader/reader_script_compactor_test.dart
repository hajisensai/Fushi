import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_script_compactor.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

/// TODO-perf（跨章）：setup 脚本注入前的整行注释/空行剥离必须是**语义等价**的——
/// 它跑在每次跨章的热路径上，一旦剥错行就是整本书白屏。
///
/// 三层覆盖：
/// 1. 手写词法地雷用例（注释/引号串/正则里的反引号、`${}` 嵌套）——预期输出手写，
///    与实现无关，直接钉住「反引号只在代码区才计数」这条根因修复。
/// 2. **全部**真实注入 JS 载荷（selection / longPressDrag / caret / 分页 / 连续 / VN
///    三种 shell）——断言扫描器扫完干净、被删的每一行都确实是空行或整行注释、幂等。
/// 3. 用 node `--check` 真解析：把 `webview.part.dart` 里那份**最终拼装脚本**按真实
///    组件重建出来（821 行外壳 + 各真实载荷），压缩前后都必须是合法 JS。这才是生产上
///    真正被 compact 的东西，此前一行测试都没有。
void main() {
  group('ReaderScriptCompactor.compact', () {
    test('剥掉整行注释与空行', () {
      const String src = '''
// 整行注释
var a = 1;

  // 缩进的整行注释
var b = 2;
''';
      expect(ReaderScriptCompactor.compact(src), 'var a = 1;\nvar b = 2;');
    });

    test('保留行内尾注释与代码里的 //（URL / 正则）', () {
      const String src = '''
var u = 'https://hoshi.local/epub/x.xhtml';
var re = /[^/]+/g;
var c = 3; // 尾注释保留
''';
      expect(ReaderScriptCompactor.compact(src), src.trimRight());
    });

    test('模板字符串内部的注释样式行与空行原样保留', () {
      const String src = r'''
var t = `line1
// 这不是注释，是模板里的数据

line2`;
var d = 4;
''';
      expect(ReaderScriptCompactor.compact(src), src.trimRight());
    });

    test('转义反引号不误翻模板状态', () {
      const String src = r'''
var s = 'a \` b';
// 该删
var e = 5;
''';
      expect(
          ReaderScriptCompactor.compact(src), "var s = 'a \\` b';\nvar e = 5;");
    });
  });

  // 根因修复的核心：旧实现按「本行未转义反引号奇偶」翻转模板态，把注释/引号串/正则里的
  // 反引号也算进去。下面每一条在旧实现下都会剥错行（或漏剥），预期输出全部手写。
  group('ReaderScriptCompactor 词法地雷', () {
    test('注释里的单个反引号不会把后续模板串当成代码区', () {
      const String src = '''
// 用 `hoshiReader 包一层（奇数个反引号）
var css = `body {

  color: red;
}`;
// 该删
var z = 1;
''';
      // 模板串内部的空行必须原样留着；只有两行真注释被剥。
      expect(
          ReaderScriptCompactor.compact(src),
          'var css = `body {\n'
          '\n'
          '  color: red;\n'
          '}`;\n'
          'var z = 1;');
    });

    test('块注释里的反引号同样不计数', () {
      const String src = '''
/* 说明：`a` 与 `b`
   跨两行 */
var t = `x

y`;
''';
      expect(ReaderScriptCompactor.compact(src), src.trimRight());
    });

    test('引号串里的反引号不计数', () {
      const String src = '''
var a = "prefix ` suffix";
// 该删
var t = `x

y`;
''';
      expect(ReaderScriptCompactor.compact(src),
          'var a = "prefix ` suffix";\nvar t = `x\n\ny`;');
    });

    test('正则字面量里的反引号不计数', () {
      const String src = '''
var re = /[`]/g;
// 该删
var t = `x

y`;
''';
      expect(ReaderScriptCompactor.compact(src),
          'var re = /[`]/g;\nvar t = `x\n\ny`;');
    });

    test('模板 \${} 内是代码区：里面的整行注释该剥，模板数据行不剥', () {
      const String src = '''
var t = `head
\${
  // 这是代码区的注释，该剥
  compute()
}

tail`;
''';
      expect(
          ReaderScriptCompactor.compact(src),
          'var t = `head\n'
          '\${\n'
          '  compute()\n'
          '}\n'
          '\n'
          'tail`;');
    });

    test('scansCleanly 认得未闭合的模板串与块注释', () {
      expect(ReaderScriptCompactor.scansCleanly('var t = `a`;\n'), isTrue);
      expect(ReaderScriptCompactor.scansCleanly('var t = `a;\n'), isFalse);
      expect(ReaderScriptCompactor.scansCleanly('/* open\n'), isFalse);
      // 注释里的反引号不再让状态跑偏。
      expect(ReaderScriptCompactor.scansCleanly('// `\nvar a = 1;\n'), isTrue);
    });
  });

  group('真实注入脚本（全部载荷）', () {
    final Map<String, String> payloads = _realPayloads();

    test('覆盖到全部真实载荷（含体量最大的 pagination 与三种 shell）', () {
      expect(
        payloads.keys.toSet(),
        <String>{
          'selection',
          'longPressDrag',
          'caret',
          'pagination.paginated',
          'pagination.continuous',
          'pagination.vn',
          'setupScript',
        },
        reason: '新增参与拼装的 JS 载荷必须同时纳入本守卫，否则压缩器对它零覆盖',
      );
    });

    for (final MapEntry<String, String> entry in payloads.entries) {
      final String name = entry.key;
      final String src = entry.value;

      test('$name：词法扫描扫完干净', () {
        expect(ReaderScriptCompactor.scansCleanly(src), isTrue,
            reason: '$name 扫完后仍停在模板串 / 块注释 / \${} 内——要么脚本本身不完整，'
                '要么有扫描器读不懂的写法。此时压缩结果不可信，禁止静默通过。');
      });

      test('$name：只删空行与整行注释，一行代码都不许丢', () {
        final String out = ReaderScriptCompactor.compact(src);
        for (final String removed in _removedLines(src, out)) {
          final String trimmed = removed.trim();
          expect(trimmed.isEmpty || trimmed.startsWith('//'), isTrue,
              reason: '$name 被剥掉了非注释行：${_preview(removed)}');
        }
      });

      test('$name：幂等（再压一次不变）', () {
        final String once = ReaderScriptCompactor.compact(src);
        expect(ReaderScriptCompactor.compact(once), once,
            reason: '$name 二次压缩结果变化 = 词法状态在首次压缩后错位');
      });
    }

    test('大载荷的注释/空行占一成以上（压缩确实在省东西）', () {
      for (final String name in <String>[
        'caret',
        'selection',
        'pagination.paginated',
        'pagination.continuous',
        'setupScript',
      ]) {
        final String src = payloads[name]!;
        final String out = ReaderScriptCompactor.compact(src);
        final double saved = 1 - out.length / src.length;
        expect(saved, greaterThan(0.1),
            reason: '$name 实测省 ${(saved * 100).toStringAsFixed(1)}%');
      }
    });
  });

  group('压缩后仍是合法 JS（node --check 真解析）', () {
    final String? nodeExe = _resolveNode();
    final Map<String, String> payloads = _realPayloads();

    for (final MapEntry<String, String> entry in payloads.entries) {
      test('${entry.key}：压缩前后都能被 JS 引擎解析', () async {
        if (nodeExe == null) {
          markTestSkipped('node not found on PATH; skipping JS syntax check');
          return;
        }
        final String src = entry.value;
        final String before = await _nodeCheck(nodeExe, entry.key, src);
        if (before.isNotEmpty) {
          // 原始载荷本身不是可独立解析的完整脚本（例如只是对象字面量片段）——
          // 那就没有「压缩破坏了它」这一说，跳过而不是假阳。
          markTestSkipped('${entry.key} 原始载荷不可独立解析：$before');
          return;
        }
        final String after = await _nodeCheck(
            nodeExe, entry.key, ReaderScriptCompactor.compact(src));
        expect(after, isEmpty,
            reason: '${entry.key} 压缩后解析失败 = 线上白屏。node 输出：\n$after');
      });
    }
  });
}

/// 全部真正被 [ReaderScriptCompactor.compact] 处理过的 JS 载荷。
///
/// `setupScript` 是**最终拼装脚本**——生产上 `_buildReaderSetupScript` 交给压缩器的正是
/// 它。它由 `webview.part.dart` 里那段 821 行的外壳模板 + 各真实子载荷拼成，这里按同一
/// 份源码重建（见 [_assembledSetupScript]），不复制粘贴、不会漂。
Map<String, String> _realPayloads() {
  final String paginated =
      _stripScriptTags(ReaderPaginationScripts.shellScript());
  return <String, String>{
    'selection': ReaderSelectionScripts.source(),
    'longPressDrag': ReaderSelectionScripts.longPressDragGestureScript(),
    'caret': ReaderCaretScripts.source(),
    'pagination.paginated': paginated,
    'pagination.continuous': _stripScriptTags(
        ReaderPaginationScripts.shellScript(continuousMode: true)),
    'pagination.vn':
        _stripScriptTags(ReaderPaginationScripts.shellScript(vnMode: true)),
    'setupScript': _assembledSetupScript(paginated),
  };
}

/// 从 `webview.part.dart` 抠出 `_buildReaderSetupScript` 的那段 Dart 三引号模板，把每个
/// 插值换成真实子载荷（或语法上等价的标量替身），还原成生产上真正被压缩的整份脚本。
///
/// 插值一旦新增/改名，[_setupPlaceholders] 里没有对应替身就直接 fail——不会静默漏覆盖。
String _assembledSetupScript(String paginationJs) {
  final File part = File(
    'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
  );
  if (!part.existsSync()) {
    throw StateError('${part.path} 必须存在');
  }
  final String source = part.readAsStringSync();
  const String opener = "return ReaderScriptCompactor.compact('''";
  final int start = source.indexOf(opener);
  if (start < 0) {
    throw StateError('_buildReaderSetupScript 的压缩入口变了，本守卫需同步更新');
  }
  String body = source.substring(start + opener.length);
  final int end = body.indexOf("\n''');");
  if (end <= 0) {
    throw StateError('setup 模板的收尾三引号没找到');
  }
  body = body.substring(0, end);

  // Dart 非 raw 三引号串里唯一出现的反斜杠转义是 `\.`（未知转义 = 字符本身）。
  // 出现别的转义就说明重建逻辑需要扩展，直接失败而不是悄悄错。
  final RegExp escapes = RegExp(r'\\(.)');
  for (final RegExpMatch m in escapes.allMatches(body)) {
    if (m.group(1) != '.') {
      throw StateError('setup 模板出现新的转义 \${m.group(1)}，重建逻辑需同步');
    }
  }
  body = body.replaceAll(r'\.', '.');

  final Map<String, String> subs = <String, String>{
    r'$selectionJs': ReaderSelectionScripts.source(),
    r'$paginationJs': paginationJs,
    r'$caretJs': ReaderCaretScripts.source(),
    r'$caretInit': ReaderCaretScripts.initInvocation(
        color: 'rgba(0,0,0,0.5)', insetTop: 0, insetBottom: 0),
    // _buildFuriganaJs 是 State 私有方法，测试拿不到；它是十几行无反引号的纯代码，
    // 用占位注释顶上（拼装外壳与其余载荷才是本守卫的目标）。
    r'$furiganaJs': '/* furigana placeholder */',
    r'$longPressDragJs': ReaderSelectionScripts.longPressDragGestureScript(),
    r'$swipeFastDistThreshold': '22',
    r'$swipeDistThreshold': '44',
    r'$tapSlop': '10',
    r'$continuousMode': 'false',
    r'$hoverAutoLookup': 'false',
    r'$vnClickAdvance': 'false',
    r'$vnMode': 'false',
    r'$_showChrome': 'false',
    r'${DebugLogService.instance.enabled}': 'false',
    r'${ReaderHibikiSource.instance.highlightOnTap}': 'false',
    r'${appModel.scanNonJapaneseText}': 'false',
  };
  final RegExp placeholder = RegExp(r'\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*');
  return body.replaceAllMapped(placeholder, (Match m) {
    final String key = m.group(0)!;
    final String? value = subs[key];
    if (value == null) {
      throw StateError('setup 模板新增插值 $key，请在本守卫里给出替身，'
          '否则最终拼装脚本的压缩就没有覆盖');
    }
    return value;
  });
}

String _stripScriptTags(String js) => js
    .replaceFirst(RegExp(r'^<script[^>]*>\n?'), '')
    .replaceFirst(RegExp(r'\n?</script>$'), '');

/// [out] 相对 [src] 被删掉的行。顺带证明 [out] 是 [src] 的行子序列（行内容零改写）。
List<String> _removedLines(String src, String out) {
  final List<String> before = src.split('\n');
  final List<String> after = out.split('\n');
  final List<String> removed = <String>[];
  int j = 0;
  for (final String line in before) {
    if (j < after.length && after[j] == line) {
      j++;
      continue;
    }
    removed.add(line);
  }
  expect(j, after.length, reason: '压缩结果不是原脚本的行子序列 = 有行被改写，不只是被删');
  return removed;
}

String _preview(String line) {
  final String trimmed = line.trim();
  return trimmed.length <= 120 ? trimmed : '${trimmed.substring(0, 120)}…';
}

/// 用 `node --check` 真解析一份 JS；返回空串 = 语法合法，否则返回 node 的报错。
Future<String> _nodeCheck(String nodeExe, String label, String js) async {
  final Directory dir =
      await Directory.systemTemp.createTemp('hibiki_js_check_');
  try {
    final File file = File('${dir.path}/${label.replaceAll('.', '_')}.js');
    await file.writeAsString(js);
    final ProcessResult result =
        await Process.run(nodeExe, <String>['--check', file.path]);
    if (result.exitCode == 0) return '';
    final String err = result.stderr.toString().trim();
    return err.isEmpty ? 'exit=${result.exitCode}' : err;
  } finally {
    await dir.delete(recursive: true);
  }
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
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

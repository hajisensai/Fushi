import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/reader/reader_caret_scripts.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_visual_novel_scripts.dart';
import 'package:fushi/src/reader/reader_script_compactor.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// TODO-perf（跨章）：setup 脚本注入前的整行注释/空行剥离必须是**语义等价**的——
/// 它跑在每次跨章的热路径上，一旦剥错行就是整本书白屏。
///
/// 三层覆盖：
/// 1. 手写词法地雷用例（注释/引号串/正则里的反引号、`${}` 嵌套）——预期输出手写，
///    与实现无关，直接钉住「反引号只在代码区才计数」这条根因修复。
/// 2. **全部**真实注入 JS 载荷（selection / longPressDrag / caret / 分页 / 连续 / VN
///    三种 shell）——断言扫描器扫完干净、被删的每一行都确实是空行或整行注释、幂等。
/// 3. 用 node `--check` 真解析：**最终拼装脚本**（= 引擎源码，
///    `readerFushiEngineSourceUncompacted()`）压缩前后都必须是合法 JS。这才是生产上
///    真正被 compact 的东西。
/// 4. **装配完整性**（见 group「setup 装配完整性」）：reader 侧还有约 100 条守卫只断言
///    某个生成函数**返回的字符串**里含某符号——它们证明不了这个串真的被拼进最终注入的
///    脚本。本层堵的是这个单向漏洞：对最终产物断言各子载荷**整段原样在场** + 运行时
///    哨兵在场。
///
///    BUG-1140 第二阶段①之前，最终脚本是把 `webview.part.dart` 的三引号模板抠出来、
///    按一张手写替身表重建的；那张表对**新增**插值会抛 StateError（响亮），对**删除**
///    插值完全静默，只能靠额外收集「命中键」来兜。现在引擎是零插值的静态源码，直接向
///    生产代码要同一份对象，重建与漂移一起没有了。
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
var u = 'https://fushi.local/epub/x.xhtml';
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
// 用 `fushiReader 包一层（奇数个反引号）
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
          'keyBridge.space',
          'pagination.paginated',
          'pagination.continuous',
          'pagination.vn',
          'engine',
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
        'engine',
      ]) {
        final String src = payloads[name]!;
        final String out = ReaderScriptCompactor.compact(src);
        final double saved = 1 - out.length / src.length;
        expect(saved, greaterThan(0.1),
            reason: '$name 实测省 ${(saved * 100).toStringAsFixed(1)}%');
      }
    });
  });

  // 单向漏洞的封口：模板里**删掉**一个插值（整个子载荷不再注入）此前完全静默——
  // 那约 100 条只断言「生成函数返回的串里含某符号」的守卫照样全绿。
  // 本组是「被注入」这件事的唯一集中证据，不要求那 100 条各自再证一遍。
  group('setup 装配完整性（子载荷真的被拼进最终脚本）', () {
    // 三种 view-mode 各自的最终拼装脚本（生产上真正交给压缩器的那份）。
    final Map<String, String> assembledByMode = <String, String>{
      'paged': readerFushiEngineSourceUncompacted(),
      'continuous': readerFushiEngineSourceUncompacted(continuousMode: true),
      'vn': readerFushiEngineSourceUncompacted(vnMode: true),
    };
    final String assembled = assembledByMode['paged']!;

    // 载荷是**字面**拼接，所以每个子载荷必须整段原样出现在产物里。这是「被拼进去」
    // 最强的直接证据：哨兵符号会因为外壳/兄弟载荷里也出现同名符号而假绿（实测删掉
    // caret 载荷后 `window.fushiCaret` 仍在——它由 caret 初始化调用带进来），整段比对不会。
    test('最终脚本里各子载荷整段原样在场', () {
      final Map<String, String> payloads = <String, String>{
        'selection': ReaderSelectionScripts.source(),
        'caret': ReaderCaretScripts.source(),
        'longPressDrag': ReaderSelectionScripts.longPressDragGestureScript(),
        'keyBridge': webViewKeyBridgeScript(
          handlerName: 'onSpaceKey',
          keys: const <String>[' '],
        ),
      };
      for (final MapEntry<String, String> entry in payloads.entries) {
        expect(assembled, contains(entry.value),
            reason: '${entry.key} 载荷没有整段出现在最终注入脚本里——'
                '它没被拼进引擎，注入后整块功能是死的');
      }
      // 每种 view-mode 的引擎必须整段带上**自己那一份** shell。
      final Map<String, String> shells = <String, String>{
        'paged':
            _stripScriptTags(ReaderPaginationScripts.paginatedShellSource()),
        'continuous':
            _stripScriptTags(ReaderPaginationScripts.continuousShellSource()),
        'vn': _stripScriptTags(ReaderVisualNovelScripts.vnShellScript()),
      };
      shells.forEach((String mode, String shell) {
        expect(assembledByMode[mode]!, contains(shell),
            reason: '$mode 引擎没有整段带上自己那一份 shell');
      });
    });

    test('最终脚本里各子载荷的运行时哨兵同时在场', () {
      const Map<String, String> sentinels = <String, String>{
        'selection': 'window.fushiSelection',
        'pagination': 'window.fushiReader',
        'caret': 'window.fushiCaret',
        'longPressDrag': '__fushiTextSelectDragActive',
        'keyBridge': "'onSpaceKey'",
      };
      for (final MapEntry<String, String> entry in sentinels.entries) {
        expect(assembled, contains(entry.value),
            reason: '最终注入脚本里找不到 ${entry.key} 的哨兵 ${entry.value}——'
                '该载荷没被拼进引擎，注入后整块功能是死的');
      }
    });

    test('压缩之后哨兵依然在场（压缩不得吃掉任何子载荷）', () {
      final String compacted = ReaderScriptCompactor.compact(assembled);
      for (final String sentinel in <String>[
        'window.fushiSelection',
        'window.fushiReader',
        'window.fushiCaret',
        '__fushiTextSelectDragActive',
        "'onSpaceKey'",
      ]) {
        expect(compacted, contains(sentinel),
            reason: '压缩后 $sentinel 消失 = 压缩器剥掉了真代码');
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
/// `engine` 是**最终拼装脚本**——生产上交给压缩器的正是它（`_buildReaderEngineSource`
/// 的返回值，经 `readerFushiEngineSourceUncompacted()` 直接取到）。
///
/// BUG-1140 第二阶段①之前，这里是把 `webview.part.dart` 的三引号模板抠出来、按一张
/// 手写 `subs` 替身表重建一遍。那张表是**查找表**：新增插值会 fail，**删掉**一个载荷
/// （比如 `$caretJs` 不再拼进去）却完全静默——整份注入物少了一块，压缩覆盖跟着少一块，
/// 而没有一条测试会红。现在引擎是零插值的静态源码，直接向生产代码要同一份对象，
/// 那个不对称从根上没有了。
Map<String, String> _realPayloads() {
  return <String, String>{
    'selection': ReaderSelectionScripts.source(),
    'longPressDrag': ReaderSelectionScripts.longPressDragGestureScript(),
    'caret': ReaderCaretScripts.source(),
    // PR#480 的裸 Space 键盘桥：它同样被拼进引擎后一起压缩，必须有独立的
    // scansCleanly / 幂等 / node --check 覆盖，不能只靠 engine 顺带带过。
    'keyBridge.space': webViewKeyBridgeScript(
      handlerName: 'onSpaceKey',
      keys: const <String>[' '],
    ),
    'pagination.paginated':
        _stripScriptTags(ReaderPaginationScripts.paginatedShellSource()),
    'pagination.continuous':
        _stripScriptTags(ReaderPaginationScripts.continuousShellSource()),
    'pagination.vn': _stripScriptTags(ReaderVisualNovelScripts.vnShellScript()),
    'engine': readerFushiEngineSourceUncompacted(),
  };
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

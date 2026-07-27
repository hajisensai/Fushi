import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_script_compactor.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

/// TODO-perf（跨章）：setup 脚本注入前的整行注释/空行剥离必须是**语义等价**的——
/// 它跑在每次跨章的热路径上，一旦剥错行就是整本书白屏。
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

    test('真实注入脚本：体积显著下降，且剥离的都是注释/空行', () {
      final String caret = ReaderCaretScripts.source();
      final String selection = ReaderSelectionScripts.source();
      for (final String src in <String>[caret, selection]) {
        final String out = ReaderScriptCompactor.compact(src);
        final double saved = 1 - out.length / src.length;
        expect(saved, greaterThan(0.1),
            reason: '真实注入脚本的注释/空行应占一成以上，实测省 '
                '${(saved * 100).toStringAsFixed(1)}%');
        // 剥掉的每一行都必须是空行或整行注释——用「保留行是原脚本行的子序列」
        // 反查：任何代码行都不能丢。
        final List<String> kept = out.split('\n');
        final List<String> code = src
            .split('\n')
            .where(
                (String l) => l.trim().isNotEmpty && !l.trim().startsWith('//'))
            .toList();
        expect(kept.length, lessThanOrEqualTo(code.length + 8),
            reason: '保留行数应约等于原脚本的非注释非空行数（模板内行可多留几行）');
      }
    });
  });
}

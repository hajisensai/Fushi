import 'package:flutter_test/flutter_test.dart';

import 'source_guard.dart';

/// 共享源码扫描 helper 自身的词法单测。
///
/// 本仓的守卫全靠这套原语判红绿，它自己没测就等于全仓守卫的判据没测。四类洞
/// （TODO-2358）逐条钉在这里：
/// ① 整行注释（含带引号者）；② 含引号行的**行尾**注释；③ 块注释 `/* */`；
/// ④ methodBody 的三引号 / 引号 / 注释内花括号。
void main() {
  group('掩码是等长的（切片下标可跨串复用）', () {
    const String src = '''
// head
final a = 'x'; // tail
/* block
   more */
final b = \'\'\'{ js }\'\'\';
''';
    test('maskComments 与原文等长、换行位置一致', () {
      expect(maskComments(src).length, src.length);
      expect(
        maskComments(src).split('\n').length,
        src.split('\n').length,
      );
    });
    test('maskCommentsAndStrings 与原文等长', () {
      expect(maskCommentsAndStrings(src).length, src.length);
    });
  });

  group('① 整行注释', () {
    test('普通整行注释被清掉', () {
      expect(containsCodeLine('  // needleToken\n', 'needleToken'), isFalse);
    });
    test('带引号的整行注释也被清掉（不能因为含引号就整行放行）', () {
      expect(
        containsCodeLine("  // final u = 'x'; needleToken\n", 'needleToken'),
        isFalse,
      );
    });
    test('文档注释 /// 同样被清掉', () {
      expect(containsCodeLine('  /// needleToken\n', 'needleToken'), isFalse);
    });
  });

  group('② 含引号行的行尾注释', () {
    test("`final u = 'https://x/a'; // Fnv1a` 的 Fnv1a 不算命中", () {
      expect(
        containsCodeLine("final u = 'https://x/a'; // Fnv1a\n", 'Fnv1a'),
        isFalse,
      );
    });
    test('同一行的真代码仍然命中', () {
      expect(
        containsCodeLine("final u = 'https://x/a'; // Fnv1a\n", 'final u'),
        isTrue,
      );
    });
    test('字符串字面量里的 // 不会被当注释砍掉（不制造假红）', () {
      expect(
        containsCodeLine("const String s = 'https://example.com/a';\n",
            'https://example.com/a'),
        isTrue,
      );
    });
  });

  group('③ 块注释', () {
    test('单行块注释里的字面量不算命中', () {
      expect(containsCodeLine('/* needleToken */\n', 'needleToken'), isFalse);
    });
    test('跨行块注释里**不以 * 开头**的行也不算命中', () {
      const String body = '/* 说明\nneedleToken 在这里只是文档\n*/\n';
      expect(containsCodeLine(body, 'needleToken'), isFalse);
    });
    test('行尾块注释不算命中，行首真代码仍命中', () {
      const String body = 'final int x = 1; /* needleToken */\n';
      expect(containsCodeLine(body, 'needleToken'), isFalse);
      expect(containsCodeLine(body, 'final int x'), isTrue);
    });
    test('containsIdentifierCall 同样不吃注释里的调用', () {
      expect(containsIdentifierCall('/* Image.file( */', 'Image'), isFalse);
      expect(containsIdentifierCall('// Image.file(', 'Image'), isFalse);
      expect(
          containsIdentifierCall('final w = Image.file(f);', 'Image'), isTrue);
      expect(
        containsIdentifierCall('final w = PortraitCoverImage(x);', 'Image'),
        isFalse,
      );
    });
    test('maskCssComments 只剥块注释，等长', () {
      const String css = '.a { color: red; } /* needleToken */';
      expect(maskCssComments(css).length, css.length);
      expect(maskCssComments(css).contains('needleToken'), isFalse);
      expect(maskCssComments(css).contains('color: red'), isTrue);
    });
  });

  group('④ methodBody 的词法边界', () {
    test('三引号多行串里的花括号不参与配对（D5 硬前提）', () {
      const String src = '''
  String jsFor() {
    return \'\'\'
      function f() { if (a) { return 1; } }
    \'\'\';
  }
  String next() {
    return 'sentinel';
  }
''';
      final String body = methodBody(src, 'String jsFor()');
      expect(body.contains('function f()'), isTrue,
          reason: '方法体必须整段取到，不能在第一段 JS 的花括号处截断');
      expect(body.contains('sentinel'), isFalse, reason: '不能越界吞掉后一个方法');
    });

    test('注释里的花括号不参与配对', () {
      const String src = '''
  void a() {
    // 这里故意写一个 } 不该收口
    /* 也不该 } 收口 */
    final int x = 1;
  }
  void b() {
    final String s = 'sentinel';
  }
''';
      final String body = methodBody(src, 'void a()');
      expect(body.contains('final int x = 1;'), isTrue);
      expect(body.contains('sentinel'), isFalse);
    });

    test('单引号串里的花括号不参与配对', () {
      const String src = '''
  void a() {
    final String s = '} not a brace {';
    final int x = 1;
  }
  void b() {
    final String s2 = 'sentinel';
  }
''';
      final String body = methodBody(src, 'void a()');
      expect(body.contains('final int x = 1;'), isTrue);
      expect(body.contains('sentinel'), isFalse);
    });

    test('命名参数表的花括号不被当成方法体（PR#607 修的那类）', () {
      const String src = '''
  Widget wrap({required Widget child}) {
    return Padding(padding: EdgeInsets.zero, child: child);
  }
''';
      final String body =
          methodBody(src, 'Widget wrap({required Widget child})');
      expect(body.contains('Padding('), isTrue);
    });

    test('签名首现于文档注释时锚到真定义', () {
      const String src = '''
  /// 见 void target() 的说明。
  void other() {
    final int y = 2;
  }
  void target() {
    final String s = 'real';
  }
''';
      final String body = methodBody(src, 'void target()');
      expect(body.contains("'real'"), isTrue);
      expect(body.contains('final int y = 2;'), isFalse);
    });

    test('找不到签名时 fail，绝不返回空串', () {
      expect(
        () => methodBody('void a() {}', 'void nope()'),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('enclosingCall：窗口由括号配对给出，不靠定长/相邻声明', () {
    const String src = '''
    SettingsCustomItem(
      // 说明：换行与缩进都不该进契约
      id: 'sync.mode',
      title: t.sync_mode,
      children: <Widget>[
        Text('sync.mode'),
      ],
    ),
    SettingsSwitchItem(
      id: 'sync.statistics',
    ),
''';

    test('取到最内层调用的名字（跨注释、跨嵌套集合字面量）', () {
      expect(
          enclosingCallOf(src, "id: 'sync.mode'").name, 'SettingsCustomItem');
      expect(
        enclosingCallOf(src, "id: 'sync.statistics'").name,
        'SettingsSwitchItem',
      );
    });

    test('窗口止于该调用的右括号，不会读进下一项', () {
      final String body = enclosingCallOf(src, "id: 'sync.mode'").text;
      expect(body.contains('t.sync_mode'), isTrue);
      expect(body.contains("id: 'sync.statistics'"), isFalse);
    });

    test('锚点只认代码，注释里的同名文本不算数', () {
      const String commented = '''
    Wrapper(
      // id: 'sync.mode' 这是注释
      other: 1,
    ),
    RealItem(
      id: 'sync.mode',
    ),
''';
      expect(enclosingCallOf(commented, "id: 'sync.mode'").name, 'RealItem');
    });

    test('命名构造器与泛型实参都算进名字', () {
      const String generic = 'AdaptiveRow<int>(value: 1)';
      expect(enclosingCallOf(generic, 'value:').name, 'AdaptiveRow');
      const String named = 'EdgeInsets.symmetric(horizontal: 4)';
      expect(
          enclosingCallOf(named, 'horizontal:').name, 'EdgeInsets.symmetric');
    });

    test('找不到锚点时 fail，绝不静默锚到文件头', () {
      expect(
        () => enclosingCallOf('Foo(bar: 1)', 'nope:'),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('namedArgumentValues：取实参表达式而不是拼写', () {
    test('跨换行取整段实参，顶层逗号定右边界', () {
      const String src = '''
      Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.card,
          vertical: tokens.spacing.gap,
        ),
        child: body,
      )
''';
      final List<String> values = namedArgumentValues(src, 'insetPadding');
      expect(values.length, 1);
      expect(values.single.contains('tokens.spacing.card'), isTrue);
      expect(values.single.contains('child: body'), isFalse);
    });

    test('注释与字符串里的同名参数不算数', () {
      const String src = '''
      Dialog(
        // insetPadding: EdgeInsets.all(16),
        title: 'insetPadding: EdgeInsets.all(16)',
        insetPadding: EdgeInsets.zero,
      )
''';
      final List<String> values = namedArgumentValues(src, 'insetPadding');
      expect(values.length, 1);
      expect(values.single, 'EdgeInsets.zero');
    });

    test('非实参位置的同名标识符不算数（三元表达式）', () {
      const String src = 'final x = flag ? insetPadding : other;';
      expect(namedArgumentValues(src, 'insetPadding'), isEmpty);
    });
  });

  group('maskCommentsAndScriptLines：吃掉三引号串里的整行 JS 注释', () {
    const String src = '''
final String js = \'\'\'
  // window.hoshiReader.paginate('forward')
  const url = 'https://hoshi.local/x';
\'\'\';
''';

    test('等长且行数守恒', () {
      expect(maskCommentsAndScriptLines(src).length, src.length);
      expect(
        maskCommentsAndScriptLines(src).split('\n').length,
        src.split('\n').length,
      );
    });

    test('串内整行 JS 注释被掩掉（maskComments 会原样保留）', () {
      expect(maskComments(src).contains('paginate'), isTrue);
      expect(maskCommentsAndScriptLines(src).contains('paginate'), isFalse);
    });

    test('串里的 URL 不被砍（旧手写「按首个 // 截断」会砍）', () {
      expect(
        maskCommentsAndScriptLines(src).contains('https://hoshi.local/x'),
        isTrue,
      );
    });
  });
}

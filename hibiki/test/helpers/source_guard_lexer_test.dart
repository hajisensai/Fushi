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

  group('compactCode', () {
    const String needle = 'FushiToast.show(msg: t.failed,';

    test('跨 dart format 换行仍命中真实调用', () {
      const String src = '''
FushiToast.show(
  msg: t.failed,
  severity: ToastSeverity.error,
);
''';
      expect(compactCode(src), contains(compactCode(needle)));
    });

    test('整行、行尾与块注释里的调用均不命中', () {
      for (final String src in <String>[
        '// FushiToast.show(msg: t.failed, severity: ToastSeverity.error);',
        'final ok = true; // FushiToast.show(msg: t.failed,',
        '/*\nHibikiToast.show(msg: t.failed, severity: x);\n*/',
      ]) {
        expect(compactCode(src), isNot(contains(compactCode(needle))),
            reason: src);
      }
    });

    test('needle 的右边界标点防止 i18n key 前缀假绿', () {
      const String renamed =
          'FushiToast.show(msg: t.failed_v2, severity: ToastSeverity.error);';
      expect(compactCode(renamed), isNot(contains(compactCode(needle))));
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

    test('CSS 块注释**不嵌套**：首个 */ 就收口，不吞掉文件剩余部分', () {
      // 「注释掉一段本身含注释的规则」是真实会发生的编辑动作。按 Dart 的嵌套规则扫，
      // 深度永远回不到 0 ⇒ 后半个文件整段被当注释 ⇒ 之后所有断言对着空串跑，静默全绿。
      const String css = '/* off: .x { /* why */ } */ .keep { color: red; }';
      final String masked = maskCssComments(css);
      expect(masked.length, css.length);
      expect(masked.contains('.keep { color: red; }'), isTrue,
          reason: '首个 */ 之后的规则必须留下来');
    });

    test('maskHtmlComments 等长，且位置下标与原文一致', () {
      const String html =
          '<head><!-- needleToken --><meta charset="utf-8"><script src="a.js">';
      final String masked = maskHtmlComments(html);
      expect(masked.length, html.length);
      expect(masked.contains('needleToken'), isFalse);
      expect(masked.indexOf('<meta'), html.indexOf('<meta'),
          reason: '删除式剥离会让下标漂移，位置型断言（meta 是否在 script 之前）'
              '就无法回原文取证');
      expect(masked.indexOf('<meta'), lessThan(masked.indexOf('<script')));
    });

    test('HTML 注释里的 <script> 不算真标签', () {
      const String html =
          '<!-- <script src="fake.js"> --><meta charset="utf-8">';
      expect(maskHtmlComments(html).contains('<script'), isFalse);
    });

    test('maskHashComments 等长，行首与行尾 # 注释都掩得掉', () {
      const String mk = '# needleToken\n'
          'VER=ffmpeg6.1.6\n'
          '\tsed -i \'\' \'s/x/y/\' f.sh # needleToken trailing\n';
      final String masked = maskHashComments(mk);
      expect(masked.length, mk.length);
      expect(masked.contains('needleToken'), isFalse,
          reason: '整行注释与**行尾**注释都必须掩掉——旧的「整行以 # 开头」过滤器'
              '正是漏掉行尾注释的那一档');
      expect(masked.contains('VER=ffmpeg6.1.6'), isTrue);
      expect(masked.indexOf('VER='), mk.indexOf('VER='),
          reason: '等长掩码，下标可回原串切片');
    });

    test('引号内的 # 不是注释（误剪命令比漏剪注释危险）', () {
      const String mk = "\tsed 's/#tag/keepToken/' f.sh\n";
      final String masked = maskHashComments(mk);
      expect(masked.contains('keepToken'), isTrue,
          reason: '把引号内的 # 当注释会把半条命令抹成空白，要求型断言凭空变红');
      expect(masked.length, mk.length);
    });

    test('漏配的引号不传染到下一行', () {
      // 引号状态若跨行传染，一个笔误就能把文件剩余部分当成串 —— 之后所有断言
      // 对着「没有注释」的原文跑，isFalse 型断言被注释里的文字判红、
      // isTrue 型断言被注释里的字面量骗绿。
      const String mk = "A='unclosed\nB=keepToken # needleToken\n";
      final String masked = maskHashComments(mk);
      expect(masked.contains('keepToken'), isTrue);
      expect(masked.contains('needleToken'), isFalse);
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

  // -------------------------------------------------------------------------
  // ④' 箭头函数体（TODO-2726）
  // -------------------------------------------------------------------------
  //
  // 这一组语料全部**手写合成**，不读磁盘：判据必须能在「被守文件恰好长成另一个样」
  // 时仍然点名验证到每一条分支。真实文件既证不了负例（健康仓库里箭头越界不会发生
  // 两次），也会让「注释把变异兜住」的老陷阱重演。
  group("④' methodBody 认箭头函数体（TODO-2726：只认花括号会静默返回邻居）", () {
    /// 越界的**充分必要**语料：箭头函数紧跟一个花括号体的邻居。
    /// 旧实现在这里会把 `neighbourBody` 整段读进窗口。
    const String arrowThenBrace = '''
String alpha(int x) => 'A\$x';

String beta(int x) {
  return 'neighbourBody';
}
''';

    test('箭头体只取到自己的分号，不吞掉紧随其后的花括号邻居', () {
      final String body = methodBody(arrowThenBrace, 'String alpha(int x)');
      expect(body.contains("'A"), isTrue, reason: '箭头体自身必须在窗口里');
      expect(body.trimRight().endsWith(';'), isTrue,
          reason: '箭头体的右边界是深度 0 的分号');
      expect(body.contains('neighbourBody'), isFalse,
          reason: '这正是 TODO-2726：旧实现把邻居 beta 的实现当成 alpha 的体返回');
    });

    test('=> switch (…) { … }; 里的花括号不提前也不延后收口', () {
      const String src = '''
String label(int x) => switch (x) {
      1 => 'one',
      _ => 'other',
    };

String next() {
  return 'neighbourBody';
}
''';
      final String body = methodBody(src, 'String label(int x)');
      expect(body.contains("'other'"), isTrue, reason: 'switch 表达式整段都在体内');
      expect(body.contains('neighbourBody'), isFalse);
    });

    test('箭头体里实参内的分号不提前收口', () {
      const String src = '''
String f() => g('a;b', <int>[1, 2]);

String next() {
  return 'neighbourBody';
}
''';
      final String body = methodBody(src, 'String f()');
      expect(body.contains('<int>[1, 2]'), isTrue);
      expect(body.contains('neighbourBody'), isFalse);
    });

    test('箭头体里闭包**语句块**的分号不提前收口（真·深度 >0 的分号）', () {
      // 上一条的 `'a;b'` 在结构串里已被掩成空白，其实**碰不到**深度判断这条分支。
      // 闭包体里的分号是真的、在花括号深度 1 上——只有这里才验得到「深度 0 才收口」。
      const String src = '''
String f() => run(() {
      final int a = 1;
      return a.toString();
    });

String next() {
  return 'neighbourBody';
}
''';
      final String body = methodBody(src, 'String f()');
      expect(body.contains('a.toString()'), isTrue, reason: '首个分号收口会把闭包体拦腰截断');
      expect(body.trimRight().endsWith(');'), isTrue);
      expect(body.contains('neighbourBody'), isFalse);
    });

    test('命名参数默认值里的 => 不被当成函数体起点', () {
      const String src = '''
Widget wrap({Widget Function() build = _fallback, required Widget child}) {
  return Padding(padding: EdgeInsets.zero, child: child);
}
''';
      final String body = methodBody(
        src,
        'Widget wrap({Widget Function() build = _fallback',
      );
      expect(body.contains('Padding('), isTrue,
          reason: '参数表里的 => 在圆括号深度 >0，不该收口');
    });

    test('没有体的声明（抽象方法）fail loudly，绝不静默锚到下一个声明', () {
      const String src = '''
abstract class A {
  void target();
}

class B {
  void other() {
    final String s = 'neighbourBody';
  }
}
''';
      expect(
        () => methodBody(src, 'void target()'),
        throwsA(isA<TestFailure>()),
        reason: '旧实现会一路找到 B.other 的花括号，把邻居的体当成 target 的体',
      );
    });

    test('花括号体不受影响（回归）', () {
      const String src = '''
String beta(int x) {
  return 'own';
}

String next() {
  return 'neighbourBody';
}
''';
      final String body = methodBody(src, 'String beta(int x)');
      expect(body.contains("'own'"), isTrue);
      expect(body.contains('neighbourBody'), isFalse);
    });
  });

  group("④'' topLevelFunctionBody：按名字取体，跳过调用点", () {
    const String src = '''
String headline({required String reason}) => label(reason);

String label(String code) {
  switch (code) {
    case 'x':
      return 'X';
  }
  return code;
}

void caller() {
  headline(reason: 'never-part-of-a-body');
}
''';

    test('箭头体返回 => 与 ; 之间的表达式，不含邻居', () {
      final String? body = topLevelFunctionBody(src, 'headline');
      expect(body, isNotNull);
      expect(containsIdentifierCall(body!, 'label'), isTrue,
          reason: '一跳可达判据靠的就是这个窗口');
      expect(body.contains("case 'x'"), isFalse,
          reason: '不得读到邻居 label 的 switch 块（PR#762 实测到的那次假绿）');
    });

    test('花括号体返回含 {} 的整块', () {
      final String? body = topLevelFunctionBody(src, 'label');
      expect(body, isNotNull);
      expect(body!.trimLeft().startsWith('{'), isTrue);
      expect(body.contains("case 'x'"), isTrue);
      expect(body.contains('never-part-of-a-body'), isFalse);
    });

    test('只有调用点没有声明时返回 null，不返回调用方的体', () {
      const String callsOnly = '''
void caller() {
  headline(reason: 'r');
}
''';
      expect(topLevelFunctionBody(callsOnly, 'headline'), isNull);
    });

    test('async / async* / sync* 修饰符不得把声明误判成调用点', () {
      // 「右括号后第一个非空白字符是不是 `=>` / `{`」是本函数分辨声明与调用点的
      // 唯一判据，而异步函数在两者之间隔着一个 `async`。不跳它 ⇒ 每个
      // `Future<T> f() async { … }` 都被判成调用点、整个函数解析成 null，
      // 而 null 在「一跳可达」判据里的含义是**不可达** ⇒ 实现完全正确时守卫转红。
      const String asyncSrc = '''
class _State {
  Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  Stream<int> ticks() async* {
    yield 1;
  }

  Iterable<int> ones() sync* {
    yield 1;
  }

  Future<String> read() async => fetch();

  Future<void> caller() async {
    await copy('x');
  }
}
''';
      final String? brace = topLevelFunctionBody(asyncSrc, 'copy');
      expect(brace, isNotNull, reason: 'async 花括号体必须取得到');
      expect(containsIdentifierCall(brace!, 'Clipboard.setData'), isTrue);
      expect(brace.contains('yield'), isFalse, reason: '不得越界读到邻居');

      expect(
          topLevelFunctionBody(asyncSrc, 'ticks')?.contains('yield 1'), isTrue);
      expect(
          topLevelFunctionBody(asyncSrc, 'ones')?.contains('yield 1'), isTrue);

      final String? arrow = topLevelFunctionBody(asyncSrc, 'read');
      expect(arrow, isNotNull, reason: 'async 箭头体必须取得到');
      expect(containsIdentifierCall(arrow!, 'fetch'), isTrue);
      expect(arrow.contains('{'), isFalse,
          reason: 'async 箭头体收口在深度 0 的分号，不得吞掉下一个花括号体');
    });

    test('只跳 async / sync，不跳任意标识符（调用点不得被误判成声明）', () {
      // 「跳过右括号后任意标识符」是个诱人但错误的泛化：下面两处都是**调用点**，
      // 一旦被当成声明，窗口会静默锚到别人的花括号上。
      const String traps = '''
void caller() {
  if (target(1)) {
    print('not a body');
  }
}
''';
      expect(topLevelFunctionBody(traps, 'target'), isNull,
          reason: '`if (target(1)) {` 里的 target 是调用点，不是声明');
      const String asyncPrefixed = '''
void caller() {
  asyncHelper(1);
}
''';
      expect(topLevelFunctionBody(asyncPrefixed, 'asyncHelper'), isNull,
          reason: '`asyncHelper` 只是以 async 开头的标识符，不是修饰符');
    });

    test('调用点排在声明之前时仍锚到声明', () {
      const String callFirst = '''
void caller() {
  headline(reason: 'r');
}

String headline({required String reason}) => label(reason);
''';
      final String? body = topLevelFunctionBody(callFirst, 'headline');
      expect(body, isNotNull);
      expect(containsIdentifierCall(body!, 'label'), isTrue);
    });
  });

  // 禁止型断言（isFalse）在健康仓库里**永远零命中**：判据自己坏掉时，扫盘那一路
  // 检验不到。所以判据必须在**手写语料**上单独验证，且与磁盘扫描互不依赖。
  group('containsIdentifier：禁止型判据的自校验（手写语料，不读磁盘）', () {
    test('代码里以独立标识符出现 ⇒ 命中', () {
      expect(
        containsIdentifier(
            '  static const int _galAudioBackMs = 8000;', '_galAudioBackMs'),
        isTrue,
      );
      expect(
        containsIdentifier('final int x = _galAudioBackMs;', '_galAudioBackMs'),
        isTrue,
      );
    });

    test('只出现在注释里 ⇒ 不命中（否则守卫会被一句解释永久判红）', () {
      expect(
        containsIdentifier(
            '// 历史：这里曾有 _galAudioBackMs 同时当两个量用。\nfinal int a = 1;',
            '_galAudioBackMs'),
        isFalse,
      );
      expect(
        containsIdentifier('/* _galAudioBackMs */', '_galAudioBackMs'),
        isFalse,
      );
    });

    test('更长的标识符含同名子串 ⇒ 不命中（否则正确写法反被判红）', () {
      expect(
        containsIdentifier(
            'const int _galAudioBackMsLegacy = 1;', '_galAudioBackMs'),
        isFalse,
      );
      expect(
        containsIdentifier(
            'const int x_galAudioBackMs = 1;', '_galAudioBackMs'),
        isFalse,
      );
    });

    test('不要求是次调用（与 containsIdentifierCall 的分工）', () {
      expect(containsIdentifier('a = selectable && !excluded;', 'selectable'),
          isTrue);
      expect(
        containsIdentifierCall('a = selectable && !excluded;', 'selectable'),
        isFalse,
      );
    });
  });

  group('initializerExpression：取「这个量是怎么来的」而不是逐字拼写', () {
    test('取到分号前的整段表达式，与修饰符/空格/类型名无关', () {
      const String src = '''
class A {
  static const int cap = 60 * 1000;
  static const Duration window = Duration(seconds: 20);
}
''';
      expect(initializerExpression(src, 'cap'), '60 * 1000');
      expect(initializerExpression(src, 'window'), 'Duration(seconds: 20)');
    });

    test('实参/集合字面量里的分号不提前收口', () {
      const String src = "final String s = fn('a;b', <int>[1]);";
      expect(initializerExpression(src, 's'), "fn('a;b', <int>[1])");
    });

    test('闭包**语句块**里的分号不提前收口（真·深度 >0 的分号）', () {
      // 上一条的 `'a;b'` 在结构串里已被掩成空白，碰不到深度判断。闭包体里的分号是
      // 真的、在花括号深度 1 上——只有这里才验得到「深度 0 才收口」。
      const String src = '''
final VoidCallback cb = () {
  count += 1;
};
final int tail = 7;
''';
      expect(initializerExpression(src, 'cb'), '() {\n  count += 1;\n}');
    });

    test('`name == x` 是比较，不是声明', () {
      const String src = '''
bool f(int name) {
  if (name == 3) return true;
  return false;
}
''';
      expect(initializerExpression(src, 'name'), isNull);
    });

    test('switch 表达式的 `pattern => …` 分支不被当成声明', () {
      // `v =>` 与 `v =` 只差一个字符，且它出现在真声明**之前**：
      // 少了这一条，取到的会是那个分支的表达式而不是变量的初始化式。
      const String src = '''
void f(int x) {
  final String s = switch (x) {
    1 => 'one',
    v => 'other',
  };
  final int v = 9;
}
''';
      expect(initializerExpression(src, 'v'), '9');
    });

    test('注释里的同名声明不算数', () {
      const String src = '''
// 旧值 static const int cap = 8000;
static const int cap = 60000;
''';
      expect(initializerExpression(src, 'cap'), '60000');
    });

    test('找不到返回 null，不返回空串', () {
      expect(initializerExpression('const int a = 1;', 'b'), isNull);
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
  // window.fushiReader.paginate('forward')
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

    test('串里的**行尾** JS 注释与块注释也被掩掉（旧版只认整行 //）', () {
      const String tail = '''
final String js = \'\'\'
  paginate('forward'); // needleTail
  /* needleBlock */
  const ok = 1;
\'\'\';
''';
      final String masked = maskCommentsAndScriptLines(tail);
      expect(masked.length, tail.length);
      expect(masked.contains('needleTail'), isFalse);
      expect(masked.contains('needleBlock'), isFalse);
      expect(masked.contains('const ok = 1'), isTrue);
      expect(masked.contains("paginate('forward')"), isTrue);
    });

    test('串里 JS 正则字面量的 // 不再把整行砍掉', () {
      const String withRegex = '''
final String js = \'\'\'
  const bare = url.replace(/^https?:\\/\\//i, ''); needleAfterRegex;
\'\'\';
''';
      final String masked = maskCommentsAndScriptLines(withRegex);
      expect(masked.contains('needleAfterRegex'), isTrue,
          reason: '正则里的 // 被当行注释 ⇒ 从这里到行尾整段消失 ⇒ 要求型断言假红、'
              '禁止型断言假绿');
    });
  });

  group('maskJsComments：JS 专用词法（模板串 / 正则 / 行尾注释）', () {
    test('等长且行数守恒', () {
      const String js = 'const a = `x \${v}`; // t\n/* b */ const c = 2;\n';
      expect(maskJsComments(js).length, js.length);
      expect(maskJsComments(js).split('\n').length, js.split('\n').length);
      expect(maskJsCommentsAndStrings(js).length, js.length);
    });

    test('行注释与块注释被掩掉', () {
      expect(maskJsComments('a(); // needleToken\n').contains('needleToken'),
          isFalse);
      expect(maskJsComments('a(); /* needleToken */\n').contains('needleToken'),
          isFalse);
      expect(maskJsComments('a(); // x\n').contains('a();'), isTrue);
    });

    test('正则字面量里的 // 不被当注释（maskComments 会砍，这是它的洞）', () {
      const String js = r"const s = u.replace(/^https?:\/\//i, ''); keepMe;";
      expect(maskJsComments(js).contains('keepMe'), isTrue);
      expect(maskComments(js).contains('keepMe'), isFalse,
          reason: 'Dart 掩码在 JS 正则上必然出错——这正是需要独立 JS 原语的原因');
    });

    test('字符类里的 / 不收口正则', () {
      const String js = r'const re = /[a-z/]+/g; keepMe;';
      expect(maskJsComments(js).contains('keepMe'), isTrue);
    });

    test('除号不被误当正则起点（否则会把后面整段吞成正则）', () {
      const String js = 'const half = (a + b) / 2; const q = c / d; keepMe;';
      expect(maskJsComments(js), js);
    });

    test('模板串内容保留，插值里的注释仍被掩掉', () {
      const String js = r'const t = `a ${f(/* needleToken */ 1)} b`; keepMe;';
      final String masked = maskJsComments(js);
      expect(masked.contains('needleToken'), isFalse);
      expect(masked.contains('`a '), isTrue);
      expect(masked.contains('keepMe'), isTrue);
    });

    test('模板串里的 // 不被当注释', () {
      const String js = 'const t = `https://x/y`; keepMe;';
      expect(maskJsComments(js).contains('keepMe'), isTrue);
    });

    test('已知边界：`)` 之后的正则被当成除号（TODO-2477 复核结论）', () {
      // `/` 是正则还是除号，只能靠前一个有意义 token 判。`)` 有意**不在**
      // _kJsRegexAllowedAfter 里，因为 `(a+b)/2` 是除法，而「if 条件收口后紧跟
      // 正则」在真实代码里罕见。代价是下面这种写法会被读成「除号 + 行注释」，
      // 从 `//` 起到行尾整段被掩掉。
      //
      // 全仓 66 个真实 .js 资产扫下来没有一处命中（TODO-2477 实测），所以保持
      // 现状；真要修得引入表达式上下文/ASI 跟踪，代价远大于收益。这条用例把
      // 边界钉住：谁哪天真去修了，它会红，提醒同步更新这段说明。
      const String js = 'if (a) /x://y/.test(b); keepMe;';
      expect(maskJsComments(js).contains('keepMe'), isFalse,
          reason: '这是已知且有意的取舍，不是回归；改动前先读上面的说明');
      // 反过来：`(`、`=`、`[`、`return` 之后的正则都判得对，含 `\/` 转义斜杠。
      for (final String ok in <String>[
        r't(/x:\/\/y/); keepMe;',
        r'var re = /a:\/\/b/; keepMe;',
        r'return /a:\/\/b/.test(s); keepMe;',
      ]) {
        expect(maskJsComments(ok).contains('keepMe'), isTrue, reason: ok);
      }
    });

    test('maskJsCommentsAndStrings 掩掉串内容但保留结构括号', () {
      const String js = "function f() { const s = '}{'; return 1; }";
      final String structural = maskJsCommentsAndStrings(js);
      expect(structural.length, js.length);
      expect(structural.contains('}{'), isFalse,
          reason: '串里的花括号必须退出配对，否则 methodBody 当场跑偏');
      expect(structural.contains('function f()'), isTrue);
    });

    test('methodBody(lexicon: js) 用 JS 词法取函数体', () {
      const String js = '''
function target() {
  const re = /\\}\\{/g;      // 正则里的花括号不该收口
  const s = `a \${x} }`;    // 模板串里的也不该
  return 'realBody';
}
function next() {
  return 'sentinel';
}
''';
      final String body =
          methodBody(js, 'function target()', lexicon: SourceLexicon.js);
      expect(body.contains("'realBody'"), isTrue);
      expect(body.contains('sentinel'), isFalse, reason: '不能越界吞掉下一个函数');
    });
  });
}

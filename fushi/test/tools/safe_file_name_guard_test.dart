// 守卫：Windows 文件名黑名单字符集只允许一处真相源（命名统一 G1，BUG-1125）。
//
// 背景：全仓曾有 10+ 份手写 `[\\/:*?"<>|]` 及排列变体，其中 home_video_page 的
// 一份漏写反斜杠（BUG-1125：云视频 id 含 `\` 时字幕与封面落到不同目录）。收敛到
// `lib/src/utils/misc/safe_file_name.dart` 后，本测试扫描 lib/ 源码，禁止再手写
// 该字符类的 RegExp。
//
// TODO-2715 修掉判据自身的两个假相源（旧写法是「同一行里既有 `RegExp(` 又有指纹」）：
//
// ⑤ **假红**：旧注释自陈「注释/文档里引用历史字符串不算违规」，但代码里**从来没有
//    剥过注释**——把一段历史写法注释掉当反例，守卫会当场判红。现在先 [maskComments]
//    再匹配，注释与判据终于一致。
// ④ **假绿**：`dart format` 会把长构造折成
//    `RegExp(\n  r'[\\/:*?"<>|]',\n)`，`RegExp(` 与指纹落在两行，逐行判据直接失配。
//    现在改成「先定位 `RegExp(` 调用，再用括号配对切出整个调用原文」，与换行无关。
//
// 判据是**禁止型**（violations isEmpty），所以真实仓库里长期零命中——也就是说
// 「判据本身还认不认得违规」在扫盘那条路上永远得不到检验。下面的自校验用**手写语料**
// 独立喂进同一个 [findWindowsFileNameBlacklistRegExps]，正负两向都钉住。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 手写黑名单字符类的指纹子串（覆盖历史上出现过的全部排列变体）。
const List<String> kBlacklistFingerprints = <String>[
  r':*?"<>|', // [\\/:*?"<>|] / [\/:*?"<>|] / [:*?"<>|] / [...\x00-\x1f]
  r'<>:"/', // [<>:"/\\|?*] / [\x00-\x1F<>:"/\\|?*]
  r':"|?*', // [<>:"|?*\x00-\x1F]
];

/// 唯一允许持有该字符类的真相源。
const String _allowedFile = 'lib/src/utils/misc/safe_file_name.dart';

/// 以独立标识符身份出现的 `RegExp(` 构造（`MyRegExp(` 不算）。
final RegExp _regExpConstruction = RegExp(r'(?<![A-Za-z0-9_$])RegExp\s*\(');

/// [source] 里所有「构造了 Windows 文件名黑名单字符类」的 `RegExp(...)` 调用，
/// 返回 `行号: 首行原文` 形式的定位串（行号从 1 起）。
///
/// 词法纪律：
/// - 注释（`//`、`/* */`，含跨行）先掩成等长空白 ⇒ 注释里引用历史字符串不算违规；
/// - 调用范围由 [enclosingCall] 的括号配对给出 ⇒ `dart format` 怎么折行都不影响；
/// - 调用原文再掩一次注释 ⇒ 调用实参之间夹的注释同样不算数。
List<String> findWindowsFileNameBlacklistRegExps(String source) {
  final String code = maskComments(source);
  // 便宜的前置过滤：整份代码里连指纹都没有就不必做括号配对。
  if (!kBlacklistFingerprints.any(code.contains)) return const <String>[];

  final List<String> hits = <String>[];
  for (final RegExpMatch match in _regExpConstruction.allMatches(code)) {
    // match.end 落在 `(` 之后一位，必然在这次调用的实参区间里。
    final EnclosingCall call = enclosingCall(source, match.end);
    final String callCode = maskComments(call.text);
    if (!kBlacklistFingerprints.any(callCode.contains)) continue;
    final int line =
        '\n'.allMatches(source.substring(0, call.start)).length + 1;
    hits.add('$line: ${call.text.split('\n').first.trim()}');
  }
  return hits;
}

void main() {
  test('lib/ 下除唯一真相源外不得手写 Windows 文件名黑名单 RegExp', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: '需在 fushi/ 包根下运行（flutter test 默认即是）');

    final List<String> violations = <String>[];
    final Iterable<File> files = libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));
    expectScanScale(files.length,
        what: 'lib/ 下的 .dart', atLeast: 750, measured: 939);
    for (final File f in files) {
      final String rel = f.path.replaceAll(r'\', '/');
      if (rel == _allowedFile || rel.endsWith('/$_allowedFile')) continue;
      for (final String hit in findWindowsFileNameBlacklistRegExps(
        f.readAsStringSync(),
      )) {
        violations.add('$rel:$hit');
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Windows 文件名黑名单字符集已收敛到 $_allowedFile 的 '
          'safeWindowsFileName / windowsUnsafeFileNameChars——直接复用，'
          '勿再复制字符集（BUG-1125 正是复制时漏了反斜杠）：\n${violations.join('\n')}',
    );
  });

  // 真相源自己必须还持有那个字符集，否则上面那条「除它以外都不许有」守的是空气。
  test('唯一真相源仍持有该字符类', () {
    final File truth = File(_allowedFile);
    expect(truth.existsSync(), isTrue, reason: '真相源文件不见了：$_allowedFile');
    expect(findWindowsFileNameBlacklistRegExps(truth.readAsStringSync()),
        isNotEmpty,
        reason: '$_allowedFile 里已经找不到黑名单字符类了——要么它被改坏，'
            '要么指纹表过期；两种都会让主守卫退化成永远绿');
  });

  group('判据自校验（手写语料，与磁盘扫描互不依赖）', () {
    test('单行写法命中', () {
      expect(
        findWindowsFileNameBlacklistRegExps(
          "final RegExp bad = RegExp(r'[\\\\/:*?\"<>|]');",
        ),
        isNotEmpty,
      );
    });

    test('④ dart format 折行后仍命中', () {
      expect(
        findWindowsFileNameBlacklistRegExps('''
final RegExp bad = RegExp(
  r'[\\\\/:*?"<>|]',
);
'''),
        isNotEmpty,
        reason: '折行是 dart format 的常规产物，判据不得依赖「同一行」',
      );
    });

    test('④ 另外两个历史排列变体折行后同样命中', () {
      for (final String cls in <String>[r'[<>:"/\|?*]', r'[<>:"|?*]']) {
        expect(
          findWindowsFileNameBlacklistRegExps(
              'final r = RegExp(\n  r\'$cls\',\n);'),
          isNotEmpty,
          reason: '排列变体 $cls 折行后漏判',
        );
      }
    });

    test('⑤ 行注释里的历史写法不算违规', () {
      expect(
        findWindowsFileNameBlacklistRegExps(
          "// 旧写法：RegExp(r'[\\\\/:*?\"<>|]')，已收敛到 safe_file_name.dart",
        ),
        isEmpty,
      );
    });

    test('⑤ 块注释 / 文档注释里的历史写法不算违规', () {
      expect(
        findWindowsFileNameBlacklistRegExps('''
/* 历史写法留档：
   RegExp(r'[\\\\/:*?"<>|]')
*/
/// 参见 RegExp(r'[<>:"/\\\\|?*]') 的收敛过程。
void f() {}
'''),
        isEmpty,
      );
    });

    test('不构造 RegExp 的普通串不算违规', () {
      expect(
        findWindowsFileNameBlacklistRegExps(
          "final String note = 'chars are :*?\"<>| on Windows';",
        ),
        isEmpty,
        reason: '本守卫钉的是「别再手写这个 RegExp」，不是禁止提到这些字符',
      );
    });

    test('无关的 RegExp 不误伤', () {
      expect(
        findWindowsFileNameBlacklistRegExps(
          "final RegExp ok = RegExp(r'^[a-z0-9_]+\$');",
        ),
        isEmpty,
      );
    });
  });
}

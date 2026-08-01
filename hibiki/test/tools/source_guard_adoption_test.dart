import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/banned_comment_strip.dart';
import '../helpers/source_guard.dart';

/// TODO-2358 / TODO-2477 的**覆盖率**守卫：源码扫描守卫不得再手写注释剥离。
///
/// 为什么需要这一条：全仓 22 个守卫各写过一份自己的「剥注释」逻辑，形态都是
/// ```dart
/// src.split('\n').where((String l) => !l.trimLeft().startsWith('//')).join('\n')
/// ```
/// 这个写法三个方向都漏，而且**每一处都要各踩一遍才会被发现**：
/// - `/* needle */` 块注释一概放行 ⇒ 要求型断言（isTrue）可以被「把实现删光、
///   只在块注释里留下那串字面量」骗绿。这是真实验证过的假绿，不是理论风险；
/// - 行尾注释（`foo(); // needle`）同样放行；
/// - 「丢掉整行」会改变字符串长度与行数 ⇒ 后续 `indexOf` / `substring` 的下标
///   与原文错位，报错信息里的行号也是错的。
///
/// 把 22 处都迁到共享 helper 只解决了**存量**。没有这条守卫，第 23 个守卫照样会
/// 手写一遍，全仓性假绿源原地复活。所以覆盖必须锁在「新增」这一侧。
///
/// 判据方向：**正向枚举违规**（扫全部 test 源码找禁用形态），再用一张写明理由的
/// 豁免表放行少数合法用法。绝不反过来「用已迁移的文件集合取反算出应当被守的集合」
/// ——那样新增文件天生落在集合外，守卫对它零覆盖。
///
/// flutter test 的 cwd 是 hibiki 包根。
void main() {
  /// 允许出现禁用形态的文件 → **具体**理由。
  ///
  /// 理由必须说清「为什么这里手写是对的」。只写文件名的白名单两个月后就退化成
  /// 「往里塞一行」的橡皮图章。
  const Map<String, String> allowed = <String, String>{
    'test/helpers/source_guard.dart':
        '共享 helper 的**实现本体**。maskCommentsAndScriptLines 里那一遍「整行以 '
            '// 开头」是有意保留的保守超集（并集，只会掩得更多、绝不更少），'
            '用来兜住三引号串里 JS 词法器没覆盖到的边角。',
    'test/helpers/banned_comment_strip.dart':
        '禁用形态的**模式表本体**：那些字面量按定义必须出现在这里。单独成文件正是'
            '为了让守卫本体不含任何禁用形态，从而能被自己覆盖；本文件里没有任何'
            '扫描逻辑可以退化。',
    'test/reader/reader_script_compactor_test.dart':
        '这里的 `trimmed.startsWith(\'//\')` 不是「剥注释」，而是**被测对象自己的'
            '契约断言**：ReaderScriptCompactor 只许删空行与注释行，测试逐条核对'
            '被删掉的行确实是注释。换成掩码反而表达不了这个判据。',
  };

  // 模式表放在 helpers/banned_comment_strip.dart：那些字面量若写在本文件里，
  // 会被本守卫自己扫成违规（断言字面量同时也是扫描输入）。挪出去之后本文件不含
  // 任何禁用形态，于是**本守卫自己也在覆盖范围内**。
  const Map<String, String> banned = kBannedCommentStripPatterns;

  test('test/ 下不得再手写注释剥离，一律走 helpers/source_guard.dart', () {
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity e in Directory('test').listSync(
      recursive: true,
    )) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = e.path.replaceAll('\\', '/');
      if (allowed.containsKey(rel)) continue;
      scanned++;
      // 自举：用共享掩码剥掉本文件的注释再扫。守卫自己也不许被注释骗——
      // 迁移说明注释里必然写着旧形态长什么样（本文件上面就写了好几处）。
      final List<String> lines = maskComments(e.readAsStringSync()).split('\n');
      for (int i = 0; i < lines.length; i++) {
        for (final MapEntry<String, String> b in banned.entries) {
          if (!lines[i].contains(b.key)) continue;
          offenders.add('$rel:${i + 1}  用了 ${b.key} —— 改用 ${b.value}');
        }
      }
    }

    // 扫描本身失效（路径变了 / listSync 拿不到东西）必须红，不能静默变成
    // 「零违规」的摆设。
    expect(scanned, greaterThan(200),
        reason: '只扫到 $scanned 个 test/*.dart —— 扫描逻辑失效了，'
            '这条守卫会变成永远绿的摆设，请修扫描而不是删断言');

    expect(offenders, isEmpty,
        reason: '这些地方手写了注释剥离：\n${offenders.join('\n')}\n\n'
            '手写形态只跳 `//` 开头的整行：块注释 `/* needle */` 一概放行'
            '（要求型断言可被「实现删光、注释留字面量」骗绿）、行尾注释也放行、'
            '删行还会让后续 indexOf/substring 的下标与原文错位。\n'
            '共享原语在 test/helpers/source_guard.dart：maskComments / '
            'maskCommentsAndStrings / maskJsComments / maskCssComments / '
            'maskHtmlComments / maskCommentsAndScriptLines / containsCodeLine。\n'
            '确有正当理由的，加进本文件的 allowed 表并写清为什么。');
  });

  test('豁免表不许过期，也不许是只有文件名的橡皮图章', () {
    for (final MapEntry<String, String> e in allowed.entries) {
      expect(File(e.key).existsSync(), isTrue,
          reason: '豁免表里的 ${e.key} 已不存在，请清理');
      expect(e.value.trim().length, greaterThanOrEqualTo(20),
          reason: '${e.key} 的豁免理由太短，等于没写');
      for (final String placeholder in <String>['TODO', 'FIXME', '待补', 'n/a']) {
        expect(e.value.contains(placeholder), isFalse,
            reason: '${e.key} 的豁免理由是占位符（含 "$placeholder"）');
      }
    }
  });

  test('豁免的文件里确实存在被豁免的形态（名单不许养僵尸）', () {
    for (final String rel in allowed.keys) {
      final String masked = maskComments(File(rel).readAsStringSync());
      final bool hit = banned.keys.any(masked.contains);
      expect(hit, isTrue,
          reason: '$rel 已经不含任何禁用形态了，说明它早该从豁免表里删掉——'
              '留着就是给后来人开的后门');
    }
  });
}

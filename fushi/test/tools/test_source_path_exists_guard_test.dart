import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 测试里**按磁盘路径读源码**的那批守卫，路径必须指得到真实文件。
///
/// 由来：#1316 把一批文件从 `fushi/lib/src/` 搬进 `packages/fushi_engine/lib/`。
/// 写成 `import 'package:fushi/src/...'` 的引用一改就编译不过、当场暴露；但
/// 写成 `File('lib/src/...').readAsStringSync()` 的**源码扫描型守卫**不一样——
/// 它在编译期毫无异样，只有真跑到那条用例时才抛 PathNotFoundException。这类
/// 守卫散在各功能目录里（stats / onnx / settings / pages …），按功能域挑定向
/// 测试结构上挑不到，于是一路漏到 CI 的真单测门才炸（`study_session_edit_test`
/// 就是这么红的）。
///
/// 这条守卫把「路径指得到」变成一次性可查的事实：一次搬家之后跑它，比逐个
/// 功能域去猜哪条守卫会踩雷快得多。
///
/// **故意指不到的除外**：有一批守卫断言的正是「这个文件已经被删掉了」
/// （旧设置页、已下线的字幕录制器等），它们的路径本就不该存在。白名单按
/// 「读出来之后是不是在断言不存在」判定——见 [_intentionallyAbsent]。
void main() {
  /// 只认**裸** `File('lib/src/…')`：形如 `_asrCoreFile('lib/src/…')` 的是
  /// 另一个包的路径解析器，那串相对的是那个包，不是 fushi/。
  final RegExp pattern =
      RegExp(r"""(?<![A-Za-z0-9_])File\(\s*'lib/src/([^']+)'""");

  /// 路径里带插值的跳过：那是运行期拼出来的一批文件名，静态判不了。
  bool interpolated(String rel) => rel.contains(r'$');

  /// 以 '/' 结尾的是目录前缀（用来枚举一批文件），不是单个文件。
  bool directoryPrefix(String rel) => rel.endsWith('/');

  /// 只声明了 File 对象、从没对它 readAsString 的，指不到也不会抛
  /// （那多半是拿来判存在性的）。
  bool neverRead(String source) =>
      !source.contains('readAsStringSync()') &&
      !source.contains('readAsString(') &&
      !source.contains('readAsLinesSync()');

  /// 断言「已被删除」的守卫：文件不存在正是它要的结论。
  bool intentionallyAbsent(String source, String rel) {
    final int at = source.indexOf("'lib/src/$rel'");
    if (at < 0) return false;
    // 取该处前后各 600 字符当上下文——这类守卫的 existsSync 判据与 reason
    // 都写在紧邻处。
    final int from = at - 600 < 0 ? 0 : at - 600;
    final int to = at + 600 > source.length ? source.length : at + 600;
    final String around = source.substring(from, to);
    // existsSync() 与 isFalse 之间会被 dart format 拆行加缩进，逐字匹配必然漏，
    // 所以按「existsSync() 之后、下一个非空白 token 是 isFalse」判。
    final RegExp absentAssertion = RegExp(r'existsSync\(\)\s*,\s*isFalse');
    return absentAssertion.hasMatch(around) ||
        around.contains('isNot(exists') ||
        around.contains('已删除') ||
        around.contains('已移除') ||
        around.contains('已不存在') ||
        around.contains('不得存在') ||
        around.contains('must not exist') ||
        around.contains('no longer exists');
  }

  test('测试里 File(\'lib/src/…\') 读的源码路径都指得到（搬家后别漏改）', () {
    final List<String> offenders = <String>[];
    for (final String root in <String>['test', 'integration_test']) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // 跳过本文件：它的注释与 reason 里写着示例路径，会扫到自己。
        if (entity.path.endsWith('test_source_path_exists_guard_test.dart')) {
          continue;
        }
        final String source = entity.readAsStringSync();
        if (neverRead(source)) continue;
        for (final RegExpMatch m in pattern.allMatches(source)) {
          final String rel = m.group(1)!;
          if (interpolated(rel)) continue;
          if (directoryPrefix(rel)) continue;
          if (File('lib/src/$rel').existsSync()) continue;
          if (intentionallyAbsent(source, rel)) continue;
          offenders.add('${entity.path.replaceAll(r'\', '/')}  ->  lib/src/$rel');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '这些守卫按磁盘路径读源码，但路径指不到文件——多半是某次搬家只改了 import、'
          '漏了这里。编译期看不出来，跑到那条用例才 PathNotFoundException：\n'
          '${offenders.join('\n')}\n'
          '若文件确实搬走了，把路径改成新位置（如 '
          "'../packages/fushi_engine/lib/…'）；"
          '若是断言「已被删除」，让判据显式写成 existsSync(), isFalse。',
    );
  });
}

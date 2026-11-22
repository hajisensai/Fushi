// 守卫：起真 headless Chrome 的测试文件都带 chrome 标签。
//
// dist_test 按标签派活（tool/test_flow/dist_plan.dart 的 scanSuiteRequirement）：带
// chrome 标签的套件只进声明了 chrome 能力的 worker。测试里的「Chrome 在不在」只看
// 可执行文件存不存在，而装了 Chrome 不等于能跑——无图形会话的 SSH worker（wight-mac）
// 上 headless Chrome 一启动就段错误退出（exit -11）。漏了标签的套件被派到这种机器上
// 就是只在那台机器上红的伪红；带上标签，由派发层把它们放到能跑 Chrome 的机器上。
//
// 判据与派发层同一份扫描（不在这里另写标签正则）：文件里出现直接起 Chrome 的环境变量
// 名或 node harness 的 Chrome 探测，就必须扫出 chrome 能力。

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/dist_plan.dart';

// 下面的判据串都拼接产生，免得本文件自己命中扫描；本文件也不能含带引号的标签字面量
// 或标签注解（否则派发层会把这个守卫本身钉到 chrome worker）。

/// 直接起 Chrome 的套件都经这个环境变量找浏览器。
const String _chromeEnv =
    'CHROME_'
    'EXECUTABLE';

/// 经 node harness 起 Chrome 的套件先用它探测浏览器（test/helpers/node_runtime.dart）。
const String _nodeChromeProbe =
    'chromeAvailable'
    'Via(';

void main() {
  test('起真 Chrome 的测试文件都带 chrome 标签（dist 只派给有 chrome 能力的 worker）', () {
    final List<String> untagged = <String>[];
    int launching = 0;
    for (final FileSystemEntity entity in Directory(
      'test',
    ).listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('_test.dart')) continue;
      final String source = entity.readAsStringSync();
      if (!source.contains(_chromeEnv) && !source.contains(_nodeChromeProbe)) {
        continue;
      }
      launching++;
      if (!scanSuiteRequirement(source).capabilities.contains('chrome')) {
        untagged.add(entity.path.replaceAll(r'\', '/'));
      }
    }
    expect(launching, greaterThan(0), reason: '扫描没找到任何起 Chrome 的测试，判据失效');
    expect(
      untagged..sort(),
      isEmpty,
      reason:
          '这些测试起真 headless Chrome 却没带 chrome 标签：在文件头加 @Tags 注解，'
          '或在对应 test / group 上加 tags 参数（标签名 chrome）',
    );
  });
}

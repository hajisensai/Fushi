import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
// 公开入口只导出 PackageBuilder，期望诊断的类型得从实现库拿（官方示例同样只写字面量列表）。
// ignore: implementation_imports
import 'package:analyzer_testing/src/analysis_rule/pub_package_resolution.dart'
    show ExpectedDiagnostic;

import 'package:test/test.dart' show group, test;

// ignore: implementation_imports
export 'package:analyzer_testing/src/analysis_rule/pub_package_resolution.dart'
    show ExpectedDiagnostic;

/// 一条规则用例：拿到已 setUp 的测试实例，做断言。
typedef RuleCase<T extends FushiRuleTest> = Future<void> Function(T t);

/// 把一组用例注册成普通 package:test 用例，每条用例一个新实例
/// （setUp → 用例 → tearDown）。
///
/// 不用官方示例里的 test_reflective_loader：它依赖 dart:mirrors，CI 的包测试
/// runner 走 `flutter test`，那里没有 mirrors。用例直接写成这张表里的闭包，
/// 不存在「写了方法却忘了登记」。
void defineRuleTests<T extends FushiRuleTest>(
  T Function() create,
  Map<String, RuleCase<T>> cases,
) {
  group('$T', () {
    for (final MapEntry<String, RuleCase<T>> c in cases.entries) {
      test(c.key, () async {
        final T t = create();
        t.setUp();
        try {
          await c.value(t);
        } finally {
          await t.tearDown();
        }
      });
    }
  });
}

/// 规则单测的公共底座：把测试包放在仓库同构的位置上（`/home/fushi`、
/// `/home/packages/<名字>`），让规则按真实的仓库相对路径判作用域与豁免。
abstract class FushiRuleTest extends AnalysisRuleTest {
  /// 测试包相对工作区根的目录，例如 `fushi` 或 `packages/fushi_engine`。
  String get packageDir => 'fushi';

  @override
  String get testPackageRootPath => '$workspaceRootPath/$packageDir';

  /// 在测试包里按包内路径（`lib/src/a.dart`）写一个文件，返回它的绝对路径。
  ///
  /// 原样写入、不像 `newFile` 那样按平台换行改写，这样期望偏移和
  /// `assertDiagnostics` 一样直接按 [content] 计算（分析在首次解析时才建上下文，
  /// 此前写入的文件都会被发现）。
  String writePackageFile(String inPackage, String content) {
    final String path = convertPath('$testPackageRootPath/$inPackage');
    resourceProvider.getFile(path).writeAsStringSync(content);
    return path;
  }

  /// [source] 里第 [occurrence] 处 [needle] 的违规诊断。
  ExpectedDiagnostic lintAt(
    String source,
    String needle, {
    int occurrence = 0,
  }) {
    int at = -1;
    for (int i = 0; i <= occurrence; i++) {
      at = source.indexOf(needle, at + 1);
      if (at < 0) {
        throw ArgumentError('"$needle" #$occurrence not found in source');
      }
    }
    return lint(at, needle.length);
  }

  /// 文件头上的「豁免过期」诊断。
  ExpectedDiagnostic staleAllowance() =>
      lint(0, 0, name: '${rule.name}_stale_allowance');
}

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
// 公开入口只导出 PackageBuilder，期望诊断的类型得从实现库拿（官方示例同样只写字面量列表）。
// ignore: implementation_imports
import 'package:analyzer_testing/src/analysis_rule/pub_package_resolution.dart'
    show ExpectedDiagnostic;

// ignore: implementation_imports
export 'package:analyzer_testing/src/analysis_rule/pub_package_resolution.dart'
    show ExpectedDiagnostic;

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

import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';

import '../ratchet.dart';

/// 禁止 `fushi/lib` 下 import / export SDK 内的 `package:flutter/material.dart`
/// 与 `package:flutter/cupertino.dart`。
///
/// Flutter 3.47 把 Material / Cupertino 拆成 pub 包 `material_ui` /
/// `cupertino_ui`。SDK 内旧库与新包的同名符号是**不同的类型**：一个文件混进旧
/// import，它造出来的 `ThemeData` / `Material` 对新树完全不可见（Theme.of 读
/// 不到、debug 下「No Material widget found」），编译却能过。并发分支带进来的
/// 旧 import 用 `bash tool/migrate_design_widgets.sh` 收尾。
///
/// 豁免只收「必须把旧 SDK 类型交给未迁移第三方包」的文件，并且那里的旧 import
/// 必须带 `as legacy` 前缀（不和新符号混名）；不带前缀的旧 import 不吃豁免。
class NoLegacyDesignImport extends RatchetedRule {
  NoLegacyDesignImport()
    : super(name: ruleName, description: 'SDK 内旧 Material / Cupertino import');

  static const String ruleName = 'fushi_no_legacy_design_import';

  static const LintCode code = LintCode(
    ruleName,
    "Don't import the SDK's {0}: {1}",
    correctionMessage:
        'Use package:material_ui/material_ui.dart / '
        'package:cupertino_ui/cupertino_ui.dart '
        '(bash tool/migrate_design_widgets.sh rewrites it).',
    severity: DiagnosticSeverity.WARNING,
  );

  static const LintCode stale = LintCode(
    '${ruleName}_stale_allowance',
    'fushi_lints allows {1} legacy {0} import(s) in this file but found {2}.',
    correctionMessage:
        'Lower or delete the Allowance in '
        'packages/fushi_lints/lib/src/rules/no_legacy_design_import.dart.',
    severity: DiagnosticSeverity.WARNING,
  );

  static const String material = 'package:flutter/material.dart';
  static const String cupertino = 'package:flutter/cupertino.dart';

  static const List<Allowance> exemptions = <Allowance>[
    Allowance(
      'fushi/lib/src/utils/adaptive/legacy_design_compat.dart',
      material,
      1,
      '把新主题 / 本地化桥给未迁移第三方组件，需要旧 Material 祖先',
    ),
    Allowance(
      'fushi/lib/src/pages/implementations/changelog_page.dart',
      material,
      1,
      'flutter_markdown 0.6 的 MarkdownStyleSheet.fromTheme 只收旧 ThemeData',
    ),
    Allowance(
      'fushi/lib/src/utils/misc/update_checker.dart',
      material,
      1,
      'flutter_markdown 0.6 的 MarkdownStyleSheet.fromTheme 只收旧 ThemeData',
    ),
  ];

  @override
  LintCode get violationCode => code;

  @override
  LintCode get staleCode => stale;

  @override
  List<Allowance> get allowances => exemptions;

  @override
  bool appliesTo(String repoPath) => repoPath.startsWith('fushi/lib/');

  @override
  List<RuleSite> collect(CompilationUnit unit, RuleContext context) {
    final List<RuleSite> sites = <RuleSite>[];
    for (final Directive d in unit.directives) {
      if (d is! NamespaceDirective) continue;
      final String? uri = d.uri.stringValue;
      if (uri != material && uri != cupertino) continue;
      final bool legacyPrefixed =
          d is ImportDirective && d.prefix?.name == 'legacy';
      sites.add(
        RuleSite(
          d,
          uri!,
          legacyPrefixed
              ? 'this file has no legacy-import allowance.'
              : "legacy imports must use the 'as legacy' prefix even when "
                    'allowed.',
          allowable: legacyPrefixed,
        ),
      );
    }
    return sites;
  }
}

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';

/// 规则在一个编译单元里找到的一处命中。
///
/// [kind] 区分同一条规则下的不同对象（例如「SegmentedButton」与「TabBar」），
/// 豁免按 kind 分别计数；[detail] 进违规消息，说明这一处为什么不行、该怎么改；
/// [allowable] 为 false 的命中不吃豁免额度，一律报。
final class RuleSite {
  const RuleSite(this.node, this.kind, this.detail, {this.allowable = true});

  final AstNode node;
  final String kind;
  final String detail;
  final bool allowable;
}

/// 一条精确豁免：仓库相对路径 [path] 里允许 [count] 处 [kind] 命中。
///
/// 豁免是棘轮：命中数多于 [count] 时这个文件的全部命中都报（新增即红）；
/// 少于 [count] 时在文件头报「豁免过期」，逼着把数字往下调，所以只减不增。
final class Allowance {
  const Allowance(this.path, this.kind, this.count, this.reason);

  final String path;
  final String kind;
  final int count;
  final String reason;
}

/// 把一个文件换算成仓库相对路径（`fushi/lib/...`、`packages/fushi_engine/lib/...`）。
///
/// 用分析器给出的 pub 包根定位：包根目录名就是包目录名，包根的父目录叫
/// `packages` 时前面补上 `packages/`。不在任何 pub 包里的文件返回 null。
String? repoRelativePath(RuleContext context) {
  final File? file = context.currentUnit?.file;
  final Folder? root = context.package?.root;
  if (file == null || root == null) return null;
  final String rootPath = root.path;
  final String filePath = file.path;
  if (!filePath.startsWith(rootPath)) return null;
  final String inPackage = filePath
      .substring(rootPath.length)
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'^/+'), '');
  final Folder? parent = root.parent;
  final String prefix = parent != null && parent.shortName == 'packages'
      ? 'packages/'
      : '';
  return '$prefix${root.shortName}/$inPackage';
}

/// 「找命中 → 按精确豁免计数 → 报违规或报豁免过期」的公共骨架。
///
/// 子类只声明三件事：作用域 [appliesTo]、命中 [collect]、豁免 [allowances]。
/// 豁免写在规则自己的源码里（一处登记、规则单测校验它们都指向存在的文件），
/// 不用 `// ignore:` 在业务代码里铺。
abstract class RatchetedRule extends MultiAnalysisRule {
  RatchetedRule({required super.name, required super.description});

  /// 违规诊断；消息里的 `{0}` 是命中的 [RuleSite.kind]，`{1}` 是 [RuleSite.detail]。
  LintCode get violationCode;

  /// 豁免过期诊断；`{0}` kind，`{1}` 登记的额度，`{2}` 实际命中数。
  LintCode get staleCode;

  List<Allowance> get allowances;

  bool appliesTo(String repoPath);

  List<RuleSite> collect(CompilationUnit unit, RuleContext context);

  @override
  List<DiagnosticCode> get diagnosticCodes => <DiagnosticCode>[
    violationCode,
    staleCode,
  ];

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _UnitVisitor(this, context));
  }

  void _check(CompilationUnit unit, RuleContext context) {
    final String? path = repoRelativePath(context);
    if (path == null || !appliesTo(path)) return;
    final List<RuleSite> sites = collect(unit, context);
    final Map<String, int> budget = <String, int>{
      for (final Allowance a in allowances)
        if (a.path == path) a.kind: a.count,
    };
    final Map<String, List<RuleSite>> byKind = <String, List<RuleSite>>{};
    for (final RuleSite site in sites) {
      if (!site.allowable) {
        _violation(site);
        continue;
      }
      (byKind[site.kind] ??= <RuleSite>[]).add(site);
    }
    for (final MapEntry<String, List<RuleSite>> e in byKind.entries) {
      final int allowed = budget[e.key] ?? 0;
      if (e.value.length > allowed) {
        for (final RuleSite site in e.value) {
          _violation(site);
        }
      }
    }
    for (final MapEntry<String, int> e in budget.entries) {
      final int found = byKind[e.key]?.length ?? 0;
      if (found < e.value) {
        reportAtOffset(
          0,
          0,
          diagnosticCode: staleCode,
          arguments: <Object>[e.key, e.value, found],
        );
      }
    }
  }

  void _violation(RuleSite site) {
    reportAtNode(
      site.node,
      diagnosticCode: violationCode,
      arguments: <Object>[site.kind, site.detail],
    );
  }
}

class _UnitVisitor extends SimpleAstVisitor<void> {
  _UnitVisitor(this.rule, this.context);

  final RatchetedRule rule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) => rule._check(node, context);
}

/// 只在 `fushi/` 与 `packages/*/` 的 `lib/`、`bin/` 下生效的作用域判据。
bool isProductionSource(String repoPath) {
  final List<String> parts = repoPath.split('/');
  if (parts.first == 'fushi') {
    return parts.length > 2 && (parts[1] == 'lib' || parts[1] == 'bin');
  }
  if (parts.first == 'packages') {
    return parts.length > 3 && (parts[2] == 'lib' || parts[2] == 'bin');
  }
  return false;
}

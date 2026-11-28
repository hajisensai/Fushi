import 'dart:io';

import 'package:fushi_lints/src/ratchet.dart';
import 'package:fushi_lints/src/rules.dart';
import 'package:fushi_lints/src/rules/no_raw_design_controls.dart';
import 'package:test/test.dart';

/// 豁免表本身的结构校验：规则只能在被分析的文件上报「豁免过期」，文件被删掉
/// 之后它的豁免就没人看得见了，所以在这里按真实仓库核一遍。
void main() {
  // 包测试从 packages/fushi_lints 跑，仓库根在两级之上。
  final Directory repoRoot = Directory.current.parent.parent;

  test('每条豁免指向仓库里存在的文件，且在规则作用域内', () {
    expect(
      File('${repoRoot.path}/fushi/pubspec.yaml').existsSync(),
      isTrue,
      reason: '请从 packages/fushi_lints 包根跑测试',
    );
    final List<String> problems = <String>[];
    for (final RatchetedRule rule in fushiRules()) {
      for (final Allowance a in rule.allowances) {
        if (!File('${repoRoot.path}/${a.path}').existsSync()) {
          problems.add('${rule.name}: ${a.path} 不存在，删掉这条豁免');
        }
        if (!rule.appliesTo(a.path)) {
          problems.add('${rule.name}: ${a.path} 不在规则作用域内');
        }
        if (a.count <= 0) {
          problems.add('${rule.name}: ${a.path} 的额度必须为正数');
        }
        if (a.reason.trim().isEmpty) {
          problems.add('${rule.name}: ${a.path} 缺少豁免理由');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('设计控件的实现层路径都存在', () {
    final Set<String> layer = <String>{
      for (final DesignControl c in NoRawDesignControls.controls.values)
        ...c.implementationLayer,
    };
    final List<String> missing = <String>[
      for (final String p in layer)
        if (!File('${repoRoot.path}/$p').existsSync() &&
            !Directory('${repoRoot.path}/$p').existsSync())
          p,
    ];
    expect(missing, isEmpty, reason: '实现层路径已不存在：${missing.join(', ')}');
  });

  test('同一规则里 (文件, kind) 只登记一次', () {
    for (final RatchetedRule rule in fushiRules()) {
      final Set<String> seen = <String>{};
      for (final Allowance a in rule.allowances) {
        expect(
          seen.add('${a.path}#${a.kind}'),
          isTrue,
          reason: '${rule.name}: ${a.path} / ${a.kind} 重复',
        );
      }
    }
  });

  test('规则名唯一且带 fushi_ 前缀', () {
    final Set<String> names = <String>{};
    for (final RatchetedRule rule in fushiRules()) {
      expect(rule.name, startsWith('fushi_'));
      expect(names.add(rule.name), isTrue, reason: rule.name);
    }
  });
}

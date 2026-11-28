import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

// 「皮肤分支外泄」棘轮（架构重构 O2「皮肤分支收进组件」的地基）：设计系统判据
// （`isGlassDesign` / `isGlassDesignTheme` / `glassMaterialOf`）该只在公共组件层
// （`lib/src/utils/components/**`、`lib/src/utils/adaptive/**`）里出现，功能页
// 经公共组件拿到两套外观，不自己判。存量还没迁（O2 的活），这里先把「哪些文件
// 在组件层之外判了皮肤」冻成基线：
//
// - 基线之外的文件新出现判据调用 → 红（把分支收进公共组件，不往基线里加）；
// - 基线里的文件已经不判了 → 也红（把那一行从基线删掉），所以基线只会变短。
//
// 基线是 skin_branch_leak_baseline.txt，一行一个路径、按字典序。

const String _baselinePath = 'test/widgets/glass/skin_branch_leak_baseline.txt';

/// 公共组件层：皮肤分支本来就该住在这里。
const List<String> _componentLayers = <String>[
  'lib/src/utils/components/',
  'lib/src/utils/adaptive/',
];

final RegExp _skinPredicateCall = RegExp(
  r'\b(?:isGlassDesign|isGlassDesignTheme|glassMaterialOf)\s*\(',
);

/// [path] 在组件层之外、且代码（注释与字符串内容不算）里调用了皮肤判据。
bool leaksSkinBranch(String path, String source) {
  if (_componentLayers.any(path.startsWith)) return false;
  // 快路径：不提判据名字的文件免掉整文件词法扫描。
  if (!source.contains('isGlassDesign') &&
      !source.contains('glassMaterialOf')) {
    return false;
  }
  return _skinPredicateCall.hasMatch(maskCommentsAndStrings(source));
}

void main() {
  test('组件层之外判皮肤的文件只减不增', () {
    final List<String> baselineLines = File(_baselinePath)
        .readAsLinesSync()
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
    final List<String> sortedBaseline = <String>[...baselineLines]..sort();
    expect(baselineLines, sortedBaseline, reason: '基线要按字典序排好');
    final Set<String> baseline = baselineLines.toSet();
    expect(baseline.length, baselineLines.length, reason: '基线里有重复行');

    final Set<String> actual = <String>{};
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('.g.dart')) continue;
      final String path = entity.path.replaceAll(r'\', '/');
      if (leaksSkinBranch(path, entity.readAsStringSync())) actual.add(path);
    }

    final List<String> added = actual.difference(baseline).toList()..sort();
    final List<String> gone = baseline.difference(actual).toList()..sort();
    expect(
      added,
      isEmpty,
      reason:
          '这些文件在公共组件层之外新判了设计系统（isGlassDesign / '
          'glassMaterialOf）。把分支收进 utils/components 或 utils/adaptive 的'
          '公共组件，不要往基线里加：\n${added.join('\n')}',
    );
    expect(
      gone,
      isEmpty,
      reason: '这些文件已经不判皮肤了，把它们从 $_baselinePath 删掉：\n${gone.join('\n')}',
    );
  });

  group('守卫自检', () {
    test('功能页里调判据算外泄', () {
      const String source = '''
Widget build(BuildContext context) {
  return isGlassDesign(context) ? const A() : const B();
}
''';
      expect(leaksSkinBranch('lib/src/pages/some_page.dart', source), isTrue);
      expect(
        leaksSkinBranch(
          'lib/src/pages/some_page.dart',
          'final FushiGlassMaterial m = glassMaterialOf(context);',
        ),
        isTrue,
      );
      expect(
        leaksSkinBranch(
          'lib/src/models/x.dart',
          'final bool g = isGlassDesignTheme(theme);',
        ),
        isTrue,
      );
    });

    test('公共组件层里判皮肤不算', () {
      const String source = 'final bool g = isGlassDesign(context);';
      expect(
        leaksSkinBranch('lib/src/utils/components/fushi_x.dart', source),
        isFalse,
      );
      expect(
        leaksSkinBranch('lib/src/utils/adaptive/adaptive_x.dart', source),
        isFalse,
      );
    });

    test('只在注释、文档引用或字符串里提到不算', () {
      const String source = '''
/// 见 [isGlassDesign]。
// isGlassDesign(context) 的结果由公共组件消费。
const String note = 'isGlassDesign(context)';
''';
      expect(leaksSkinBranch('lib/src/pages/some_page.dart', source), isFalse);
    });
  });
}

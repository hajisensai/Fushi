/// 守卫：重复条目处置的命名统一（CLAUDE.md 命名术语表新增三行）。
///
/// ## 守什么
///
/// 1. **淘汰词不得复活**。`skipIfExists` / `onDuplicateTitle` / `DuplicateTitleCallback`
///    / `DuplicateTitleResolution` / `resolveBookTitleConflict` / `isVideoPathReferenced`
///    / `filterDroppedGameExes` 已全部换名，`lib/` 与 `test/` 里不得再出现（注释除外
///    ——讲历史的注释是有价值的，扫描跳过注释行）。
///
/// 2. **三态不得退回两参编码**。这是本次改名的实质：此前
///    `(bool skipIfExists, AskOnDuplicate? onDuplicateTitle)` 两个参数有四种组合、
///    只有三种合法，第四种的行为从没被写下来过。收敛成 sealed `DuplicatePolicy`
///    后非法组合不可表达。守卫钉住 sealed 声明与三个 factory 都在。
///
/// 3. **分派必须穷尽**。`resolveDuplicateTitle` 里的 switch 不许写 `default`——
///    将来加第四种策略要在这里编译报错，而不是悄悄落进某个兜底分支。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kPolicyFile = 'lib/src/epub/book_title_conflict.dart';

/// 已淘汰的名字 → 换成什么。
const Map<String, String> kRetiredNames = <String, String>{
  'skipIfExists': 'DuplicatePolicy.skip()',
  'onDuplicateTitle': 'policy: DuplicatePolicy.ask(...)',
  'DuplicateTitleCallback': 'AskOnDuplicate',
  'DuplicateTitleResolution': 'DuplicateChoice',
  'resolveBookTitleConflict': 'resolveDuplicateTitle',
  'isVideoPathReferenced': 'isDuplicateVideoPath',
  'filterDroppedGameExes': 'filterOutDuplicateGameExes',
};

/// 本守卫自身的路径。它的 [kRetiredNames] 清单里当然写满了淘汰词——不排除自己就
/// 会永远红（自指）。
const String kSelfPath = 'test/tools/duplicate_policy_naming_guard_test.dart';

/// 读取 [path] 并**剥掉整行注释**后的代码文本。
///
/// 结构断言一律走它，绝不用含注释的原文：本守卫早先版本直接 `src.contains(...)`，
/// 把 `sealed class DuplicatePolicy` 的真声明删掉、只在注释里留下同一串字面量，
/// 守卫照样全绿（实测）。注释是资产，但**不能替代声明**。
String _codeOf(String path) => File(path)
    .readAsLinesSync()
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

/// 扫 [roots] 下所有 .dart 的**非注释**行，返回 `文件:行号` 命中列表。
///
/// 跳过 `//` / `///` 开头的行：讲「此前叫什么、为什么改」的注释是资产，不是债。
List<String> _codeHits(List<String> roots, String needle) {
  final List<String> hits = <String>[];
  for (final String root in roots) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String rel = e.path.replaceAll(r'\', '/');
      if (rel.endsWith(kSelfPath)) continue;
      final List<String> lines = e.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//')) continue;
        if (lines[i].contains(needle)) {
          hits.add('$rel:${i + 1}');
        }
      }
    }
  }
  return hits;
}

void main() {
  const List<String> roots = <String>['lib', 'test'];

  group('淘汰词不得复活', () {
    kRetiredNames.forEach((String retired, String replacement) {
      test('$retired 已退休（应使用 $replacement）', () {
        expect(
          _codeHits(roots, retired),
          isEmpty,
          reason: '`$retired` 是淘汰词，新代码请用 `$replacement`'
              '（见 CLAUDE.md 命名术语表）。讲历史的注释不受限——把它写进注释即可。',
        );
      });
    });
  });

  group('三态不得退回两参编码', () {
    late final String src = _codeOf(kPolicyFile);

    test('DuplicatePolicy 是 sealed 的（非法组合不可表达）', () {
      expect(src.contains('sealed class DuplicatePolicy'), isTrue,
          reason: '必须 sealed：否则外部可以再造第四种状态，穷尽 switch 失效');
    });

    test('三个策略 factory 都在', () {
      for (final String f in <String>[
        'factory DuplicatePolicy.ask(',
        'factory DuplicatePolicy.skip(',
        'factory DuplicatePolicy.suffix(',
      ]) {
        expect(src.contains(f), isTrue, reason: '缺少 $f');
      }
    });

    test('resolveDuplicateTitle 只收一个策略参数', () {
      expect(src.contains('DuplicatePolicy policy'), isTrue);
      expect(
        src.contains('bool skipIfExists'),
        isFalse,
        reason: '不得退回 (bool, callback?) 两参编码三态',
      );
    });
  });

  test('策略分派必须穷尽（switch 不许有 default）', () {
    // 剥注释后再找 switch：注释里的 `default:` 不该算数。
    final String src = _codeOf(kPolicyFile);
    final int switchAt = src.indexOf('switch (policy)');
    expect(switchAt, isNonNegative, reason: '分派应是对 policy 的 switch');
    final String body = src.substring(switchAt);
    expect(
      // Dart 3 里 `case _:` / `case _ when ...` 与 `default:` 等效，一样让穷尽性
      // 失效。只堵 `default:` 是假绿——实测 `case _:` 能整个穿过去。
      RegExp(r'^\s*(default\s*:|case\s+_\s*(:|when))', multiLine: true)
          .allMatches(body)
          .map((RegExpMatch m) => m.group(0)!.trim())
          .toList(),
      isEmpty,
      reason: '写兜底分支就等于放弃穷尽检查——加第四种策略时这里必须编译报错，'
          '而不是悄悄走进 default / case _',
    );
  });
}

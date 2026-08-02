import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// BUG-1352 守卫：`packages/*/test/` 下不得再出现 schemaVersion 的**等值**断言。
///
/// 背景：`HibikiDatabase.schemaVersion` 每次加迁移都 +1，而「当前恰好是第几版」
/// 的等值断言散落在两个互不相干的测试根：
///   - `hibiki/test/` —— 由本仓约定的本地全量门（`flutter_test_failures.dart`
///     在 `hibiki/` 下跑）覆盖，schema bump 时作者一次批量替换就全改到；
///   - `packages/*/test/` —— 只由 CI 的 `Run package tests` 步骤覆盖，本地全量
///     门根本不跑，于是同一次批量替换够不着。
///
/// 结果就是 v65 → v66（PR#663，collection_relations + video_scrape_meta
/// .episode_number）时 `packages/hibiki_core/test/mihon_database_test.dart`
/// 的 `expect(database.schemaVersion, 65)` 漏改，本地 `hibiki/` 全量 16771 条
/// 全绿、CI 的 `Run package tests` 跑到第 40 条就红，develop 上 `Build Release
/// APK`（本仓真正的单测合并门）连红 5 个 commit。
///
/// 修法不是「每次记得多改一处」，而是消除这个跨根漂移源：package 侧的测试只该
/// 断言「本用例依赖的表已进入 schema」，即下界 `greaterThanOrEqualTo(<引入版本>)`。
/// 「当前是第几版」的等值守卫留在迁移阶梯测试 `hibiki/test/database/` 里——那儿
/// 本来就是它的家，也在同一个批量替换半径内。
void main() {
  final Directory packagesDir = Directory('../packages');

  test('packages 目录存在', () {
    expect(packagesDir.existsSync(), isTrue,
        reason: 'expected ${packagesDir.absolute.path}');
  });

  test('packages/*/test 下的 schemaVersion 断言必须是下界而非等值', () {
    if (!packagesDir.existsSync()) {
      fail('../packages 不存在——静默 return 会让这条守卫整条变绿（扫不到 = 没违规），'
          '这正是本轮要消灭的假绿形态。请在 hibiki/ 包根下运行。');
    }

    // 匹配 `expect(<任意>.schemaVersion, 66)` 这类第二参数是裸整数字面量的断言。
    // `greaterThanOrEqualTo(65)` / `lessThan(...)` 等 matcher 不匹配。
    final RegExp exactEquality =
        RegExp(r'expect\(\s*[A-Za-z0-9_.]*schemaVersion\s*,\s*[0-9]+\s*[,)]');

    final List<String> offenders = <String>[];
    int scannedFiles = 0;

    for (final FileSystemEntity pkg in packagesDir.listSync()) {
      if (pkg is! Directory) continue;
      final Directory testDir = Directory('${pkg.path}/test');
      if (!testDir.existsSync()) continue;

      for (final FileSystemEntity entity
          in testDir.listSync(recursive: true, followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        scannedFiles++;
        final String source = entity.readAsStringSync();
        // 剥注释走共享词法掩码（`test/helpers/source_guard.dart`），不手写
        // 「整行以 // 开头就跳过」：那个形态剥不掉行尾注释与 `/* */` 块注释，
        // 把违规写法塞进块注释就能骗绿（`source_guard_adoption_test` 守着这条）。
        // 这里不用 containsCodeLine 是因为判据是**正则**且报告要给行号，而它只收
        // 字面量 needle、只返回 bool；maskComments 是它内部用的同一个原语，且**等长
        // 等行**，掩码行下标可以直接回原文取证。
        final List<String> maskedLines = maskComments(source).split('\n');
        final List<String> rawLines = source.split('\n');
        for (int i = 0; i < maskedLines.length; i++) {
          if (exactEquality.hasMatch(maskedLines[i])) {
            offenders.add(
                '${entity.path.replaceAll(r'\', '/')}:${i + 1}: ${rawLines[i].trim()}');
          }
        }
      }
    }

    expectScanScale(scannedFiles,
        what: 'packages/*/test 下的 .dart', atLeast: 50, measured: 72);
    expect(offenders, isEmpty,
        reason: 'package 侧测试跑在 CI 的 `Run package tests` 里，拿不到 hibiki/test '
            '那次批量替换，schema bump 必漏改。改成下界断言，例如\n'
            '  expect(db.schemaVersion, greaterThanOrEqualTo(65),\n'
            "      reason: 'v65 = <本用例依赖的表>');\n"
            '违规位置：\n${offenders.join('\n')}');
  });
}

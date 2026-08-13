import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：**会构建 app 的 job，必须把每一种「烘进包里的密钥」都注入**。
///
/// ## 起因（BUG-1588）
///
/// `tmdb_default_key.dart` 入库的是空占位（`kBuiltinTmdbApiKey = ''`），真值
/// 由 CI 从 `secrets.TMDB_API_KEY` sed 进去。但这步注入**只写进了验证构建**
/// （`main.yml` / `build-multiplatform.yml`），两条**发布** workflow
/// （`release.yml` / `release-desktop.yml`）整个漏了。
///
/// 后果极其隐蔽：CI 全绿（验证构建有 key，TMDB 刮削正常），只有**发出去的包**
/// 里 key 是空串 → `TmdbVideoMetadataProvider.isAvailable` 恒 false → 用户侧
/// 表现成「TMDB 连不上」。没有任何构建期症状能暴露它。
///
/// ## 为什么用 dandanplay 当「这个 job 在构建 app」的判据
///
/// 不去数 `flutter build`（它散落在脚本、matrix、复合 action 里，判据不稳），
/// 而是拿**同类密钥**当锚：dandanplay 的 AppId/AppSecret 与 TMDB key 是同一种
/// 东西——入库空占位 + CI 注入真值 + 缺了就静默降级。凡是需要前者的 job，必然
/// 也需要后者。于是「成对出现」这条不变式既简单又自维护：新增构建 job 时只要
/// 抄了一个就会被这条守卫抓住漏掉的另一个。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');

  /// 步骤名 -> 人类可读的说明，用于失败时指出漏了什么。
  const String dandanplayStep = 'Provide gitignored dandanplay secret stub';
  const String tmdbStep = 'Provide gitignored TMDB API key stub';

  test('前置：workflows 目录存在', () {
    expect(workflowsDir.existsSync(), isTrue,
        reason: 'expected ${workflowsDir.absolute.path}');
  });

  final List<File> workflows = workflowsDir.existsSync()
      ? (workflowsDir
          .listSync()
          .whereType<File>()
          .where(
              (File f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path)))
      : <File>[];

  /// workflow 名 -> (dandanplay 步骤数, tmdb 步骤数)。
  final Map<String, List<int>> counts = <String, List<int>>{};

  for (final File workflow in workflows) {
    final String name = workflow.uri.pathSegments.last;
    // 按**整行**比对，不用子串包含：`- name: X` 是 `- name: X MUTANT` 的前缀，
    // 子串计数会把改了名的步骤照旧算进去，守卫变成空转。这是本守卫第一次变异
    // 实测（把步骤名改成 `... MUTANT`）暴露出来的。
    final List<String> lines = workflow
        .readAsLinesSync()
        .map((String l) => l.trim())
        .toList(growable: false);
    final int dan =
        lines.where((String l) => l == '- name: $dandanplayStep').length;
    final int tmdb = lines.where((String l) => l == '- name: $tmdbStep').length;
    if (dan > 0 || tmdb > 0) counts[name] = <int>[dan, tmdb];
  }

  test('守卫没跑空：至少扫到一个注入密钥桩的 workflow', () {
    expect(workflows, isNotEmpty, reason: '一个 workflow 都没扫到');
    expect(counts, isNotEmpty,
        reason: '一个「注入 gitignored 密钥桩」的步骤都没扫到。步骤名改过了？'
            '本守卫已失去锚点，下面的成对断言此刻是空转——先修守卫。');
  });

  test('每个注入 dandanplay 的 workflow 都同样数量地注入 TMDB key', () {
    final List<String> offenders = <String>[];
    counts.forEach((String name, List<int> pair) {
      final int dan = pair[0];
      final int tmdb = pair[1];
      if (dan != tmdb) {
        offenders.add('  $name: dandanplay 桩 $dan 个，TMDB 桩 $tmdb 个');
      }
    });
    expect(offenders, isEmpty,
        reason: '这些 workflow 的两种「烘进包里的密钥」注入步骤数量对不上。'
            '少的那一种在**发出去的包**里会是空占位，而 CI 依旧全绿——'
            'BUG-1588 就是 release.yml / release-desktop.yml 漏了 TMDB 注入，'
            '导致用户侧 TMDB 恒「未配置」、被读成「连不上」：\n'
            '${offenders.join("\n")}');
  });
}

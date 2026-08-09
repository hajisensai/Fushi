import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2721 守卫：GitHub Actions 缓存必须留在 10 GB 配额里。
///
/// 2026-08-02 实测 `gh api repos/hajisensai/fushi/actions/cache/usage` =
/// 10.65 GB / 14 条，超配额，GitHub 一直在 LRU 驱逐。驱逐不是「洁癖问题」：
/// 桌面发布 run 30729229450 变红的最后一环就是 vcpkg 缓存被驱逐后冷编 + 拉网失败。
///
/// 超配额是三条规则叠出来的，本守卫逐条钉死：
///
/// 1. **同一份 pub cache 被存了两遍。** `subosito/flutter-action@v2` 的
///    `cache: true` 自己就会把 `~/.pub-cache` 存成
///    `flutter-pub-<os>-<channel>-<ver>-<arch>-<pubspec.lock hash>`；workflow 里
///    再挂一个 `actions/cache` 存同一个目录，只是换了个 key 名。实测
///    `flutter-pub-linux-...-3fa29c49` = 149,357,387 B 与
///    `Linux-pubcache-3fa29c49` = 149,365,205 B——同一批字节，两条记录，
///    三平台合计白占 447 MB，且每个作业还要多花 6~32 s 重复解压一次。
///    ⇒ 任何 workflow 都不许再为 pub cache 目录挂 `actions/cache`。
///
/// 2. **同一份 Gradle 缓存被存了两遍。** `main.yml` / `release.yml` 在缓存步骤
///    **之前**用 `sed -i` 删掉了 `build.gradle` / `settings.gradle` 里的 aliyun
///    镜像行，而 `build-multiplatform.yml` 的同名 sed 在缓存步骤**之后**。
///    两边 `hashFiles('fushi/android/**/*.gradle*')` 因此算在不同内容上，
///    产出两条 key：`Linux-gradle-6facc6ed…`（2,901,298,096 B）与
///    `Linux-gradle-5709404c…`（2,901,388,049 B）——差 89,953 B，实质同一份，
///    白占 2.7 GB。⇒ 三个 workflow 的 Gradle 缓存 path + key 必须逐字相同，
///    且缓存步骤必须排在那些 sed **前面**。
///
/// 3. **Gradle 缓存里塞了派生产物。** `~/.gradle/caches` 全量含
///    `<ver>/transforms`（解包 AAR / jetify / desugar 的输出）。本机实测
///    `~/.gradle/caches/8.14.2/transforms` = 5,073.7 MB，是
///    `~/.gradle/caches/modules-2`（1,937.2 MB）的 2.6 倍，而它完全可以从
///    modules-2 重算。⇒ 只缓存下载物（`modules-2` / `wrapper/dists`）
///    加一个记账用的 `journal-1`，不缓存整个 `~/.gradle/caches`。
void main() {
  final Directory workflowsDir = Directory('../.github/workflows');

  test('workflows 目录存在', () {
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

  /// 一个 workflow 步骤块：`- name:` / `- uses:` 起头，延伸到下一个同缩进
  /// （或更浅）的列表项。行号是 0 基，指向原文。
  final List<_CacheStep> allCacheSteps = <_CacheStep>[];

  /// 每个 workflow 里「用 sed 改 build.gradle / settings.gradle」的最早行号。
  final Map<String, int> earliestGradleSed = <String, int>{};

  final RegExp stepHeader = RegExp(r'^(\s*)-\s+(name|uses):');
  final RegExp pathKey = RegExp(r'^(\s*)path:\s*(.*)$');
  final RegExp keyLine = RegExp(r'^\s*key:\s*(.*)$');
  final RegExp restoreKeysLine = RegExp(r'^\s*restore-keys:\s*(.*)$');
  // `sed ... build.gradle` / `sed ... settings.gradle`（就地编辑与否都算：任何
  // 对这两个文件的 sed 改写都会污染 hashFiles）。
  final RegExp gradleSed = RegExp(r'\bsed\b[^\n]*\b(build|settings)\.gradle\b');

  for (final File workflow in workflows) {
    final String name = workflow.uri.pathSegments.last;
    final String source = workflow.readAsStringSync();
    final List<String> raw = source.split('\n');
    // 注释不是配置：整块扫描前先掩成等长空白，免得注释里写的
    // `~/.gradle/caches` / `path: ~/.pub-cache` 把守卫骗绿或骗红。
    final List<String> masked = maskHashComments(source).split('\n');

    for (int i = 0; i < masked.length; i++) {
      if (gradleSed.hasMatch(masked[i])) {
        earliestGradleSed[name] = earliestGradleSed[name] == null
            ? i
            : (earliestGradleSed[name]! < i ? earliestGradleSed[name]! : i);
      }

      final RegExpMatch? header = stepHeader.firstMatch(masked[i]);
      if (header == null) continue;
      final int indent = header.group(1)!.length;

      // 步骤块 = 从本行到下一个缩进 <= indent 的列表项 / 更浅的 key 行。
      int end = masked.length;
      for (int j = i + 1; j < masked.length; j++) {
        final String line = masked[j];
        if (line.trim().isEmpty) continue;
        final int lead = line.length - line.trimLeft().length;
        if (lead <= indent) {
          end = j;
          break;
        }
      }
      final List<String> block = masked.sublist(i, end);
      if (!block.any((String l) => l.contains('uses: actions/cache@'))) {
        continue;
      }

      // path: 可能是标量，也可能是 `|` 块。
      final List<String> paths = <String>[];
      for (int j = 0; j < block.length; j++) {
        final RegExpMatch? pm = pathKey.firstMatch(block[j]);
        if (pm == null) continue;
        final String inline = pm.group(2)!.trim();
        if (inline.isNotEmpty && inline != '|' && inline != '|-') {
          paths.add(inline);
          continue;
        }
        final int pathIndent = pm.group(1)!.length;
        for (int k = j + 1; k < block.length; k++) {
          final String line = block[k];
          if (line.trim().isEmpty) continue;
          final int lead = line.length - line.trimLeft().length;
          if (lead <= pathIndent) break;
          paths.add(line.trim());
        }
      }

      String keyText = '';
      for (final String line in block) {
        final RegExpMatch? km = keyLine.firstMatch(line);
        if (km != null) {
          keyText = km.group(1)!.trim();
          break;
        }
      }
      final List<String> restoreKeys = <String>[];
      for (int j = 0; j < block.length; j++) {
        if (!restoreKeysLine.hasMatch(block[j])) continue;
        final int rkIndent = block[j].length - block[j].trimLeft().length;
        for (int k = j + 1; k < block.length; k++) {
          final String line = block[k];
          if (line.trim().isEmpty) continue;
          final int lead = line.length - line.trimLeft().length;
          if (lead <= rkIndent) break;
          restoreKeys.add(line.trim());
        }
        break;
      }

      allCacheSteps.add(_CacheStep(
        workflow: name,
        line: i + 1,
        header: raw[i].trim(),
        paths: paths,
        key: keyText,
        restoreKeys: restoreKeys,
      ));
    }
  }

  test('扫描到了 actions/cache 步骤（守卫没跑空）', () {
    expect(allCacheSteps, isNotEmpty,
        reason: '一个 actions/cache 步骤都没扫到，说明块切分坏了或 workflow 改版了；'
            '本守卫的其余断言此时全部无意义。');
  });

  test('没有 workflow 再为 pub cache 目录挂第二个 actions/cache', () {
    // flutter-action 的 `cache: true` 已经存过这两个目录（Linux/macOS 是
    // ~/.pub-cache，Windows 是 %LOCALAPPDATA%\Pub\Cache）。
    bool isPubCachePath(String p) {
      final String v = p.toLowerCase().replaceAll(r'\', '/');
      return v.contains('.pub-cache') ||
          (v.contains('appdata/local/pub/cache'));
    }

    final List<String> offenders = allCacheSteps
        .where((_CacheStep s) => s.paths.any(isPubCachePath))
        .map((_CacheStep s) => '${s.workflow}:${s.line} ${s.header} '
            '(path: ${s.paths.join(", ")})')
        .toList();

    expect(offenders, isEmpty,
        reason: 'subosito/flutter-action@v2 的 `cache: true` 已经把 pub cache 存成 '
            '`flutter-pub-<os>-...-<pubspec.lock hash>` 了；再挂一个 actions/cache 只是'
            '把同一批字节换个 key 名存第二遍，白占 GitHub 那 10 GB 配额（三平台 447 MB）'
            '并让每个作业多解压一次。删掉这些步骤：\n${offenders.join("\n")}');
  });

  group('Gradle 缓存', () {
    final List<_CacheStep> gradleSteps = allCacheSteps
        .where((_CacheStep s) => s.key.contains('-gradle-'))
        .toList();

    test('三个 Android workflow 各有且仅有一个 Gradle 缓存步骤', () {
      final List<String> owners =
          gradleSteps.map((_CacheStep s) => s.workflow).toList()..sort();
      expect(
          owners,
          equals(<String>[
            'build-multiplatform.yml',
            'main.yml',
            'release.yml',
          ]),
          reason: 'Gradle 缓存步骤的归属变了。多一个 workflow 存 Gradle 缓存就多一条 '
              '2.7 GB 级记录，改动前先算配额；少一个则说明本守卫已失去锚点。'
              '实际扫到：$owners');
    });

    test('三处的 path + key + restore-keys 逐字相同', () {
      final Set<String> shapes = gradleSteps
          .map((_CacheStep s) => 'path=${s.paths.join("|")} key=${s.key} '
              'restore=${s.restoreKeys.join("|")}')
          .toSet();
      expect(shapes.length, 1,
          reason: 'Gradle 缓存 key 只要有一处不同，同一份 2.7 GB 内容就会被存成两条。'
              'develop 上真发生过：`Linux-gradle-6facc6ed…` 与 '
              '`Linux-gradle-5709404c…` 只差 89,953 B。当前形状：\n'
              '${gradleSteps.map((_CacheStep s) => "${s.workflow}:${s.line} "
                  "path=${s.paths} key=${s.key}").join("\n")}');
    });

    test('只缓存下载物，不缓存 transforms 之类的派生产物', () {
      final List<String> offenders = <String>[];
      for (final _CacheStep step in gradleSteps) {
        for (final String p in step.paths) {
          final String v = p.trim();
          // 整个 ~/.gradle/caches（或 ~/.gradle）会把 <ver>/transforms 一起吞进来。
          if (v == '~/.gradle' ||
              v == '~/.gradle/' ||
              v == '~/.gradle/caches' ||
              v == '~/.gradle/caches/') {
            offenders.add('${step.workflow}:${step.line} path 含 "$v"');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: '`~/.gradle/caches` 全量里 `<ver>/transforms` 是可从 modules-2 '
              '重算的构建产物（本机实测 5,073.7 MB vs modules-2 的 1,937.2 MB）。'
              '缓存它是拿配额换 CPU，而配额才是本仓的瓶颈。只列 '
              '`~/.gradle/caches/modules-2` / `~/.gradle/caches/journal-1` / '
              '`~/.gradle/wrapper/dists`：\n${offenders.join("\n")}');
    });

    test('Gradle 缓存步骤必须排在改写 build.gradle/settings.gradle 的 sed 前面', () {
      // 反向锚：那些 sed 还在，才说明这条排序断言仍有对象可查。
      expect(
          earliestGradleSed.keys.toSet(),
          containsAll(
              <String>['build-multiplatform.yml', 'main.yml', 'release.yml']),
          reason: '三个 workflow 里删 aliyun 镜像的 sed 消失了？若注入方式改版请同步'
              '更新本守卫，别让它空转。实际：${earliestGradleSed.keys.toList()..sort()}');

      final List<String> offenders = <String>[];
      for (final _CacheStep step in gradleSteps) {
        final int? sedLine = earliestGradleSed[step.workflow];
        if (sedLine == null) continue;
        if (sedLine + 1 < step.line) {
          offenders.add('${step.workflow}: sed 在第 ${sedLine + 1} 行，'
              'Gradle 缓存步骤在第 ${step.line} 行');
        }
      }
      expect(offenders, isEmpty,
          reason: 'hashFiles() 算的是**当时磁盘上**的内容。sed 改过 build.gradle / '
              'settings.gradle 之后再算 key，得到的哈希与「没改过」的 workflow 不同，'
              '同一份 Gradle 缓存就被存成两条 2.7 GB 记录。把 sed 步骤挪到缓存步骤'
              '之后（gradle 真正跑起来之前即可）：\n${offenders.join("\n")}');
    });
  });

  test('PR 关闭后回收 PR 作用域缓存的 workflow 还在，且不碰发布', () {
    final File cleanup = File('../.github/workflows/cache-cleanup.yml');
    expect(cleanup.existsSync(), isTrue,
        reason: 'cache-cleanup.yml 是把 refs/pull/<N>/merge 桶还给配额的唯一入口；'
            'GitHub 自己要等 7 天无访问才回收。');
    final String masked = maskHashComments(cleanup.readAsStringSync());
    expect(masked, contains('actions/caches'),
        reason: '清理步骤必须真的调 DELETE /actions/caches');
    // 这条 workflow 只做回收，绝不能长出发布动作（CLAUDE.md 发布通道硬规则）。
    for (final String forbidden in <String>[
      'softprops/action-gh-release',
      'gh release create',
      'make_latest',
    ]) {
      expect(masked.contains(forbidden), isFalse,
          reason: 'cache-cleanup.yml 不得触碰发布链路，发现：$forbidden');
    }
  });
}

/// 一个 `actions/cache` 步骤的规范化形状。
class _CacheStep {
  const _CacheStep({
    required this.workflow,
    required this.line,
    required this.header,
    required this.paths,
    required this.key,
    required this.restoreKeys,
  });

  final String workflow;

  /// 1 基行号（指向 `- name:` / `- uses:` 那行）。
  final int line;
  final String header;
  final List<String> paths;
  final String key;
  final List<String> restoreKeys;
}

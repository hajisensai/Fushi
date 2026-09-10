import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 同一个 git 依赖仓库，全仓的 `ref:` 必须**逐字一致**。
///
/// 由来（2026-09-10 实测）：`fushi-subtitles` 的 sha 被 #1400 抬到 8820d38，但
/// #1316 新增的 `packages/fushi_engine` / `packages/fushi_server` 两个 pubspec 里
/// 还钉着 PR 分支当时的旧 sha。后果是**两份副本**：
///
/// - `ci/patches/git/` 的补丁目录按 `<repo>-<sha>` 命名，补丁打到了新 sha 那份；
/// - 而 `fushi_asr_onnx_ffi` 解析到的是**旧 sha** 那份，没打补丁 →
///   `entry.readBytes()` 在本仓钉的 archive 3.6.1 上不存在 →
///   `packages/fushi_server` 三个 suite 编译失败。
///
/// 这条红只有 CI 的 `Run package tests` 抓得到：app 侧的 analyze 与主应用测试
/// 完全不碰 fushi_server，本机也不会跑到（`flutter analyze` 不覆盖 packages/*）。
/// 所以把「sha 单一真值」变成一条可在本地跑的静态事实。
///
/// 顺带钉住补丁目录：若 `ci/patches/git/` 下存在以该 repo 命名的目录，它的 sha
/// 必须就是当前钉的那个——否则 `ci/apply-patches.sh` 会**静默跳过**（只打一行
/// WARNING），补丁形同不存在。
void main() {
  /// 测试的 cwd 恒为 `fushi/`，仓库根就是它的父目录。
  ///
  /// **不要**靠「一路往上找 .git」定位：在 `.claude/worktrees/<task>/` 里那样爬
  /// 会爬到主 checkout，随后 listSync(recursive) 就会扫进同级其它 worktree 的
  /// build 产物（并撞上构建中途消失的目录 → PathNotFoundException）。
  Directory repoRoot() => Directory.current.parent;

  /// 从一份 pubspec 里抽出 `url:` 含 [repo] 的那些块的 `ref:`。
  List<String> refsFor(File pubspec, String repo) {
    if (!pubspec.existsSync()) return const <String>[];
    final List<String> lines = pubspec.readAsLinesSync();
    final List<String> refs = <String>[];
    bool inRepoBlock = false;
    for (final String raw in lines) {
      final String line = raw.trim();
      if (line.startsWith('url:')) {
        inRepoBlock = line.contains(repo);
        continue;
      }
      if (!inRepoBlock) continue;
      if (line.startsWith('ref:')) {
        refs.add(line.substring(4).trim().replaceAll('"', '').replaceAll("'", ''));
        inRepoBlock = false;
      }
    }
    return refs;
  }

  test('fushi-subtitles 的 git ref 全仓只有一个值', () {
    const String repo = 'fushi-subtitles';
    final Directory root = repoRoot();
    final Map<String, List<String>> byFile = <String, List<String>>{};

    // 扫描面 = 根 pubspec + app + 本仓自有的 packages/*，逐个显式列出，
    // 不递归全树（理由见 repoRoot 的说明）。packages/ 下按目录枚举，
    // 新增一个包会自动进来。
    final List<File> pubspecs = <File>[
      File('${root.path}/pubspec.yaml'),
      File('${root.path}/fushi/pubspec.yaml'),
    ];
    final Directory packages = Directory('${root.path}/packages');
    if (packages.existsSync()) {
      for (final FileSystemEntity entity in packages.listSync()) {
        if (entity is Directory) {
          pubspecs.add(File('${entity.path}/pubspec.yaml'));
        }
      }
    }

    for (final File pubspec in pubspecs) {
      final List<String> refs = refsFor(pubspec, repo);
      if (refs.isEmpty) continue;
      final String path = pubspec.path.replaceAll(r'\', '/');
      byFile[path.substring(root.path.length + 1)] = refs;
    }

    expect(byFile, isNotEmpty,
        reason: '一个 $repo 的 ref 都没扫到——扫描面空了，这条守卫等于没跑');

    final Set<String> distinct =
        byFile.values.expand((List<String> r) => r).toSet();
    expect(
      distinct,
      hasLength(1),
      reason: '同一个 git 仓库被钉了多个 sha，pub 会解析出**两份副本**：\n'
          '${byFile.entries.map((MapEntry<String, List<String>> e) => '  ${e.key}: ${e.value.join(", ")}').join('\n')}\n'
          'ci/patches/git/ 的补丁按 <repo>-<sha> 命名，只会打中其中一份，另一份'
          '静默地没打补丁——本机与 app 侧测试都看不出来，只有 CI 的 '
          '`Run package tests` 会因编译失败而红。',
    );

    // 补丁目录若在，sha 必须与当前钉的一致。
    final Directory patches = Directory('${root.path}/ci/patches/git');
    if (!patches.existsSync()) return;
    final String pinned = distinct.single;
    for (final FileSystemEntity entity in patches.listSync()) {
      final String name = entity.path.replaceAll(r'\', '/').split('/').last;
      if (!name.startsWith('$repo-')) continue;
      expect(
        name,
        '$repo-$pinned',
        reason: '补丁目录名里的 sha 与 pubspec 钉的对不上。'
            'ci/apply-patches.sh 按目录名去 pub-cache 找目标，对不上就只打一行 '
            'WARNING 然后跳过——补丁形同不存在，而依赖它的包会在编译期才炸。',
      );
    }
  });
}

// 由改动文件推导「必须加跑哪些测试」。
//
// ## 为什么要有这个工具
//
// `docs/agent/fast-workflow.md` 里的默认整批 35 条守卫，扫的是 Dart 源码树，
// 目录枚举、自动纳入新文件，所以「整批跑」就够了。真正会漏的是另一半：
// **读 native / 非 Dart 树的守卫**（`hibiki/windows`、`hibiki/android`、
// `packages/*/windows`、`native/`、`tools/browser-extension`、`.github/workflows`、
// `third_party/` …）。它们的触发面不在 Dart 树里，整批清单抓不到，于是文档里
// 长期挂着一份**手写的 9 个测试名**当「按触发条件加跑」清单。
//
// 那份名字表的分类维度是「资产种类」（workflow / 扩展 / 二进制 / native），
// 而真实触发面的维度是「哪棵源码树」。两者不对齐，结果是五棵最大的 native 树里
// 只有一棵被点了一个名——改一行 `hibiki/windows/runner/*.cpp` 会牵动十几条守卫，
// 清单一条都没提。**这是「合入的 PR 把红带进 develop」的共同根因之一。**
//
// ## 判据：不再点名，改为从仓库现状推导
//
// 每条这类守卫都必须在源码里写出它要读的路径（否则它读不到东西）。所以
// **测试文件自己的路径字面量就是触发面的真相源**：
//
//   改动文件 F 触发测试 T  ⟺  T 的源码里引用了某个仓库路径 P，且 F 落在 P 底下。
//
// 这个判据比手写名字表稳，关键在于**耦合**：被提取的字符串和被守卫断言存在的
// 路径是同一个文件里的同一个字面量。树改名时，守卫必须改那个字面量（不然它自己
// 就红了），于是索引自动跟着走。名字表没有这种耦合，只会烂。
//
// ## 有意的偏置：过度触发，不漏触发
//
// 漏一条 ⇒ 红带进 develop（本仓已发生 3 次）；多跑一条 ⇒ 多花几秒。两者代价不
// 对称，所以所有取舍一律偏向多输出：
//
// - **不剥注释**。注释里点名一棵树，本身就是「这个测试和那棵树有关」的证据；
//   而且 `tool/` 下没法 import `test/helpers/source_guard.dart`（它依赖
//   `package:flutter_test`），自己再写一遍词法器只会多一处会烂的实现。
// - 路径候选取**后缀最长匹配**，并且允许补 `hibiki/` 前缀（测试的 cwd 是
//   `hibiki/`，`'windows/runner/x.cpp'` 这种写法指的是 `hibiki/windows/...`）。
// - 引用到**文件**时，同目录的其它文件也算触发（新增文件才不会被漏掉）。
//
// 唯一的收敛手段是**磁盘存在性**：候选路径必须真的在仓库里存在。这既滤掉了 URL、
// 正则、临时目录，也让规则跟着仓库自动更新。
//
// ## 用法
//
//   cd hibiki
//   dart run tool/tests_for_changes.dart --base=origin/develop
//   dart run tool/tests_for_changes.dart hibiki/windows/runner/flutter_window.cpp
//   dart run tool/tests_for_changes.dart --base=origin/develop --explain
//   dart run tool/tests_for_changes.dart --stats
//
// 输出是可直接喂给 `flutter test` 的、相对 `hibiki/` 的测试路径，每行一个：
//
//   cd hibiki && dart run tool/flutter_test_failures.dart --no-pub \
//     --output-dir=../.codex-test/flutter-test-trigger \
//     $(dart run tool/tests_for_changes.dart --base=origin/develop)
//
// ignore_for_file: avoid_print

import 'dart:io';

/// 仓库根相对路径，一律 POSIX 分隔符、无前导 `./`。
typedef RepoPath = String;

/// 「容器目录」：底下装的是互不相干的多个域，整棵树当一个触发单元没有意义。
///
/// 只有这两个是硬编码的名字，而且它们的腐烂是**响的**不是**哑的**——
/// `tests_for_changes_guard_test.dart` 断言两者都存在且各含 ≥5 个子目录，
/// 仓库真改了布局会当场红。
const Set<RepoPath> kContainerDirs = <RepoPath>{'hibiki', 'packages'};

/// 非源码、且**各机器有无不一致**的目录名。
///
/// 它们必须被排除，理由不是「没用」而是「会让索引因机器而异」：本机有
/// `hibiki/build/windows/x64/...`、CI 的干净 checkout 没有，同一条路径字面量
/// 在两处解析成不同深度，于是本机推导出的测试集和 CI 的不一样。索引必须只由
/// **入库内容**决定。
const Set<String> kNonSourceDirs = <String>{
  'build',
  '.dart_tool',
  '.gradle',
  '.codex-test',
  '.worktrees',
  'node_modules',
  'Pods',
};

/// 默认整批 35 条 + 定向测试已经覆盖的 Dart 源码树。
///
/// 落在这些树里的改动**不由本工具输出**：它们的守卫是目录枚举型的，
/// 「整批跑」本来就抓得到，再输出一遍只会把结果淹掉、让人不看。
/// `--include-dart` 可关掉这层过滤。
const List<String> kDefaultBatchCoveredGlobs = <String>[
  'hibiki/lib/',
  'hibiki/test/',
  'hibiki/integration_test/',
];

/// 仓库磁盘视图。抽成对象是为了让守卫测试能对着真仓库跑同一份逻辑，
/// 而不必把 `Directory` 到处传。
class RepoFs {
  RepoFs(this.root);

  /// 仓库根目录（含 `hibiki/pubspec.yaml` 与 `native/`）。
  final Directory root;

  final Map<RepoPath, bool> _existsCache = <RepoPath, bool>{};
  final Map<RepoPath, bool> _isDirCache = <RepoPath, bool>{};
  final Map<RepoPath, Set<String>> _entriesCache = <RepoPath, Set<String>>{};
  Set<RepoPath>? _topLevelCache;

  String _abs(RepoPath repoPath) =>
      repoPath.isEmpty ? root.path : '${root.path}/$repoPath';

  /// 某个目录下的直接子项名。**大小写按磁盘原样**。
  Set<String> _entriesOf(RepoPath dirRepoPath) =>
      _entriesCache.putIfAbsent(dirRepoPath, () {
        final Directory dir = Directory(_abs(dirRepoPath));
        if (!dir.existsSync()) return const <String>{};
        try {
          return dir
              .listSync(followLinks: false)
              .map((FileSystemEntity e) =>
                  e.path.replaceAll('\\', '/').split('/').last)
              .toSet();
        } on FileSystemException {
          return const <String>{};
        }
      });

  /// 仓库里是否真有这个路径（文件或目录），**逐段精确大小写比对**。
  ///
  /// 不能直接用 `existsSync`：Windows 的 NTFS 大小写不敏感，且会静默吃掉路径段
  /// 末尾的空格与点。于是注释里的「Android/iOS/macOS/Windows/Linux」会被判成
  /// `hibiki/Linux` 存在——**在 Linux CI 上却不存在**，同一份索引两个平台两个样。
  /// 逐段比对目录列表把这两类幽灵一次性掐掉。
  bool exists(RepoPath repoPath) => _existsCache.putIfAbsent(repoPath, () {
        final List<String> segments = repoPath.split('/');
        RepoPath cursor = '';
        for (final String seg in segments) {
          if (seg.isEmpty) return false;
          if (!_entriesOf(cursor).contains(seg)) return false;
          cursor = cursor.isEmpty ? seg : '$cursor/$seg';
        }
        return true;
      });

  /// 这个路径是不是目录。
  bool isDirectory(RepoPath repoPath) => _isDirCache.putIfAbsent(repoPath,
      () => exists(repoPath) && Directory(_abs(repoPath)).existsSync());

  /// 仓库根下的一级目录名（含 `.github`）。**运行时枚举，不硬编码。**
  Set<RepoPath> topLevelDirs() => _topLevelCache ??= root
      .listSync(followLinks: false)
      .whereType<Directory>()
      .map((Directory d) => d.path.replaceAll('\\', '/').split('/').last)
      .where((String name) => name != '.git')
      .toSet();
}

/// 从 [start] 起向上找仓库根：以 `hibiki/pubspec.yaml` + `native/` 同时存在为准。
Directory locateRepoRoot(Directory start) {
  Directory dir = start.absolute;
  for (int depth = 0; depth < 12; depth++) {
    final bool hasApp = File('${dir.path}/hibiki/pubspec.yaml').existsSync();
    final bool hasNative = Directory('${dir.path}/native').existsSync();
    if (hasApp && hasNative) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('定位不到仓库根（找不到 hibiki/pubspec.yaml + native/）：'
      '${start.absolute.path}');
}

/// 把任意写法的路径候选归一成仓库根相对路径；无法归一则返回 `null`。
///
/// 归一规则（按顺序试，取第一个在磁盘上存在的）：
/// 1. 丢掉 `.` / `..` / 空段；
/// 2. 从最长后缀往最短试，要求首段是仓库一级目录；
/// 3. 同一后缀内，**从最长前缀往最短退**，落到最近的一个真实存在的祖先；
/// 4. 都不成时，给各级后缀补 `hibiki/` 前缀再走一遍（测试 cwd 是 `hibiki/`）。
///
/// 第 3 步不是可有可无的收尾，它兜住三类实测漏网：
/// - 指向**构建产物**的路径（`native/galgame_hook/dist` 磁盘上不存在）；
/// - 注释里的**省略写法**（`packages/flutter_inappwebview_windows/.../x.cpp`）；
/// - 被删/被改名的叶子文件。
/// 三类都属于「这个测试确实关心那棵树」，退到最近祖先是正确的过度触发。
///
/// 最后拒绝 [kContainerDirs]——它们太宽，等于「整个仓库」。
RepoPath? normalizeRepoPath(String candidate, RepoFs fs) {
  // `C:/x`、`a*b` 之类不可能是仓库路径，而且在 Windows 上 existsSync 会直接抛。
  if (_illegalPathChar.hasMatch(candidate)) return null;
  final List<String> segments = candidate
      .replaceAll('\\', '/')
      .split('/')
      .where((String s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  if (segments.isEmpty) return null;

  final Set<RepoPath> topLevel = fs.topLevelDirs();
  RepoPath? best;
  int bestDepth = 0;

  void consider(RepoPath joined) {
    if (kContainerDirs.contains(joined)) return;
    final List<String> parts = joined.split('/');
    if (parts.any(kNonSourceDirs.contains)) return;
    if (!fs.exists(joined)) return;
    if (parts.length <= bestDepth) return;
    best = joined;
    bestDepth = parts.length;
  }

  for (int start = 0; start < segments.length; start++) {
    for (int end = segments.length; end > start; end--) {
      final String tail = segments.sublist(start, end).join('/');
      if (topLevel.contains(segments[start])) consider(tail);
      // 首段不是一级目录时，可能是相对 `hibiki/` 写的（`windows/runner/x.cpp`）。
      consider('hibiki/$tail');
    }
  }
  return best;
}

/// Windows / POSIX 都不可能出现在仓库路径里的字符。
final RegExp _illegalPathChar = RegExp(r'[:*?<>|"]');

/// 任意含 `/` 的路径形 token。故意不认 `$`/`{`，插值前缀会在后缀匹配里被丢掉。
final RegExp _slashPathToken =
    RegExp(r'[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+');

/// `join(` / `p.join(` / `path.join(` 调用起点。
final RegExp _joinCall = RegExp(r'\b(?:p|path)?\.?join\s*\(');

/// 单/双引号里的简单字面量（不含转义与插值，够用了：路径段本来就不该有）。
final RegExp _simpleQuoted =
    RegExp("'([^'\\\\\\\$\\n]*)'|\"([^\"\\\\\\\$\\n]*)\"");

/// 从一段 Dart 源码里提取它引用到的仓库路径。
///
/// 两遍扫描取并集：
/// - **含斜杠字面量**：`'../packages/gamepads_windows/windows'`、
///   `'\${root.path}/hibiki/windows/runner'`（插值前缀靠后缀匹配丢掉）。
/// - **join 段链**：`p.join(root.path, 'hibiki', 'windows')` 这种一个斜杠都没有的
///   写法，只靠第一遍会全漏——本仓大多数 native 守卫正是这么写路径的。
Set<RepoPath> extractRepoPathReferences(String source, RepoFs fs) {
  final Set<RepoPath> refs = <RepoPath>{};

  for (final RegExpMatch m in _slashPathToken.allMatches(source)) {
    final RepoPath? p = normalizeRepoPath(m.group(0)!, fs);
    if (p != null) refs.add(p);
  }

  for (final RegExpMatch call in _joinCall.allMatches(source)) {
    final int open = call.end - 1;
    final int close = _matchingParen(source, open);
    if (close < 0) continue;
    final String args = source.substring(open + 1, close);
    final List<String> segments = <String>[];
    for (final RegExpMatch lit in _simpleQuoted.allMatches(args)) {
      final String text = lit.group(1) ?? lit.group(2) ?? '';
      if (text.isEmpty) continue;
      segments.add(text);
    }
    if (segments.isEmpty) continue;
    for (int start = 0; start < segments.length; start++) {
      final RepoPath? p =
          normalizeRepoPath(segments.sublist(start).join('/'), fs);
      if (p != null) {
        refs.add(p);
        break;
      }
    }
  }

  return refs;
}

/// 从 [open]（`(` 的下标）找配对的 `)`；找不到返回 -1。
int _matchingParen(String source, int open) {
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return i;
    } else if (c == '\n' && depth > 0 && i - open > 4000) {
      return -1;
    }
  }
  return -1;
}

/// 显式声明的触发 glob：`// tests-for-changes: **/*.ps1`。
///
/// 少数守卫的扫描面是**运行时算出来**的，源码里根本没有那些路径的字面量，
/// 静态提取必然看不见。典型是 `powershell_51_compat_guard_test.dart`：它从
/// `.github/workflows/*.yml` 里解析 `powershell -File <脚本>`，被守的 `.ps1`
/// 清单是 yml 的内容决定的。
///
/// 这类守卫在自己文件里写一行声明。**规则住在拥有它的那个文件里**，改守卫的人
/// 一眼看得见；而 `tests_for_changes_guard_test.dart` 断言每条声明至少匹配到一个
/// 真实文件，所以声明烂掉是**响的**不是哑的——这正是它比文档里一行名字表强的地方。
/// **必须行首锚定**：不锚定的话，任何在句子中间提到这个标记的散文（包括本工具的
/// 守卫自己的注释与断言文案）都会被当成一条真声明，凭空造出一堆匹配不到文件的
/// 「死规则」。这不是假想——`tests_for_changes_guard_test.dart` 第一版就是被自己
/// 的 reason 文案匹配到而红的。
final RegExp _declaredTrigger = RegExp(
  r'^\s*//\s*tests-for-changes:\s*(\S[^\n]*)',
  multiLine: true,
);

/// 提取一个测试文件里声明的触发 glob。
List<String> extractDeclaredTriggerGlobs(String source) {
  final List<String> globs = <String>[];
  for (final RegExpMatch m in _declaredTrigger.allMatches(source)) {
    for (final String g in m.group(1)!.trim().split(RegExp(r'\s+'))) {
      if (g.isNotEmpty) globs.add(g);
    }
  }
  return globs;
}

/// 最小 glob：`**` 跨目录、`*` 单层、`?` 单字符，其余按字面量转义。
RegExp globToRegExp(String glob) {
  final StringBuffer out = StringBuffer('^');
  for (int i = 0; i < glob.length; i++) {
    final String c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        out.write('.*');
        i++;
      } else {
        out.write('[^/]*');
      }
    } else if (c == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(c));
    }
  }
  out.write(r'$');
  return RegExp(out.toString());
}

/// 一个测试文件的触发面：源码里提取到的路径引用 + 显式声明的 glob。
class TestTriggerFace {
  const TestTriggerFace({
    required this.referencedPaths,
    required this.declaredGlobs,
  });

  /// 从源码里静态提取到的仓库路径引用。
  final Set<RepoPath> referencedPaths;

  /// `// tests-for-changes:` 声明的 glob（扫描面运行时才算得出来的守卫用）。
  final List<String> declaredGlobs;

  bool get isEmpty => referencedPaths.isEmpty && declaredGlobs.isEmpty;
}

/// 枚举 `hibiki/test/` 下全部 `*_test.dart`，返回仓库根相对路径。
List<RepoPath> listAppTestFiles(RepoFs fs) {
  final Directory testDir = Directory('${fs.root.path}/hibiki/test');
  if (!testDir.existsSync()) {
    throw StateError('hibiki/test 不存在，扫描面是空的');
  }
  final List<RepoPath> out = <RepoPath>[];
  for (final FileSystemEntity e
      in testDir.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final String rel = e.path
        .replaceAll('\\', '/')
        .replaceFirst('${fs.root.path.replaceAll('\\', '/')}/', '');
    if (!rel.endsWith('_test.dart')) continue;
    out.add(rel);
  }
  out.sort();
  return out;
}

/// 测试文件 → 它的触发面。
Map<RepoPath, TestTriggerFace> buildReferenceIndex(RepoFs fs) {
  final Map<RepoPath, TestTriggerFace> index = <RepoPath, TestTriggerFace>{};
  for (final RepoPath test in listAppTestFiles(fs)) {
    final String source = File('${fs.root.path}/$test').readAsStringSync();
    index[test] = TestTriggerFace(
      referencedPaths: extractRepoPathReferences(source, fs),
      declaredGlobs: extractDeclaredTriggerGlobs(source),
    );
  }
  return index;
}

/// 这条改动是不是「默认整批 35 条 + 定向测试」已经覆盖的 Dart 源码树。
bool isDefaultBatchCoveredChange(RepoPath changed) {
  for (final String prefix in kDefaultBatchCoveredGlobs) {
    if (changed.startsWith(prefix)) return true;
  }
  final List<String> segments = changed.split('/');
  if (segments.length > 3 && segments.first == 'packages') {
    if (segments[2] == 'lib' || segments[2] == 'test') return true;
  }
  return false;
}

/// [changed] 是否落在引用路径 [ref] 的触发面里。
///
/// - `ref` 是目录 ⇒ 目录下全部文件都算；
/// - `ref` 是文件 ⇒ 该文件本身，外加**同目录**的其它文件（新增文件不能被漏掉），
///   但同目录必须有 ≥2 层深度，免得 `hibiki/pubspec.yaml` 把整个 `hibiki/` 拉进来。
bool changeTriggersReference(RepoPath changed, RepoPath ref, RepoFs fs) {
  if (changed == ref) return true;
  if (fs.isDirectory(ref)) return changed.startsWith('$ref/');
  final int slash = ref.lastIndexOf('/');
  if (slash < 0) return false;
  final RepoPath parent = ref.substring(0, slash);
  if (parent.split('/').length < 2) return false;
  if (kContainerDirs.contains(parent)) return false;
  return changed.startsWith('$parent/');
}

/// 推导结果：该跑的测试 → 是被哪几条引用路径 / 声明 glob 命中的。
Map<RepoPath, Set<String>> selectTestsForChanges({
  required Iterable<RepoPath> changedFiles,
  required Map<RepoPath, TestTriggerFace> index,
  required RepoFs fs,
  bool includeDartTrees = false,
}) {
  final List<RepoPath> effective = changedFiles
      .map((RepoPath c) => c.replaceAll('\\', '/'))
      .where(
          (RepoPath c) => includeDartTrees || !isDefaultBatchCoveredChange(c))
      .toList();
  final Map<RepoPath, Set<String>> hits = <RepoPath, Set<String>>{};
  for (final MapEntry<RepoPath, TestTriggerFace> entry in index.entries) {
    for (final RepoPath changed in effective) {
      for (final RepoPath ref in entry.value.referencedPaths) {
        if (!changeTriggersReference(changed, ref, fs)) continue;
        hits.putIfAbsent(entry.key, () => <String>{}).add(ref);
      }
      for (final String glob in entry.value.declaredGlobs) {
        if (!globToRegExp(glob).hasMatch(changed)) continue;
        hits.putIfAbsent(entry.key, () => <String>{}).add('glob:$glob');
      }
    }
  }
  return hits;
}

/// 把命令行给的改动路径归一成仓库根相对。
///
/// 和 [normalizeRepoPath] 的区别：**不要求存在**。改动可以是删除或新增的文件，
/// 拿存在性当门会把「新加了一个 native 文件」这种最需要推导的场景整个吞掉。
RepoPath normalizeChangedPath(String raw, RepoFs fs) {
  final List<String> segments = raw
      .replaceAll('\\', '/')
      .split('/')
      .where((String s) => s.isNotEmpty && s != '.' && s != '..')
      .toList();
  if (segments.isEmpty) return raw;
  final Set<RepoPath> topLevel = fs.topLevelDirs();
  for (int start = 0; start < segments.length; start++) {
    if (topLevel.contains(segments[start])) {
      return segments.sublist(start).join('/');
    }
  }
  return 'hibiki/${segments.join('/')}';
}

/// 把仓库路径归到「树」（前两段）——统计与哨兵的粒度。
RepoPath treeOf(RepoPath repoPath) {
  final List<String> seg = repoPath.split('/');
  return seg.length >= 2 ? '${seg[0]}/${seg[1]}' : seg.first;
}

/// 把仓库根相对的测试路径转成 `flutter test` 在 `hibiki/` 下能直接吃的相对路径。
RepoPath toFlutterTestArg(RepoPath repoPath) => repoPath.startsWith('hibiki/')
    ? repoPath.substring('hibiki/'.length)
    : repoPath;

Iterable<String> _lines(String input) =>
    input.split(RegExp(r'\r?\n')).map((String s) => s.trim());

/// 从 [base] 求出**分叉点**再 diff。
///
/// 直接 `git diff --name-only origin/develop` 是错的：本机常有 5~10 个 agent 并发，
/// `origin/develop` 一直在动，那条 diff 会把**别人刚落地的东西**也算成「我改了什么」。
/// 实测本 PR 自举时就被污染成 43 个测试，里面全是 `.github/workflows` / `docs/bugs`
/// 这些我根本没碰的树。基准必须是 `git merge-base HEAD <base>`。
List<RepoPath> _changedFromGit(Directory root, String base) {
  final List<RepoPath> out = <RepoPath>[];
  final ProcessResult mergeBase = Process.runSync(
      'git', <String>['merge-base', 'HEAD', base],
      workingDirectory: root.path);
  final String diffBase =
      mergeBase.exitCode == 0 ? (mergeBase.stdout as String).trim() : base;
  final ProcessResult diff = Process.runSync(
      'git', <String>['diff', '--name-only', diffBase],
      workingDirectory: root.path);
  if (diff.exitCode != 0) {
    throw StateError('git diff --name-only $diffBase 失败：${diff.stderr}');
  }
  out.addAll(_lines(diff.stdout as String));
  final ProcessResult untracked = Process.runSync(
      'git', <String>['ls-files', '--others', '--exclude-standard'],
      workingDirectory: root.path);
  if (untracked.exitCode == 0) {
    out.addAll(_lines(untracked.stdout as String));
  }
  return out.where((String s) => s.trim().isNotEmpty).toList();
}

void main(List<String> args) {
  final RepoFs fs = RepoFs(locateRepoRoot(Directory.current));
  final bool explain = args.contains('--explain');
  final bool stats = args.contains('--stats');
  final bool includeDart = args.contains('--include-dart');

  final Map<RepoPath, TestTriggerFace> index = buildReferenceIndex(fs);

  if (stats) {
    final Map<RepoPath, Set<RepoPath>> perTree = <RepoPath, Set<RepoPath>>{};
    for (final MapEntry<RepoPath, TestTriggerFace> e in index.entries) {
      for (final RepoPath ref in e.value.referencedPaths) {
        perTree.putIfAbsent(treeOf(ref), () => <RepoPath>{}).add(e.key);
      }
    }
    final List<MapEntry<RepoPath, Set<RepoPath>>> sorted = perTree.entries
        .toList()
      ..sort((MapEntry<RepoPath, Set<RepoPath>> a,
              MapEntry<RepoPath, Set<RepoPath>> b) =>
          b.value.length.compareTo(a.value.length));
    print('索引：${index.length} 个测试文件，'
        '${index.values.where((TestTriggerFace f) => !f.isEmpty).length} 个有触发面');
    print('（下表是**引用该树的测试文件数**，不是实际触发数——'
        '实际触发要看改的是树里哪个文件）');
    for (final MapEntry<RepoPath, Set<RepoPath>> e in sorted) {
      if (e.value.length < 2) continue;
      print('${e.value.length.toString().padLeft(4)}  ${e.key}');
    }
    return;
  }

  String? base;
  final List<RepoPath> literal = <RepoPath>[];
  for (final String a in args) {
    if (a.startsWith('--base=')) {
      base = a.substring('--base='.length);
    } else if (!a.startsWith('--')) {
      literal.add(a.replaceAll('\\', '/'));
    }
  }

  final List<RepoPath> changed =
      (base != null ? _changedFromGit(fs.root, base) : literal)
          .map((String raw) => normalizeChangedPath(raw, fs))
          .toList();
  if (changed.isEmpty) {
    stderr.writeln('没有改动文件输入；用 --base=<ref> 或直接给路径。');
    return;
  }

  final Map<RepoPath, Set<String>> hits = selectTestsForChanges(
    changedFiles: changed,
    index: index,
    fs: fs,
    includeDartTrees: includeDart,
  );
  final List<RepoPath> selected = hits.keys.toList()..sort();

  if (explain) {
    final int filtered = changed.where(isDefaultBatchCoveredChange).length;
    stderr.writeln('改动 ${changed.length} 个文件，其中 $filtered 个落在默认整批'
        '已覆盖的 Dart 树（不再重复输出，用 --include-dart 关掉）。');
    stderr.writeln('推导出 ${selected.length} 个必须加跑的测试：');
    for (final RepoPath t in selected) {
      stderr
          .writeln('  ${toFlutterTestArg(t)}  ← ${hits[t]!.toList()..sort()}');
    }
  }
  for (final RepoPath t in selected) {
    print(toFlutterTestArg(t));
  }
}

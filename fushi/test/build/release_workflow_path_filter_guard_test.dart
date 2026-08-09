import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：workflow 的路径过滤 / `hashFiles()` 必须指向**真实存在**的路径。
///
/// 起因（W9 改名收尾）：app 目录从 `hibiki/` 改名成 `fushi/` 之后，
/// `release.yml` / `release-desktop.yml` 的 push 触发器里那条 `- 'hibiki/**'`
/// 一度还留着。这类失效**不会报错**——GitHub Actions 对匹配不到任何文件的
/// paths 过滤项没有任何诊断，结果只是「改 app 代码不再触发发版构建」：
/// workflow 静静地不跑，跟「没人推代码」长得一模一样。
/// `hashFiles('hibiki/pubspec.lock')` 更隐蔽：它不报错，只是恒返回同一个
/// 哈希，缓存 key 退化成常量，命中的永远是第一次存下的那份陈旧缓存。
///
/// 两条都是**静默失效**，只能靠「过滤项里写的路径必须真在磁盘上」来钉死。
/// 所以本守卫不去比对 `hibiki` / `fushi` 这种具体名字（下一次改名它照样过期），
/// 而是直接拿路径回磁盘上查——目录改名后忘了同步过滤项，这里必红。
///
/// ## 为什么本守卫**故意不掩掉 `#` 注释**
///
/// 其余 workflow 守卫一律先 `maskHashComments`，本守卫反着来：2026-08-07 起
/// Fushi 改名过渡期把两条发布 workflow 的整个 `push:` 块**注释掉**了（见文件
/// 头「暂停 push 自动发布」）。要守的那份 paths 清单此刻就住在注释里，掩掉注释
/// 等于把守卫的全部对象抹成空白——那正是「静默全绿」。
///
/// 掩码换成「按列还原」：`  #   paths:` 去掉 `# ` 前缀后缩进关系与真 YAML 完全
/// 一致，于是同一套块切分对「启用中」和「注释掉」两种形态都成立。等过渡期结束
/// 把 `#` 去掉时，守卫无需改一行。
void main() {
  /// `flutter test` 的 cwd 是 app 目录本身，取它的名字当「真实 app 目录名」。
  ///
  /// 不写死字符串 `'fushi'`：本文件跟着 app 目录一起被 `git mv`，目录再改名时
  /// 这个值自动跟着变，而 workflow 里的过滤项不会——差异正是要守的东西。
  final String appDir =
      Directory.current.uri.pathSegments.where((String s) => s.isNotEmpty).last;
  final Directory repoRoot = Directory('..');
  final Directory workflowsDir = Directory('../.github/workflows');

  /// 发布链路的两条 workflow：它们的 push 过滤漏掉 app 目录 = 改代码不出包。
  const List<String> releaseWorkflows = <String>[
    'release.yml',
    'release-desktop.yml',
  ];

  test('前置：app 目录名解析正确、workflows 目录存在', () {
    expect(File('../$appDir/pubspec.yaml').existsSync(), isTrue,
        reason: '从 cwd 推出的 app 目录名是 "$appDir"，但 ../$appDir/pubspec.yaml '
            '不存在。本守卫的全部断言都建立在这个名字上，先修它。'
            'cwd=${Directory.current.absolute.path}');
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

  /// 每个 workflow 里所有 `paths:` / `paths-ignore:` 清单项（含被注释掉的块）。
  final List<_FilterEntry> allFilterEntries = <_FilterEntry>[];

  /// workflow 名 -> 它的 push 触发器下的 paths 清单（注释掉的也算）。
  final Map<String, List<_FilterEntry>> pushPaths =
      <String, List<_FilterEntry>>{};

  /// `hashFiles('a', 'b')` 里的每个字面量模式。
  final List<_FilterEntry> hashFilePatterns = <_FilterEntry>[];

  final RegExp hashFilesCall = RegExp(r'hashFiles\(([^)]*)\)');
  final RegExp quoted = RegExp(r"'([^']*)'");
  final RegExp filterHeaderPattern =
      RegExp(r'^(\s*)(paths|paths-ignore):\s*(.*)$');
  final RegExp listItemPattern = RegExp(r"^\s*-\s*'([^']*)'\s*$");
  final RegExp triggerPattern = RegExp(r'^(\s*)([a-z_]+):\s*$');
  final RegExp commentPrefix = RegExp(r'^(\s*)#\s?');

  for (final File workflow in workflows) {
    final String name = workflow.uri.pathSegments.last;
    // 按列还原：注释掉的 YAML 去掉 `# ` 前缀后缩进关系与启用态一致。
    // 缩进用捕获组回填保留，块切分才能沿用同一套缩进比较。
    final List<String> logical = workflow.readAsLinesSync().map((String l) {
      // 不能用 `replaceFirst(re, r'$1')`：String.replaceFirst 的替换串是**字面
      // 量**，不做分组回填，`$1` 会原样写进结果，缩进层级全乱、push 块认不出来。
      // 本守卫的「扫到了 push 清单」反向锚第一次跑就把这个 bug 抓了出来。
      final RegExpMatch? m = commentPrefix.firstMatch(l);
      return m == null ? l : '${m.group(1)!}${l.substring(m.end)}';
    }).toList();

    for (int i = 0; i < logical.length; i++) {
      final RegExpMatch? filterHeader = filterHeaderPattern.firstMatch(
        logical[i],
      );
      if (filterHeader != null) {
        final int indent = filterHeader.group(1)!.length;
        final String inline = filterHeader.group(3)!.trim();
        final List<_FilterEntry> entries = <_FilterEntry>[];
        // 行内形态：`paths: ['fushi/**']`（contributors.yml 就是这么写的）。
        // `&anchor` / `*alias` 是 YAML 锚点，不含字面量路径。
        if (inline.isNotEmpty &&
            !inline.startsWith('&') &&
            !inline.startsWith('*')) {
          for (final RegExpMatch m in quoted.allMatches(inline)) {
            entries.add(_FilterEntry(name, i + 1, m.group(1)!));
          }
        }
        // 块形态：后续缩进更深的 `- '…'` 行。
        for (int j = i + 1; j < logical.length; j++) {
          final String line = logical[j];
          if (line.trim().isEmpty) continue;
          final int lead = line.length - line.trimLeft().length;
          if (lead <= indent) break;
          final RegExpMatch? item = listItemPattern.firstMatch(line);
          if (item != null) {
            entries.add(_FilterEntry(name, j + 1, item.group(1)!));
          }
        }
        allFilterEntries.addAll(entries);
        // 归属：这条 paths 挂在 push: 下面吗？往回找最近一个更浅的触发器名。
        for (int k = i - 1; k >= 0; k--) {
          final RegExpMatch? trigger = triggerPattern.firstMatch(logical[k]);
          if (trigger == null) continue;
          if (trigger.group(1)!.length >= indent) continue;
          if (trigger.group(2) == 'push') {
            pushPaths.putIfAbsent(name, () => <_FilterEntry>[]).addAll(entries);
          }
          break;
        }
        continue;
      }

      for (final RegExpMatch call in hashFilesCall.allMatches(logical[i])) {
        for (final RegExpMatch m in quoted.allMatches(call.group(1)!)) {
          hashFilePatterns.add(_FilterEntry(name, i + 1, m.group(1)!));
        }
      }
    }
  }

  test('守卫没跑空：扫到了路径过滤项与 hashFiles 模式', () {
    expect(workflows, isNotEmpty, reason: '一个 workflow 文件都没扫到');
    expect(allFilterEntries, isNotEmpty,
        reason: '一条 paths 过滤项都没扫到，说明块切分坏了或 workflow 改版了；'
            '此时其余断言全部无意义。');
    expect(hashFilePatterns, isNotEmpty,
        reason: '一个 hashFiles() 模式都没扫到——缓存 key 的静默退化正是本守卫'
            '要防的第二类失效，扫不到就等于没守。');
  });

  group('发布 workflow 的 push 路径过滤', () {
    for (final String name in releaseWorkflows) {
      test('$name 的 push 过滤覆盖真实 app 目录 $appDir/**', () {
        final List<_FilterEntry> entries = pushPaths[name] ?? <_FilterEntry>[];
        // 反向锚：清单本身还在，下面那条覆盖断言才有对象可查。
        expect(entries, isNotEmpty,
            reason: '$name 里找不到 push 触发器下的 paths 清单（启用态和注释态都没找到）。'
                'push 触发器被整块删掉了？还是注释格式变了让按列还原失效？'
                '无论哪种，本守卫已失去锚点，先修守卫再谈绿。');

        final Set<String> globs =
            entries.map((_FilterEntry e) => e.value).toSet();
        expect(globs, contains('$appDir/**'),
            reason: 'push 过滤没覆盖 app 目录 `$appDir/**`：改 app 代码将不再触发 '
                '$name 的发版构建，而 GitHub 对匹配不到文件的 paths 过滤**零诊断**——'
                '症状与「没人推代码」完全一致。当前清单：\n'
                '${entries.map((_FilterEntry e) => "  ${e.where} ${e.value}").join("\n")}');
      });
    }
  });

  test('所有路径过滤项都指向磁盘上真实存在的路径', () {
    final List<String> offenders = <String>[];
    for (final _FilterEntry entry in allFilterEntries) {
      final String? prefix = _literalPrefix(entry.value);
      if (prefix == null || prefix.isEmpty) continue;
      final String full = '${repoRoot.path}/$prefix';
      if (File(full).existsSync() || Directory(full).existsSync()) continue;
      offenders.add('${entry.where} "${entry.value}" -> 不存在的 $prefix');
    }
    expect(offenders, isEmpty,
        reason: '这些 paths / paths-ignore 过滤项指向的路径在仓库里不存在。目录改名'
            '（如 W9 的 hibiki/ -> fushi/）后忘了同步过滤项就长这样：workflow 不再被'
            '触发，而 GitHub 不会给任何提示。逐条改成真实路径：\n'
            '${offenders.join("\n")}');
  });

  test('所有 hashFiles() 模式都能匹配到真实文件', () {
    final List<String> offenders = <String>[];
    for (final _FilterEntry entry in hashFilePatterns) {
      final String? prefix = _literalPrefix(entry.value);
      final String full = '${repoRoot.path}/${prefix ?? ''}';
      final bool exists = prefix != null &&
          prefix.isNotEmpty &&
          (File(full).existsSync() || Directory(full).existsSync());
      if (!exists) {
        offenders.add("${entry.where} hashFiles('${entry.value}') -> "
            '匹配不到任何文件');
      }
    }
    expect(offenders, isEmpty,
        reason: 'hashFiles() 对匹配不到文件的模式**不报错**：它照常返回一个哈希，'
            '只是这个哈希恒定不变，于是缓存 key 退化成常量、永远命中第一次存下的'
            '那份陈旧缓存，而日志上一切正常。这是最难发现的一类改名残留：\n'
            '${offenders.join("\n")}');
  });
}

/// 取 glob 里**不含通配符**的最长前缀路径段（可回磁盘校验的那部分）。
///
/// `fushi/**` -> `fushi`；`fushi/android/**/*.gradle*` -> `fushi/android`；
/// `pubspec.yaml` -> `pubspec.yaml`（整条就是字面量）；`**` -> null（无可查前缀）。
String? _literalPrefix(String glob) {
  if (glob.startsWith('!')) return null; // 排除项，不是要求存在的路径。
  final List<String> kept = <String>[];
  for (final String segment in glob.split('/')) {
    if (segment.contains('*') ||
        segment.contains('?') ||
        segment.contains('[')) {
      break;
    }
    kept.add(segment);
  }
  return kept.isEmpty ? null : kept.join('/');
}

/// 一条路径过滤项 / hashFiles 模式及其出处。
class _FilterEntry {
  const _FilterEntry(this.workflow, this.line, this.value);

  final String workflow;

  /// 1 基行号。
  final int line;
  final String value;

  String get where => '$workflow:$line';
}

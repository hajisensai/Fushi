import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/scan_scale.dart';

/// 守卫：agent 规则文档（根 `CLAUDE.md` / `AGENTS.md` + `docs/agent/` 全目录）里的
/// Markdown 相对链接必须指向真实存在的文件。
///
/// 洞的形状（PR#2803 审查）：把根 `CLAUDE.md` 的段落整段迁进 `docs/agent/repo-map.md`
/// 时，原样带走了 `](docs/agent/subsystem-map.md)` 这类以仓库根为基准的写法。Markdown
/// 相对链接按**所在文件的目录**解析，于是它们在 GitHub 上指向不存在的
/// `docs/agent/docs/agent/*.md`，agent 照链接去读也会扑空；`rules-detail.md` 里早有
/// 同类死链。文档没有编译器，死链只能靠这里钉。
///
/// 判据：去掉围栏代码块与行内代码后，逐个 `](target)`；带 scheme（`https:` 等）或
/// 纯锚点（`#...`）的跳过；其余去掉 `#锚点` 后按所在文件目录解析，必须存在。
/// 指进 git submodule（`.gitmodules` 登记的路径，如 `references/ShokoServer`）的
/// 链接只要求 submodule 已登记——worktree 里 submodule 常未检出。
void main() {
  // 测试 cwd 是 `fushi/`。
  final String repoRoot = p.normalize(p.absolute('..'));

  final List<String> submodulePaths = _readSubmodulePaths(
    File(p.join(repoRoot, '.gitmodules')),
  ).map((String sub) => p.normalize(p.join(repoRoot, sub))).toList();

  List<File> agentDocs() {
    final List<File> files = <File>[
      File(p.join(repoRoot, 'CLAUDE.md')),
      File(p.join(repoRoot, 'AGENTS.md')),
    ];
    final Directory agentDir = Directory(p.join(repoRoot, 'docs', 'agent'));
    files.addAll(
      agentDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.md')),
    );
    return files.where((File f) => f.existsSync()).toList();
  }

  test('判据自校验：仓库根基准的链接写进 docs/agent 会被抓到', () {
    const String sample =
        '见 [细则](docs/agent/rules-detail.md#x)，'
        '`](docs/agent/inline-code.md)` 不算，'
        '[ok](build.md) 与 [web](https://example.com) 与 [a](#anchor)。\n'
        '```\n[fenced](docs/agent/fenced.md)\n```\n';
    expect(extractRelativeLinkTargets(sample), <String>[
      'docs/agent/rules-detail.md',
      'build.md',
    ]);
  });

  test('agent 规则文档的相对链接全部可解析', () {
    final List<File> files = agentDocs();
    expectScanScale(
      files.length,
      what: 'agent 规则文档（CLAUDE.md / AGENTS.md / docs/agent/*.md）',
      atLeast: 20,
      measured: 27,
    );

    int checked = 0;
    final List<String> broken = <String>[];
    for (final File file in files) {
      final String text = file.readAsStringSync().replaceAll('\r\n', '\n');
      final String dir = file.parent.path;
      for (final String target in extractRelativeLinkTargets(text)) {
        checked++;
        final String resolved = p.normalize(
          p.join(dir, Uri.decodeFull(target)),
        );
        final bool exists =
            File(resolved).existsSync() || Directory(resolved).existsSync();
        final bool inSubmodule = submodulePaths.any(
          (String sub) => p.equals(resolved, sub) || p.isWithin(sub, resolved),
        );
        if (!exists && !inSubmodule) {
          broken.add('${p.relative(file.path, from: repoRoot)} → $target');
        }
      }
    }

    expectScanScale(
      checked,
      what: 'agent 规则文档里的相对链接',
      atLeast: 100,
      measured: 126,
    );
    expect(
      broken,
      isEmpty,
      reason:
          '以下相对链接解析不到文件。Markdown 相对链接按所在文件的目录解析：'
          'docs/agent/ 下的文件链同目录文档要写 `](build.md)`，链仓库根要写 '
          '`](../../CLAUDE.md)`，不要照抄根 CLAUDE.md 的 `](docs/agent/...)`。\n'
          '${broken.join('\n')}',
    );
  });
}

final RegExp _fencedBlock = RegExp(
  r'^```.*?^```',
  multiLine: true,
  dotAll: true,
);
final RegExp _inlineCode = RegExp(r'`[^`\n]*`');
final RegExp _linkTarget = RegExp(r'\]\(([^)\s]+)\)');
final RegExp _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

/// 提取 Markdown 文本里需要按文件系统解析的相对链接目标（已去掉 `#锚点`）。
List<String> extractRelativeLinkTargets(String markdown) {
  final String prose = markdown
      .replaceAll(_fencedBlock, '')
      .replaceAll(_inlineCode, '');
  final List<String> targets = <String>[];
  for (final RegExpMatch m in _linkTarget.allMatches(prose)) {
    final String target = m.group(1)!;
    if (_scheme.hasMatch(target) || target.startsWith('#')) continue;
    final String path = target.split('#').first;
    if (path.isEmpty) continue;
    targets.add(path);
  }
  return targets;
}

List<String> _readSubmodulePaths(File gitmodules) {
  if (!gitmodules.existsSync()) return const <String>[];
  final RegExp pathLine = RegExp(r'^\s*path\s*=\s*(.+?)\s*$', multiLine: true);
  return pathLine
      .allMatches(gitmodules.readAsStringSync())
      .map((RegExpMatch m) => m.group(1)!)
      .toList();
}

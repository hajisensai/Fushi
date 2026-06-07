// 守卫：bug 跟踪「一 bug 一文件 + 生成式索引」不变式。
//
// 背景见 docs/BUGS.md 头部与 tool/bug.dart。旧的单文件 + 全局序号对并发 agent 有敌意
// （撞号 + 顶部插入 git 冲突），改成 per-file 后这两类冲突从工作流里消失。本测试守住
// 该数据结构不变式，防有人把正文又塞回 docs/BUGS.md（退回老结构）。
//
// 纯 dart:io，不依赖 Flutter 运行时；从 hibiki/ 向上找仓库根。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找含 docs/BUGS.md 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/docs/BUGS.md').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 docs/BUGS.md 的仓库根（从 ${Directory.current.path} 向上）');
}

final RegExp _headingRe = RegExp(r'^##\s+BUG-(\d+)\s*·', multiLine: true);

void main() {
  final root = _repoRoot();
  final indexFile = File('${root.path}/docs/BUGS.md');
  final bugsDir = Directory('${root.path}/docs/bugs');

  group('bug 跟踪 per-file 不变式', () {
    test('docs/BUGS.md 不再含任何 `## BUG-NNN` 正文标题（只放索引表）', () {
      final content = indexFile.readAsStringSync();
      final stray = _headingRe.allMatches(content).map((m) => 'BUG-${m.group(1)}').toList();
      expect(
        stray,
        isEmpty,
        reason: 'docs/BUGS.md 仍含正文标题 $stray —— 正文必须在 docs/bugs/，'
            '本文件只保留头部约定 + marker 间的自动索引（退回单文件=并发冲突复发）',
      );
    });

    test('docs/bugs/ 每个文件可解析 BUG-NNN 且号唯一', () {
      expect(bugsDir.existsSync(), isTrue, reason: '缺 docs/bugs/ 目录');
      final files = bugsDir
          .listSync()
          .whereType<File>()
          .where((f) {
            final n = f.uri.pathSegments.last;
            return n.endsWith('.md') && !n.startsWith('_');
          })
          .toList();
      expect(files.length, greaterThanOrEqualTo(100),
          reason: '已迁移过 117 条，文件数异常少说明迁移丢失');
      final byNum = <int, String>{};
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final m = _headingRe.firstMatch(f.readAsStringSync());
        expect(m, isNotNull, reason: '$name 首个 `## BUG-NNN · 标题` 标题缺失/格式错');
        final num = int.parse(m!.group(1)!);
        final prev = byNum[num];
        expect(prev, isNull,
            reason: '号撞了：BUG-$num 同时在 $prev 与 $name —— 改名其一（dart run tool/bug.dart check 可查）');
        byNum[num] = name;
      }
    });

    test('索引表每个链接都指向真实存在的 bug 文件', () {
      final content = indexFile.readAsStringSync();
      final linkRe = RegExp(r'\]\(bugs/([^)]+\.md)\)');
      final links = linkRe.allMatches(content).map((m) => m.group(1)!).toList();
      expect(links, isNotEmpty, reason: '索引表里没有任何 bug 链接，reindex 可能没跑');
      for (final rel in links) {
        expect(File('${bugsDir.path}/$rel').existsSync(), isTrue,
            reason: '索引指向不存在的文件 docs/bugs/$rel（跑 dart run tool/bug.dart reindex）');
      }
    });
  });
}

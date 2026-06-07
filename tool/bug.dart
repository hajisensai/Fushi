// Bug 跟踪工具：一 bug 一文件 + 生成式索引。
//
// 背景：旧的单文件 `docs/BUGS.md` + 全局递增 BUG-NNN，对并发 agent 有敌意——
// 几个 worktree 同时取「下一个号」必撞号，且都往同一文件顶部插入必产生 git 冲突。
// 改成每条 bug 独立文件 `docs/bugs/BUG-NNN[-slug].md`，`docs/BUGS.md` 退化成
// 「头部约定 + 自动生成的索引表」。并发新建落成两个不同文件名（无冲突），
// 撞号的代价从「解冲突」降到「重命名一个文件」。
//
// 用法：
//   dart run tool/bug.dart new <slug> [标题...]   # 新建一条 bug（自动取下一个空号 + 重建索引）
//   dart run tool/bug.dart reindex                # 扫 docs/bugs/*.md 重建 docs/BUGS.md 索引
//   dart run tool/bug.dart migrate                # 一次性：把旧单文件 BUGS.md 拆成 per-file
//   dart run tool/bug.dart check                  # 守卫：校验 per-file 不变式 + 索引是否同步
//
// 零外部依赖（只用 dart:io）。运行目录 = 仓库根（docs/ 在其下）。

import 'dart:io';

const String bugsDir = 'docs/bugs'; // 仓库根相对路径，文件读写用
const String linkDir = 'bugs'; // docs/BUGS.md 相对链接用（BUGS.md 在 docs/ 下）
const String indexFile = 'docs/BUGS.md';
const String beginMarker =
    '<!-- BUGS-INDEX:BEGIN（自动生成，勿手改；改完跑 `dart run tool/bug.dart reindex`）-->';
const String endMarker = '<!-- BUGS-INDEX:END -->';

/// docs/BUGS.md 头部约定（迁移时重写；reindex 只改 marker 之间，不动这段）。
const String headerTemplate = '''# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
>
> **数据结构：一 bug 一文件。** 每条 bug 是 `docs/bugs/BUG-NNN[-slug].md` 一个独立文件；
> 本文件（`docs/BUGS.md`）只是「头部约定 + 自动生成的索引表」，索引区**勿手改**。
> 这样并发 agent 各写各的文件，永不在同一处产生 git 冲突；撞号也只是两个不同文件名，
> 改个名即可，不再有冲突标记手术。
>
> 新建一条：`dart run tool/bug.dart new <slug> [标题...]`（自动取下一个空号、生成骨架、重建索引）。
> 改完某条 bug 文件后：`dart run tool/bug.dart reindex` 重建下面的索引表。
>
> 每条 bug 文件里：
> - **是真 bug** → 记报告日期、根因 `file:line`，然后：
>   - **① 修复**（根因修，不补丁），完成后把 `[ ] ①` 改成 `[x] ①`，记提交哈希。
>   - **② 增加自动化测试**（最强可落地层：真 widget 行为 / CSS 生成器 / 源码扫描守卫；
>     纯视觉像素只能设备截图兜底并注明），完成后把 `[ ] ②` 改成 `[x] ②`，记测试文件。
> - **不是真 bug / 无法复现** → 也建一条，标「未复现」并说明，不勾 ① ②。
> - reader/WebView/导入/播放/布局类修复：代码正确 + 单测无回归后，仍需**设备肉眼复测原始失败路径**
>   （CLAUDE.md 验证纪律）；未做的在「备注」标注待补。
>
> 分层测试选型见 [docs/specs/2026-06-03-test-flow-refactor-*.md] 与各守卫测试范式
> （源码扫描：`test/pages/reader_paginate_lyrics_guard_static_test.dart` 的 `_functionSource`；
> CSS 生成器：`test/reader/reader_content_styles_test.dart`；widget 行为：`test/settings/`）。
''';

/// bug 新建骨架模板（`new` 子命令用）。
String bugSkeleton(String paddedNum, String title, String dateIso) => '''## BUG-$paddedNum · $title
- **报告**：$dateIso（用户：）
- **真实性**：（沿真实代码路径验真伪后填：✅ 真 bug / ❌ 未复现，附根因 `file:line`）
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：
''';

/// 一条 bug 的解析结果。
class BugEntry {
  final int number;
  final String paddedNum; // 3 位补零，如 "007"
  final String title;
  final String fixIcon; // ✅ / 🚧 / —
  final String testIcon;
  final String fileName; // 相对 bugsDir，如 "BUG-007.md"

  BugEntry({
    required this.number,
    required this.paddedNum,
    required this.title,
    required this.fixIcon,
    required this.testIcon,
    required this.fileName,
  });
}

final RegExp _headingRe = RegExp(r'^##\s+BUG-(\d+)\s*·\s*(.*)$');

/// 从一段 bug 正文里解析出号 + 标题（取第一行 `## BUG-NNN · 标题`）。
/// 返回 (number, paddedNum, title)；解析失败返回 null。
(int, String, String)? parseHeading(String body) {
  for (final line in body.split('\n')) {
    final m = _headingRe.firstMatch(line.trimRight());
    if (m != null) {
      final raw = m.group(1)!;
      final n = int.parse(raw);
      return (n, n.toString().padLeft(3, '0'), m.group(2)!.trim());
    }
  }
  return null;
}

/// 根据正文里的 `[x]/[ ] ①` `[x]/[ ] ②` 勾选状态决定索引图标。
/// 既无 ① 也无 ② → 视为「未复现/仅记录」，两列都用 —。
(String, String) statusIcons(String body) {
  final hasFixMark = body.contains('① ') || body.contains('①未');
  final hasTestMark = body.contains('② ') || body.contains('②未');
  String icon(bool hasMark, bool done) {
    if (!hasMark) return '—';
    return done ? '✅' : '🚧';
  }

  final fixDone = body.contains('[x] ①');
  final testDone = body.contains('[x] ②');
  return (icon(hasFixMark, fixDone), icon(hasTestMark, testDone));
}

/// 把旧单文件 BUGS.md 切成 (header, blocks)：
/// header = 第一个 `## BUG-` 之前的内容；blocks = 每个 `## BUG-` 起的段落（已去尾部 `---`/空行）。
(String, List<String>) splitMonolith(String content) {
  final lines = content.split('\n');
  int firstBug = lines.indexWhere((l) => _headingRe.hasMatch(l.trimRight()));
  if (firstBug < 0) {
    return (content, <String>[]);
  }
  final header = lines.sublist(0, firstBug).join('\n');
  final blocks = <String>[];
  final buf = <String>[];
  void flush() {
    if (buf.isEmpty) return;
    // 去掉块尾的分隔线 `---` 和空行。
    var end = buf.length;
    while (end > 0 && (buf[end - 1].trim().isEmpty || buf[end - 1].trim() == '---')) {
      end--;
    }
    final block = buf.sublist(0, end).join('\n').trimRight();
    if (block.isNotEmpty) blocks.add('$block\n');
    buf.clear();
  }

  for (final line in lines.sublist(firstBug)) {
    if (_headingRe.hasMatch(line.trimRight())) {
      flush();
    }
    buf.add(line);
  }
  flush();
  return (header, blocks);
}

/// 扫 docs/bugs/*.md，解析成排好序（号降序）的条目列表。
List<BugEntry> scanBugs() {
  final dir = Directory(bugsDir);
  if (!dir.existsSync()) return <BugEntry>[];
  final entries = <BugEntry>[];
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.md') || name.startsWith('_')) continue;
    final body = f.readAsStringSync();
    final parsed = parseHeading(body);
    if (parsed == null) {
      stderr.writeln('警告：$name 无法解析 BUG-NNN 标题，已跳过');
      continue;
    }
    final (n, pad, title) = parsed;
    final (fix, test) = statusIcons(body);
    entries.add(BugEntry(
      number: n,
      paddedNum: pad,
      title: title,
      fixIcon: fix,
      testIcon: test,
      fileName: name,
    ));
  }
  entries.sort((a, b) => b.number.compareTo(a.number));
  return entries;
}

/// 生成索引表 markdown（不含 marker）。
String buildIndexTable(List<BugEntry> entries) {
  final sb = StringBuffer();
  sb.writeln('> 共 ${entries.length} 条。点号进各自文件。');
  sb.writeln();
  sb.writeln('| BUG | 修复 | 测试 | 标题 |');
  sb.writeln('|---|:--:|:--:|---|');
  for (final e in entries) {
    final title = e.title.replaceAll('|', r'\|');
    sb.writeln('| [BUG-${e.paddedNum}]($linkDir/${e.fileName}) | ${e.fixIcon} | ${e.testIcon} | $title |');
  }
  return sb.toString().trimRight();
}

/// 把重建好的索引表写回 docs/BUGS.md 的 marker 之间。
void writeIndex(List<BugEntry> entries) {
  final file = File(indexFile);
  final content = file.readAsStringSync();
  final beginIdx = content.indexOf('BUGS-INDEX:BEGIN');
  final endIdx = content.indexOf('BUGS-INDEX:END');
  if (beginIdx < 0 || endIdx < 0) {
    stderr.writeln('错误：$indexFile 缺少索引 marker，先跑 migrate');
    exit(1);
  }
  // 定位 begin marker 行的结尾与 end marker 行的开头。
  final beginLineEnd = content.indexOf('\n', beginIdx);
  final endLineStart = content.lastIndexOf('\n', endIdx) + 1;
  final before = content.substring(0, beginLineEnd + 1);
  final after = content.substring(endLineStart);
  final table = buildIndexTable(entries);
  file.writeAsStringSync('$before\n$table\n\n$after');
}

void cmdReindex() {
  final entries = scanBugs();
  writeIndex(entries);
  stdout.writeln('reindex 完成：${entries.length} 条 → $indexFile');
}

void cmdMigrate() {
  final file = File(indexFile);
  if (!file.existsSync()) {
    stderr.writeln('错误：找不到 $indexFile');
    exit(1);
  }
  final (_, blocks) = splitMonolith(file.readAsStringSync());
  if (blocks.isEmpty) {
    stderr.writeln('错误：$indexFile 里没有 `## BUG-NNN` 段落，无需迁移');
    exit(1);
  }
  Directory(bugsDir).createSync(recursive: true);
  final seen = <String>{};
  for (final block in blocks) {
    final parsed = parseHeading(block);
    if (parsed == null) {
      stderr.writeln('警告：某段落无法解析 BUG-NNN，已跳过');
      continue;
    }
    final (_, pad, _) = parsed;
    if (!seen.add(pad)) {
      stderr.writeln('警告：BUG-$pad 出现多次，后者覆盖前者');
    }
    File('$bugsDir/BUG-$pad.md').writeAsStringSync(block);
  }
  // 重写 docs/BUGS.md = 新头部 + 空索引 marker，再 reindex 填充。
  file.writeAsStringSync('$headerTemplate\n---\n\n$beginMarker\n$endMarker\n');
  cmdReindex();
  stdout.writeln('migrate 完成：${seen.length} 条已拆成 $bugsDir/BUG-*.md');
}

void cmdNew(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/bug.dart new <slug> [标题...]');
    stderr.writeln('  slug 是 ascii kebab（如 reader-internal-link），让并发新建落成不同文件名');
    exit(1);
  }
  final slug = _sanitizeSlug(args.first);
  if (slug.isEmpty) {
    stderr.writeln('错误：slug 清洗后为空，请用 ascii 字母/数字/连字符');
    exit(1);
  }
  final title = args.length > 1 ? args.sublist(1).join(' ') : slug;
  final entries = scanBugs();
  final maxNum = entries.isEmpty ? 0 : entries.first.number;
  final next = maxNum + 1;
  final pad = next.toString().padLeft(3, '0');
  Directory(bugsDir).createSync(recursive: true);
  final path = '$bugsDir/BUG-$pad-$slug.md';
  if (File(path).existsSync()) {
    stderr.writeln('错误：$path 已存在');
    exit(1);
  }
  final now = DateTime.now();
  final dateIso =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  File(path).writeAsStringSync(bugSkeleton(pad, title, dateIso));
  cmdReindex();
  stdout.writeln('已建 $path');
  stdout.writeln('填完根因/修复/测试后再跑 `dart run tool/bug.dart reindex`');
}

String _sanitizeSlug(String s) {
  final lower = s.toLowerCase();
  final buf = StringBuffer();
  for (final ch in lower.codeUnits) {
    final isAlnum = (ch >= 0x30 && ch <= 0x39) || (ch >= 0x61 && ch <= 0x7a);
    if (isAlnum) {
      buf.writeCharCode(ch);
    } else if (ch == 0x20 || ch == 0x2d || ch == 0x5f) {
      buf.write('-');
    }
  }
  return buf.toString().replaceAll(RegExp(r'-+'), '-').replaceAll(RegExp(r'^-|-$'), '');
}

/// 守卫：校验 per-file 不变式 + 索引是否与文件同步。返回非 0 表示有问题。
int cmdCheck() {
  var ok = true;
  // 1) docs/BUGS.md 不应再含任何 `## BUG-` 标题（全部已 per-file）。
  final indexContent = File(indexFile).readAsStringSync();
  if (RegExp(r'^##\s+BUG-\d+', multiLine: true).hasMatch(indexContent)) {
    stderr.writeln('✗ $indexFile 仍含 `## BUG-NNN` 标题——应只放索引表，正文须在 $bugsDir/');
    ok = false;
  }
  // 2) 每个文件可解析，号唯一。
  final entries = scanBugs();
  final byNum = <int, String>{};
  for (final e in entries) {
    final prev = byNum[e.number];
    if (prev != null) {
      stderr.writeln('✗ 号撞了：BUG-${e.paddedNum} 出现在 $prev 与 ${e.fileName}（改名其一）');
      ok = false;
    }
    byNum[e.number] = e.fileName;
  }
  // 3) 索引是否同步（reindex 应为 no-op）。
  final beginIdx = indexContent.indexOf('BUGS-INDEX:BEGIN');
  final endIdx = indexContent.indexOf('BUGS-INDEX:END');
  if (beginIdx < 0 || endIdx < 0) {
    stderr.writeln('✗ $indexFile 缺少索引 marker');
    ok = false;
  } else {
    final beginLineEnd = indexContent.indexOf('\n', beginIdx);
    final endLineStart = indexContent.lastIndexOf('\n', endIdx) + 1;
    final current = indexContent.substring(beginLineEnd + 1, endLineStart).trim();
    final expected = buildIndexTable(entries).trim();
    if (current != expected) {
      stderr.writeln('✗ 索引与 $bugsDir/ 不同步——跑 `dart run tool/bug.dart reindex`');
      ok = false;
    }
  }
  if (ok) {
    stdout.writeln('check 通过：${entries.length} 条，号唯一，索引同步');
    return 0;
  }
  return 1;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/bug.dart <new|reindex|migrate|check> ...');
    exit(2);
  }
  switch (args.first) {
    case 'new':
      cmdNew(args.sublist(1));
    case 'reindex':
      cmdReindex();
    case 'migrate':
      cmdMigrate();
    case 'check':
      exit(cmdCheck());
    default:
      stderr.writeln('未知子命令：${args.first}');
      exit(2);
  }
}

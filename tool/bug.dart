// Bug 跟踪工具：一 bug 一文件 + 生成式索引。
//
// 背景：旧的单文件 `docs/BUGS.md` + 全局递增 BUG-NNN，对并发 agent 有敌意——
// 几个 worktree 同时取「下一个号」必撞号，且都往同一文件顶部插入必产生 git 冲突。
// 改成每条 bug 独立文件 `docs/bugs/BUG-NNN[-slug].md`，`docs/BUGS.md` 退化成
// 「头部约定 + 自动生成的索引表」。并发新建落成两个不同文件名（无冲突），
// 撞号的代价从「解冲突」降到「重命名一个文件」。
//
// 撞号本身还是要治：`new` 取号时把可见范围从「本地工作区」扩到
// **所有本地分支 + 远端分支 + 本机每个 git 工作区磁盘上的 `docs/bugs/`**。
//
// ⚠️ 2026-08-02 一天连撞六次的根因，就在最后那一项曾经缺失：
//   `bug.dart new` **先写磁盘文件**，而这个文件要等「定位根因 → 改代码 → 跑测试」
//   之后才 commit——中间几十分钟到几小时。老实现只读 commit 树（`<ref>:docs/bugs`），
//   于是这整段窗口对并发 agent 完全不可见，而并发 agent 恰恰就在这段窗口里取号。
//   这不是不可约的 TOCTOU：那些 worktree 就在同一台机器的同一个文件系统上，
//   `git worktree list` 能枚举，读一下目录窗口就从「小时级」压到「同一次扫描内的毫秒级」。
//
// 号的判据：bug 文件的**文件名** `BUG-NNN*.md`（所有来源都认）+ **正文首个 H2**
// `## BUG-NNN · 标题`（已提交的 ref 上认，两者不一致时两个号都算已占；别人未提交的
// 工作区上不认——实测逐文件读 796k 个文件要 320s）。代码/文档里的 `BUG-NNN`
// **引用不算认领**——引用是指针，把它算成占用会让每条 bug 白烧一批号，而且引用天然
// 指向已存在的号，本来就在池子里。
//
// ⚠️ 已知残留风险（不要宣称已彻底解决）：
//   1. TOCTOU 窗口压到了毫秒级，但没消失——两个 agent 在同一次扫描期间各自落盘仍会撞。
//      开 PR 前和每次 rebase 后重跑 `check` 是最后一道闸。
//   2. 远端扫描依赖网络；网络不通时会**显式警告**并降级到「本地分支 + 已缓存的
//      remote-tracking 引用 + 本机工作区」。降级后仍看得见本机所有并发 agent，
//      只有「别人 push 到远端、本机没有对应工作区」的号会漏。
//   3. 别的机器上没 push 的号看不见（跨机并发不在本工具射程内）。
//
// 用法：
//   dart run tool/bug.dart new <slug> [标题...]        # 新建一条 bug（跨分支取下一个空号 + 重建索引）
//   dart run tool/bug.dart renumber <old> <new> [--base <ref>] [--dry-run]
//                                                     # 改号：文件名 + 正文 H2 + 代码/测试引用一把改，
//                                                     #      改完自动 reindex 并自校验零残留
//   dart run tool/bug.dart reindex                     # 扫 docs/bugs/*.md 重建 docs/BUGS.md 索引
//   dart run tool/bug.dart migrate                     # 一次性：把旧单文件 BUGS.md 拆成 per-file
//   dart run tool/bug.dart check [--strict] [--no-scan]
//                                                     # 守卫：per-file 不变式 + 索引同步
//                                                     #   + 跨分支/工作区占用复核
//
// `check` 现在**会扫**分支与工作区（这正是「开 PR 前重扫」要的东西），并逐条报出
// 「我的号 N 同时被哪些别的文件名占着、在哪个 ref / 工作区」。
// 退出码纪律：默认只有**本地不变式**决定红绿（否则一堆陈旧分支上的历史同号文件会让
// develop 永久变红）；`--strict` 才把跨源撞号也判成非 0。`--no-scan` 退回纯本地校验。
//
// renumber 的两种模式——由「old 号在本地是否唯一」决定，**不是开关**：
//   · **号唯一**（只有一个 bug 文件占 old）：全仓替换。此时仓库里每一处 `BUG-<old>` 按定义
//     都指向这唯一一条，全仓改才是对的；缩范围反而会漏引用。
//   · **撞号态**（≥2 个 bug 文件占 old——正是 integration rebase 后唯一需要改号的场景）：
//     替换范围**钉死**在「本次改动引入的文件集」（`git diff --name-only <merge-base>..工作区`
//     + untracked），并在改号前后对**范围外每个文件**的 `BUG-<old>` 出现数做断言，
//     一处变动即整体失败。
//     不这么做的后果：撞号意味着 base 上**本来就有一条合法的同号 bug**，全仓盲替换会把它
//     和所有指向它的引用一起改掉，制造「base 侧 bug 凭空消失 / 引用指向不存在的号」的
//     二次破坏——而事后 `check` 仍然报通过（号仍唯一、索引仍同步），**不会报警**。
//
// 环境变量（都可不设）：
//   HIBIKI_BUG_REMOTE=origin              远端名
//   HIBIKI_BUG_SKIP_REMOTE_FETCH=1        跳过 git fetch（离线/急用；仍扫已缓存 remote-tracking 并警告）
//   HIBIKI_BUG_REMOTE_TIMEOUT=25          fetch 超时秒数
//   HIBIKI_BUG_BASE=origin/develop        撞号态下算作用域用的基线 ref（等价于 `--base`）
//
// 零外部依赖（只用 dart:*）。运行目录 = 仓库根（docs/ 在其下）。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String bugsDir = 'docs/bugs'; // 仓库根相对路径，文件读写用
const String linkDir = 'bugs'; // docs/BUGS.md 相对链接用（BUGS.md 在 docs/ 下）
const String indexFile = 'docs/BUGS.md';
const String beginMarker =
    '<!-- BUGS-INDEX:BEGIN（自动生成，勿手改；改完跑 `dart run tool/bug.dart reindex`）-->';
const String endMarker = '<!-- BUGS-INDEX:END -->';

/// 本地不入库、但同样会引用 BUG 号的文件（`git ls-files` 看不到，改号时单独带上）。
const List<String> extraScanPaths = <String>['docs/REGRESSION_BUGS.md'];

/// 可注入的输出/警告 sink（测试替换用；默认写 stdout / stderr）。
void Function(String) logOut = stdout.writeln;
void Function(String) logWarn = stderr.writeln;

/// 工具级错误：`main` 捕获后写 stderr + 非 0 退出；测试可直接断言消息。
class BugToolError implements Exception {
  BugToolError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// docs/BUGS.md 头部约定（迁移时重写；reindex 只改 marker 之间，不动这段）。
const String headerTemplate = '''# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
>
> **数据结构：一 bug 一文件。** 每条 bug 是 `docs/bugs/BUG-NNN[-slug].md` 一个独立文件；
> 本文件（`docs/BUGS.md`）只是「头部约定 + 自动生成的索引表」，索引区**勿手改**。
> 这样并发 agent 各写各的文件，永不在同一处产生 git 冲突；撞号也只是两个不同文件名，
> 改个名即可，不再有冲突标记手术。
>
> 新建一条：`dart run tool/bug.dart new <slug> [标题...]`（跨本地+远端分支取下一个空号、生成骨架、重建索引）。
> 撞号了：`dart run tool/bug.dart renumber <old> <new>`（文件名 + 正文 H2 + 代码/测试引用一把改 + 自校验；
> 别手改——只改文件名不改正文 H2 会让 `bugs_per_file_guard_test` 变红）。
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

/// 3 位补零（>999 时按实际位数）。
String padNum(int n) => n.toString().padLeft(3, '0');

/// 从一段 bug 正文里解析出号 + 标题（取第一行 `## BUG-NNN · 标题`）。
/// 返回 (number, paddedNum, title)；解析失败返回 null。
(int, String, String)? parseHeading(String body) {
  for (final line in body.split('\n')) {
    final m = _headingRe.firstMatch(line.trimRight());
    if (m != null) {
      final raw = m.group(1)!;
      final n = int.parse(raw);
      return (n, padNum(n), m.group(2)!.trim());
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
      logWarn('警告：$name 无法解析 BUG-NNN 标题，已跳过');
      continue;
    }
    final (n, pad, title) = parsed;
    final (fix, test) = statusIcons(body);
    entries.add(
      BugEntry(
        number: n,
        paddedNum: pad,
        title: title,
        fixIcon: fix,
        testIcon: test,
        fileName: name,
      ),
    );
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
    sb.writeln(
      '| [BUG-${e.paddedNum}]($linkDir/${e.fileName}) | ${e.fixIcon} | ${e.testIcon} | $title |',
    );
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
    throw BugToolError('$indexFile 缺少索引 marker，先跑 migrate');
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
  logOut('reindex 完成：${entries.length} 条 → $indexFile');
}

void cmdMigrate() {
  final file = File(indexFile);
  if (!file.existsSync()) {
    throw BugToolError('找不到 $indexFile');
  }
  final (_, blocks) = splitMonolith(file.readAsStringSync());
  if (blocks.isEmpty) {
    throw BugToolError('$indexFile 里没有 `## BUG-NNN` 段落，无需迁移');
  }
  Directory(bugsDir).createSync(recursive: true);
  final seen = <String>{};
  for (final block in blocks) {
    final parsed = parseHeading(block);
    if (parsed == null) {
      logWarn('警告：某段落无法解析 BUG-NNN，已跳过');
      continue;
    }
    final (_, pad, _) = parsed;
    if (!seen.add(pad)) {
      logWarn('警告：BUG-$pad 出现多次，后者覆盖前者');
    }
    File('$bugsDir/BUG-$pad.md').writeAsStringSync(block);
  }
  // 重写 docs/BUGS.md = 新头部 + 空索引 marker，再 reindex 填充。
  file.writeAsStringSync('$headerTemplate\n---\n\n$beginMarker\n$endMarker\n');
  cmdReindex();
  logOut('migrate 完成：${seen.length} 条已拆成 $bugsDir/BUG-*.md');
}

// ---------------------------------------------------------------------------
// git 薄封装
// ---------------------------------------------------------------------------

/// 跑 git；失败（git 不存在 / 超时）返回 null，不抛。
/// stdout 按 latin1 解码：`cat-file --batch` 会吐二进制 tree，latin1 是无损字节映射，
/// 我们只在里面正则找 ASCII 文件名；其它子命令输出是 ASCII 路径，同样安全。
Future<ProcessResult?> runGit(
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
  String? stdinData,
}) async {
  try {
    final proc = await Process.start(
      'git',
      args,
      environment: const <String, String>{'GIT_TERMINAL_PROMPT': '0'},
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final outDone = proc.stdout.transform(latin1.decoder).forEach(out.write);
    final errDone = proc.stderr.transform(latin1.decoder).forEach(err.write);
    if (stdinData != null) {
      proc.stdin.write(stdinData);
    }
    await proc.stdin.close().catchError((Object _) {});
    var timedOut = false;
    final code = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await outDone.catchError((Object _) {});
    await errDone.catchError((Object _) {});
    if (timedOut) return null;
    return ProcessResult(proc.pid, code, out.toString(), err.toString());
  } on ProcessException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 号池扫描（防并发撞号）：跨分支 **+ 跨工作区未提交文件**
// ---------------------------------------------------------------------------

/// 一个号的占用证据：**哪个文件名**占了它、在**哪些来源**上出现。
///
/// 为什么记文件名而不是只记一个号集合：撞号的定义是「**同一个号被两个不同的 bug 文件
/// 承载**」。只记号无法区分「我这条 bug 在 900 个 ref 上都出现」（正常）与「两条不同的
/// bug 抢同一个号」（撞号）；报出来只会是噪声，于是没人看，于是白报。
class BugNumberOccupancy {
  /// 号 → 承载它的**不同 bug 文件名**集合。size > 1 即撞号。
  final Map<int, Set<String>> fileNames = <int, Set<String>>{};

  /// bug 文件名 → 来源标签（`refs/heads/xxx` 或 `工作区 <path>`）。
  /// 每个文件名最多留 [maxSourcesPerFile] 个来源，避免 900 个 ref 撑爆内存与输出。
  final Map<String, Set<String>> sources = <String, Set<String>>{};

  static const int maxSourcesPerFile = 3;

  void add(int number, String fileName, String source) {
    (fileNames[number] ??= <String>{}).add(fileName);
    final Set<String> seen = sources[fileName] ??= <String>{};
    if (seen.length < maxSourcesPerFile) seen.add(source);
  }

  Set<int> get numbers => fileNames.keys.toSet();

  /// 某个号的「已占」说明行（给人看的，明确写「已被占用」而不是丢一个数字）。
  String describe(int number) {
    final names = (fileNames[number] ?? const <String>{}).toList()..sort();
    if (names.isEmpty) return 'BUG-${padNum(number)}：未见占用';
    final parts = names.map((String n) {
      final src = (sources[n] ?? const <String>{}).toList()..sort();
      return '$n ← ${src.isEmpty ? '（来源未知）' : src.join(' / ')}';
    });
    return 'BUG-${padNum(number)} 已被 ${names.length} 个不同文件名占用：\n      '
        '${parts.join('\n      ')}';
  }
}

/// 扫描的可信度。`fresh` = 已成功刷新远端；`stale` = 只用了本地缓存的
/// remote-tracking 引用；`unavailable` = 完全没扫到（不在 git 仓库 / 没有引用）。
enum BranchScanStatus { fresh, stale, unavailable }

/// 扫到的号池 + 占用证据。
class BranchScan {
  BranchScan(
    this.status,
    this.numbers,
    this.detail, {
    this.refCount = 0,
    this.worktreeCount = 0,
    BugNumberOccupancy? occupancy,
  }) : occupancy = occupancy ?? BugNumberOccupancy();

  final BranchScanStatus status;
  final Set<int> numbers;

  /// 降级/失败原因（`fresh` 时是空串）。
  final String detail;
  final int refCount;

  /// 真正扫到 `docs/bugs/` 的工作区个数（含当前工作区）。
  final int worktreeCount;

  final BugNumberOccupancy occupancy;

  int get maxNumber => numbers.isEmpty ? 0 : numbers.reduce(math.max);
  bool get degraded => status != BranchScanStatus.fresh;

  /// 扫描范围的人话描述（输出里到处用，别再让人从一个裸数字反推）。
  String get scopeNote => '$refCount 个 ref + $worktreeCount 个工作区';

  /// 降级时的显式警告文案——**绝不静默降级**，否则会让人误以为已经防住了。
  String? get warning {
    switch (status) {
      case BranchScanStatus.fresh:
        return null;
      case BranchScanStatus.stale:
        return '⚠ 警告：未能刷新远端分支（$detail）。'
            '只用了本地分支 + 已缓存的 remote-tracking 引用 + 本机工作区（$scopeNote），'
            '别人刚 push 到远端、本机又没有工作区的号看不见——取到的号可能与并发分支相撞。'
            '联网后重跑 `dart run tool/bug.dart check` 复核。';
      case BranchScanStatus.unavailable:
        return '⚠ 警告：未能扫描分支/工作区（$detail）。'
            '取号只看了当前工作区，**取到的号极可能与并发分支相撞**；'
            '修好后重跑 `dart run tool/bug.dart check` 复核。';
    }
  }
}

/// 只用当前工作区、没扫到任何分支时的结果（降级路径与测试共用）。
BranchScan localOnlyScan(String reason) =>
    BranchScan(BranchScanStatus.unavailable, <int>{}, reason);

/// 扫「所有本地分支 + 远端分支 + 本机所有 git 工作区的磁盘文件」上的 BUG 号。
///
/// **为什么必须扫工作区**（这是 2026-08-02 一天连撞六次的根因）：
/// `bug.dart new` 先在磁盘上写出 `docs/bugs/BUG-NNNN-slug.md`，而这个文件要等
/// 「定位根因 → 改代码 → 跑测试」之后才 commit——中间是几十分钟到几小时。
/// 只扫 commit 树意味着这整段窗口对并发 agent **完全不可见**，而并发 agent 恰恰
/// 就在这段窗口里取号。窗口不是不可约的 TOCTOU：这些 worktree 就在同一台机器的
/// 同一个文件系统上，`git worktree list` 能枚举出来，读一下目录就把窗口从「小时级」
/// 压到「同一次扫描内的毫秒级」。
///
/// 号的**判据**：
///   · `docs/bugs/BUG-NNN*.md` 的**文件名**——所有来源都认这一条；
///   · 该文件正文首个 `## BUG-NNN · 标题` 的 **H2 号**——**已提交的 ref** 上认（blob 去重后
///     读一遍很便宜），文件名与 H2 不一致时两个号都算已占；别人**未提交的工作区**上不认
///     （实测逐文件读要 320s，见 [collectWorktreeBugNumbers]）。
///   **不算占用**：代码/文档里的 `BUG-NNN` 引用。引用是指针不是认领——把引用算成占用
///   会让每条 bug 白烧一批号，而且引用天然指向已存在的号，本来就在池子里。
///
/// 性能：git 进程数固定（fetch / for-each-ref / worktree list / cat-file ×3），与分支数无关。
/// 先用 `--batch-check` 把每个 `<ref>:docs/bugs` 折成 tree sha 去重，只对唯一 tree 跑
/// `--batch`；再把 bug 文件 blob 按 sha 去重后跑第二次 `--batch` 读 H2。
/// 本仓实测：worktree list 0.5s + 693 个工作区 listSync 3.0s + 1804 个 ref 全量树/blob 2.0s。
Future<BranchScan> scanBranchBugNumbers() async {
  final env = Platform.environment;
  final remote = env['HIBIKI_BUG_REMOTE'] ?? 'origin';
  final skipRaw = env['HIBIKI_BUG_SKIP_REMOTE_FETCH'] ?? '';
  final skipFetch = skipRaw.isNotEmpty && skipRaw != '0';
  final timeoutSeconds = int.tryParse(env['HIBIKI_BUG_REMOTE_TIMEOUT'] ?? '') ?? 25;

  final inRepo = await runGit(<String>[
    'rev-parse',
    '--is-inside-work-tree',
  ], timeout: const Duration(seconds: 10));
  if (inRepo == null || inRepo.exitCode != 0) {
    return localOnlyScan('不在 git 仓库里，或找不到 git 可执行文件');
  }

  var fetched = false;
  var fetchNote = '';
  if (skipFetch) {
    fetchNote = 'HIBIKI_BUG_SKIP_REMOTE_FETCH 已设，主动跳过 fetch';
  } else {
    final fetch = await runGit(<String>[
      'fetch',
      '--quiet',
      remote,
      '+refs/heads/*:refs/remotes/$remote/*',
    ], timeout: Duration(seconds: timeoutSeconds));
    fetched = fetch != null && fetch.exitCode == 0;
    if (!fetched) {
      fetchNote = fetch == null
          ? 'git fetch $remote 超时（>${timeoutSeconds}s）或 git 不可用'
          : 'git fetch $remote 失败：${firstLine(fetch.stderr as String)}';
    }
  }

  final occupancy = BugNumberOccupancy();

  // —— ① 本机所有 git 工作区的磁盘文件（含**未提交**的新 bug 文件）。
  final worktrees = await gitWorktreePaths();
  final worktreeCount = collectWorktreeBugNumbers(worktrees, occupancy);

  // —— ② 所有本地分支 + 远端分支的 commit 树。
  final refsResult = await runGit(<String>[
    'for-each-ref',
    '--format=%(refname)',
    'refs/heads',
    'refs/remotes/$remote',
  ]);
  if (refsResult == null || refsResult.exitCode != 0) {
    return localOnlyScan('git for-each-ref 失败');
  }
  final refs = (refsResult.stdout as String)
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty && !l.endsWith('/HEAD'))
      .toList();
  if (refs.isEmpty && worktreeCount == 0) {
    return localOnlyScan('本地/远端都没有可扫的分支引用，也没扫到任何工作区');
  }
  if (refs.isNotEmpty) {
    final failure = await collectRefBugNumbers(refs, occupancy);
    if (failure != null) return localOnlyScan(failure);
  }

  final status = fetched ? BranchScanStatus.fresh : BranchScanStatus.stale;
  return BranchScan(
    status,
    occupancy.numbers,
    fetchNote,
    refCount: refs.length,
    worktreeCount: worktreeCount,
    occupancy: occupancy,
  );
}

/// 取多行文本的第一行（错误信息用）。
String firstLine(String s) {
  final t = s.trim();
  if (t.isEmpty) return '（无输出）';
  final i = t.indexOf('\n');
  return i < 0 ? t : t.substring(0, i);
}

/// bug 文件名 → 号（文件名判据；与 [locateBugFiles] / [cmdCheck] 同口径）。
final RegExp _bugFileNameRe = RegExp(r'^BUG-0*(\d+)');

/// 正文首个 `## BUG-NNN` 的号——**只认号，不认后面的 `·`**。
///
/// 为什么不复用 [parseHeading]：git blob 是按 latin1 解码的（`runGit` 要能无损搬运
/// 二进制 tree），UTF-8 的 `·`（0xC2 0xB7）在 latin1 下是两个字符 `Â·`，
/// [parseHeading] 那条要求单个 `·` 的正则永远匹配不上，H2 口径会静默失效
/// （实测：只认文件名，031 被当空号发出去）。
final RegExp _h2BugNumberRe = RegExp(r'^##[ \t]+BUG-0*(\d+)(?![0-9])', multiLine: true);

/// 取一段 bug 正文里首个 H2 的号；解析不出返回 null。
int? h2BugNumber(String body) {
  final m = _h2BugNumberRe.firstMatch(body);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// 本机所有 git 工作区的路径（含主 checkout）。git 不可用时返回当前目录兜底。
Future<List<String>> gitWorktreePaths() async {
  final r = await runGit(<String>[
    'worktree',
    'list',
    '--porcelain',
  ], timeout: const Duration(seconds: 60));
  if (r == null || r.exitCode != 0) return <String>[Directory.current.path];
  final paths = <String>[];
  for (final line in (r.stdout as String).split('\n')) {
    final t = line.trim();
    if (t.startsWith('worktree ')) paths.add(normalizeRelPath(t.substring(9).trim()));
  }
  // 当前目录可能是某个 worktree 的子目录，也可能压根没被 git 列出来；总之要包含自己。
  final self = normalizeRelPath(Directory.current.path);
  if (!paths.contains(self)) paths.add(self);
  return paths;
}

/// 读每个工作区磁盘上的 `docs/bugs/` **目录项名**，把号 + 文件名记进 [occupancy]。
/// 返回真正扫到该目录的工作区个数。
///
/// **只看文件名，不读正文**——这是量出来的取舍，不是偷懒：本机 693 个工作区里一共
/// 796,356 个 bug 文件条目，`listSync` 全扫 3.0s，而逐个 `readAsStringSync` 读 H2 要
/// **320s**（实测）。取号命令等 5 分钟等于没人会用它，那才是真正的倒退。
/// 漏掉的只有「文件名号与 H2 号不一致」这一种坏态在**别人未提交的工作区**里的情形：
///   · `new` / `renumber` 生成的文件两者天然一致，新建这条路径不受影响（撞号的正是新建）；
///   · 一旦那条 bug 被 commit，ref 扫描这边会读 blob 的 H2，两个号都会记上；
///   · 本工作区自己的 H2 由 [scanBugs] / [cmdCheck] 覆盖，坏态直接报红。
int collectWorktreeBugNumbers(List<String> worktreePaths, BugNumberOccupancy occupancy) {
  var scanned = 0;
  for (final path in worktreePaths) {
    final dir = Directory('$path/$bugsDir');
    List<FileSystemEntity> entries;
    try {
      if (!dir.existsSync()) continue;
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      continue; // 断链的盘符 / 权限不足 / 工作区已被删——跳过，不影响其它来源
    }
    scanned++;
    final source = '工作区 $path';
    for (final entity in entries) {
      if (entity is! File) continue;
      final name = baseName(entity.path);
      if (!name.endsWith('.md') || name.startsWith('_')) continue;
      final m = _bugFileNameRe.firstMatch(name);
      final nameNum = m == null ? null : int.tryParse(m.group(1)!);
      if (nameNum != null) occupancy.add(nameNum, name, source);
    }
  }
  return scanned;
}

/// 对一批 ref 读 `<ref>:docs/bugs` 目录，把号 + 文件名记进 [occupancy]。
/// 成功返回 null；git 出错返回失败原因（调用方据此降级）。
Future<String?> collectRefBugNumbers(List<String> refs, BugNumberOccupancy occupancy) async {
  final check = await runGit(
    <String>['cat-file', '--batch-check'],
    stdinData: refs.map((String r) => '$r:$bugsDir\n').join(),
    timeout: const Duration(seconds: 120),
  );
  if (check == null || check.exitCode != 0) {
    return 'git cat-file --batch-check 读 ${refs.length} 个分支的 $bugsDir 失败或超时';
  }
  // `--batch-check` 逐行对应输入行；命中是 `<sha> tree <size>`，分支上没这目录是
  // `<input> missing`。按输入顺序把 tree sha 归到第一个用到它的 ref（去重后仍能说清来源）。
  final treeToRef = <String, String>{};
  final checkLines = (check.stdout as String).split('\n');
  for (var i = 0; i < checkLines.length && i < refs.length; i++) {
    final parts = checkLines[i].trim().split(' ');
    if (parts.length >= 2 && parts[1] == 'tree') {
      treeToRef.putIfAbsent(parts[0], () => refs[i]);
    }
  }
  if (treeToRef.isEmpty) return null;

  final treeShas = treeToRef.keys.toList();
  final trees = await runGit(
    <String>['cat-file', '--batch'],
    stdinData: treeShas.map((String s) => '$s\n').join(),
    timeout: const Duration(seconds: 120),
  );
  if (trees == null || trees.exitCode != 0) {
    return 'git cat-file --batch 读 ${treeShas.length} 棵 $bugsDir 树失败或超时';
  }

  // blob sha → (文件名, 来源 ref)：同一份内容在几百个 ref 上重复，按 sha 去重后
  // 只读几千个唯一 blob，才能负担得起「正文 H2 也算占用」。
  final blobOwners = <String, (String, String)>{};
  for (final block in parseBatchBlocks(trees.stdout as String)) {
    final ref = treeToRef[block.sha] ?? '（未知 ref）';
    for (final entry in parseTreeEntries(block.body)) {
      if (!entry.name.endsWith('.md') || entry.name.startsWith('_')) continue;
      final m = _bugFileNameRe.firstMatch(entry.name);
      final nameNum = m == null ? null : int.tryParse(m.group(1)!);
      if (nameNum != null) occupancy.add(nameNum, entry.name, ref);
      blobOwners.putIfAbsent(entry.sha, () => (entry.name, ref));
    }
  }
  if (blobOwners.isEmpty) return null;

  // 第二遍：读唯一 blob 的正文 H2。文件名与 H2 不一致是已知坏态（`check` 会报红），
  // 但坏态存在期间**两个号都被认领了**，只认文件名会漏掉 H2 那个。
  final blobs = await runGit(
    <String>['cat-file', '--batch'],
    stdinData: blobOwners.keys.map((String s) => '$s\n').join(),
    timeout: const Duration(seconds: 120),
  );
  if (blobs == null || blobs.exitCode != 0) {
    return 'git cat-file --batch 读 ${blobOwners.length} 个 bug 文件内容失败或超时';
  }
  for (final block in parseBatchBlocks(blobs.stdout as String)) {
    final owner = blobOwners[block.sha];
    if (owner == null) continue;
    final headingNum = h2BugNumber(block.body);
    if (headingNum == null) continue;
    final m = _bugFileNameRe.firstMatch(owner.$1);
    final nameNum = m == null ? null : int.tryParse(m.group(1)!);
    if (headingNum != nameNum) {
      occupancy.add(headingNum, owner.$1, '${owner.$2}（正文 H2）');
    }
  }
  return null;
}

/// `git cat-file --batch` 输出的一个对象块。
class BatchBlock {
  BatchBlock(this.sha, this.type, this.body);

  final String sha;
  final String type;

  /// 原始内容（latin1 解码，1 字符 = 1 字节，所以可以直接用 header 里的 size 切）。
  final String body;
}

/// 切 `git cat-file --batch` 的输出：`<sha> SP <type> SP <size> LF <body> LF` 重复。
/// 按 size 精确切块（不靠猜换行），块内是二进制 tree 也不会串块。
List<BatchBlock> parseBatchBlocks(String raw) {
  final blocks = <BatchBlock>[];
  var pos = 0;
  while (pos < raw.length) {
    final nl = raw.indexOf('\n', pos);
    if (nl < 0) break;
    final parts = raw.substring(pos, nl).split(' ');
    if (parts.length < 3) break; // `<sha> missing` 之类，无法继续按 size 切
    final size = int.tryParse(parts[2]);
    if (size == null) break;
    final start = nl + 1;
    final end = start + size;
    if (end > raw.length) break;
    blocks.add(BatchBlock(parts[0], parts[1], raw.substring(start, end)));
    pos = end + 1; // 跳过块尾的 LF
  }
  return blocks;
}

/// 一条 git tree 项。
class TreeEntry {
  TreeEntry(this.name, this.sha);

  final String name;
  final String sha; // 40 位十六进制
}

/// 解析 git tree 对象体：`<mode> SP <name> NUL <20 字节 sha>` 重复。
///
/// 刻意**不**用「在整段二进制里正则找 `BUG-\d+`」——20 字节裸 sha 里随机撞出 `BUG-`
/// 字节序列的概率不是 0（本仓 ~23MB sha 字节，期望约 0.5% 命中一次），那会凭空多出
/// 一个占用号。按结构解析既准确又拿得到文件名和 blob sha。
List<TreeEntry> parseTreeEntries(String body) {
  final entries = <TreeEntry>[];
  var pos = 0;
  while (pos < body.length) {
    final space = body.indexOf(' ', pos);
    if (space < 0) break;
    final nul = body.indexOf('\u0000', space + 1);
    if (nul < 0) break;
    final name = body.substring(space + 1, nul);
    final shaStart = nul + 1;
    if (shaStart + 20 > body.length) break;
    final sb = StringBuffer();
    for (var i = shaStart; i < shaStart + 20; i++) {
      sb.write(body.codeUnitAt(i).toRadixString(16).padLeft(2, '0'));
    }
    entries.add(TreeEntry(name, sb.toString()));
    pos = shaStart + 20;
  }
  return entries;
}

// ---------------------------------------------------------------------------
// new
// ---------------------------------------------------------------------------

/// 取号时的分支扫描器（测试注入假实现用）。
typedef BranchScanner = Future<BranchScan> Function();

Future<void> cmdNew(List<String> args, {BranchScanner? scanner}) async {
  if (args.isEmpty) {
    throw BugToolError(
      '用法：dart run tool/bug.dart new <slug> [标题...]\n'
      '  slug 是 ascii kebab（如 reader-internal-link），让并发新建落成不同文件名',
    );
  }
  final slug = sanitizeSlug(args.first);
  if (slug.isEmpty) {
    throw BugToolError('slug 清洗后为空，请用 ascii 字母/数字/连字符');
  }
  final title = args.length > 1 ? args.sublist(1).join(' ') : slug;
  final entries = scanBugs();
  final localMax = entries.isEmpty ? 0 : entries.first.number;

  final scan = await (scanner ?? scanBranchBugNumbers)();
  final warning = scan.warning;
  if (warning != null) logWarn(warning);

  final next = math.max(localMax, scan.maxNumber) + 1;
  final pad = padNum(next);
  Directory(bugsDir).createSync(recursive: true);
  final path = '$bugsDir/BUG-$pad-$slug.md';
  if (File(path).existsSync()) {
    throw BugToolError('$path 已存在');
  }
  final now = DateTime.now();
  final dateIso =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  File(path).writeAsStringSync(bugSkeleton(pad, title, dateIso));
  cmdReindex();
  // 输出语义：**只说「已占」，绝不丢一个裸数字**。
  // 历史事故：探针只打印「下一个可用号 N+1」，被读成「N 没冲突」，于是 N 被当成空号用掉。
  logOut('取号 BUG-$pad（= 已占最大号 + 1）');
  logOut('  当前工作区已占最大：BUG-${padNum(localMax)}');
  if (scan.status == BranchScanStatus.unavailable) {
    logOut('  跨分支/工作区：未扫到（见上面的警告）');
  } else {
    logOut('  跨分支/工作区已占最大：BUG-${padNum(scan.maxNumber)}'
        '（扫了 ${scan.scopeNote}，共 ${scan.numbers.length} 个号已被占用）');
    final recent = describeTopOccupied(scan.occupancy, 5);
    if (recent.isNotEmpty) {
      logOut('  最近已被占用的号（**这些是已占，不是可用**）：');
      for (final line in recent) {
        logOut('    $line');
      }
    }
  }
  logOut('已建 $path');
  logOut('填完根因/修复/测试后再跑 `dart run tool/bug.dart reindex`');
  logOut('⚠ 取号不是分布式锁：开 PR 前和每次 rebase 后重跑 `dart run tool/bug.dart check`');
}

/// 最大的 [count] 个已占号的说明行（每行写清号 + 承载它的文件名 + 来源）。
List<String> describeTopOccupied(BugNumberOccupancy occupancy, int count) {
  final nums = occupancy.fileNames.keys.toList()..sort((int a, int b) => b.compareTo(a));
  return nums.take(count).map(occupancy.describe).toList();
}

/// slug 清洗成 ascii kebab。
String sanitizeSlug(String s) {
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

// ---------------------------------------------------------------------------
// renumber
// ---------------------------------------------------------------------------

/// 号引用的**唯一口径**：`BUG-1138` / `bug_1138` / `bug-1138`（允许前导 0；禁止数字粘连，
/// 也不误伤 `debug-1138` 这种词尾）。替换、预览、自校验三处共用同一个正则，口径不会漂。
RegExp bugRefPattern(int number) => RegExp('(?<![0-9A-Za-z])(BUG|Bug|bug)([-_])0*$number(?![0-9])');

/// 一处待改的引用。
class BugRefEdit {
  BugRefEdit(this.path, this.line, this.before, this.after);

  final String path;
  final int line; // 1-based
  final String before;
  final String after;
}

/// 一次文件改名。
class BugFileRename {
  BugFileRename(this.from, this.to);

  final String from;
  final String to;
}

/// renumber 的完整计划（`--dry-run` 直接打印它）。
class RenumberPlan {
  RenumberPlan(this.oldNumber, this.newNumber, this.edits, this.renames);

  final int oldNumber;
  final int newNumber;
  final List<BugRefEdit> edits;
  final List<BugFileRename> renames;
}

/// 把 path 的**文件名部分**里的号换掉；文件名不含该号则返回 null。
String? renameNumberInPath(String path, int oldNumber, int newNumber) {
  final sepIdx = math.max(path.lastIndexOf('/'), path.lastIndexOf(r'\'));
  final dir = sepIdx < 0 ? '' : path.substring(0, sepIdx + 1);
  final base = path.substring(sepIdx + 1);
  final re = bugRefPattern(oldNumber);
  if (!re.hasMatch(base)) return null;
  final pad = padNum(newNumber);
  return dir + base.replaceAllMapped(re, (Match m) => '${m[1]}${m[2]}$pad');
}

/// 明确排除的二进制/容器扩展名（**黑名单**，只是省一次开文件的快路径；
/// 真正的判据是下面的 NUL 嗅探）。
///
/// 🔴 判据必须是黑名单，不能是白名单。旧实现要求「有点号 + 扩展名在白名单里」，
/// 实测把 `.gitattributes` / `third_party/m_extension_server/UPSTREAM` / `LICENSE` /
/// `Makefile` 这类**没有扩展名或扩展名冷门的纯文本**全判成非文本；它们既不会被
/// renumber 替换，也不会被自校验看见——一次改号 9 处引用只落了 7 处，工具仍报
/// 「零残留」（TODO-2669）。文本文件的扩展名是开放集合，枚举不完；二进制格式是
/// 有限集合，而且漏了一个还有 NUL 嗅探兜底。
const Set<String> binaryExtensions = <String>{
  // 图片
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.icns', '.webp', '.avif',
  '.tif', '.tiff', '.psd', '.heic',
  // 字体
  '.ttf', '.otf', '.ttc', '.woff', '.woff2', '.eot',
  // 音视频
  '.mp3', '.wav', '.flac', '.ogg', '.opus', '.m4a', '.aac', '.mp4', '.m4v',
  '.mkv', '.mov', '.avi', '.webm', '.wmv', '.flv',
  // 归档 / 压缩
  '.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.zst', '.lz4',
  '.jar', '.aar', '.apk', '.aab', '.ipa', '.war', '.nupkg',
  // 可执行 / 库 / 编译中间产物
  '.exe', '.dll', '.so', '.dylib', '.lib', '.a', '.o', '.obj', '.pdb',
  '.class', '.dex', '.wasm', '.bin', '.pyc', '.pyd',
  // 文档 / 数据库 / 密钥容器
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.db', '.sqlite', '.sqlite3', '.jks', '.keystore', '.p12', '.pfx', '.der',
  // 模型 / 词典二进制
  '.onnx', '.tflite', '.pt', '.pth', '.safetensors', '.mdx', '.mdd',
};

/// 无论从哪条枚举路径来的都不扫的目录（生成物 / 缓存 / VCS 内部 / 测试证据）。
/// `git ls-files` 本来就不吐这些，但兜底遍历 [walkFallback] 与 [extraScanPaths] 会。
const List<String> excludedScanPrefixes = <String>[
  '.git/',
  '.dart_tool/',
  'build/',
  'node_modules/',
  '.gradle/',
  '.idea/',
  'Pods/',
  '.worktrees/',
  '.claude/',
  '.codex-test/',
];

/// 头部多少字节内出现 NUL 就判二进制（git 自己也是这个套路）。
const int binarySniffBytes = 8192;

/// 纯字节判据：这段头部像不像二进制。不碰路径、不碰扩展名。
///
/// 替换侧与自校验侧共用**这一个低层原语**是有意的——「什么算二进制」只该有一个定义。
/// 二者的独立性在于各自的**枚举与过滤**，见 [residualScanPaths]。
bool bytesLookBinary(List<int> head) => head.contains(0);

/// 读文件头做 NUL 嗅探。读不出来一律当二进制（扫不了的东西别硬扫）。
/// 只读前 [binarySniffBytes] 字节——仓里最大的几个无扩展名文件是 18MB 的
/// `libavcodec`，整读会把 renumber 拖垮。
bool fileLooksBinary(String path) {
  RandomAccessFile? raf;
  try {
    raf = File(path).openSync();
    final int len = raf.lengthSync();
    if (len <= 0) return false; // 空文件当文本，无害
    final int n = len < binarySniffBytes ? len : binarySniffBytes;
    return bytesLookBinary(raf.readSync(n));
  } on FileSystemException {
    return true;
  } finally {
    try {
      raf?.closeSync();
    } on FileSystemException {
      // 关不上不影响判据。
    }
  }
}

/// 路径层面就能否掉的（不碰磁盘）：排除目录 + 二进制扩展名黑名单。
///
/// 「扩展名」只认最后一个点**在文件名中间**的那种：`.gitattributes` / `.gitignore`
/// 的前导点不是扩展名分隔符，旧实现把它当扩展名正是漏扫的原因之一。
bool isExcludedScanPath(String path) {
  final String p = normalizeRelPath(path);
  for (final prefix in excludedScanPrefixes) {
    if (p.startsWith(prefix) || p == prefix.substring(0, prefix.length - 1)) return true;
  }
  final int slash = p.lastIndexOf('/');
  final int dot = p.lastIndexOf('.');
  if (dot > slash + 1 && binaryExtensions.contains(p.substring(dot).toLowerCase())) return true;
  return false;
}

/// 这个文件值不值得按文本扫描：先路径/扩展名黑名单毙掉（不碰磁盘），
/// 剩下的读头 [binarySniffBytes] 字节做 NUL 嗅探。
bool looksTextual(String path) {
  if (isExcludedScanPath(path)) return false;
  return !fileLooksBinary(path);
}

/// 取路径的文件名部分。
String baseName(String path) {
  final sepIdx = math.max(path.lastIndexOf('/'), path.lastIndexOf(r'\'));
  return sepIdx < 0 ? path : path.substring(sepIdx + 1);
}

/// git 不可用时的兜底遍历要跳过的目录。
const Set<String> skipDirs = <String>{
  '.git',
  '.dart_tool',
  'build',
  'node_modules',
  '.worktrees',
  '.claude',
  '.codex-test',
  'Pods',
  '.gradle',
  '.idea',
};

List<String> walkFallback() {
  final out = <String>[];
  void walk(Directory dir, String prefix) {
    for (final e in dir.listSync(followLinks: false)) {
      final name = baseName(e.path);
      final rel = prefix.isEmpty ? name : '$prefix/$name';
      if (e is Directory) {
        if (skipDirs.contains(name)) continue;
        walk(e, rel);
      } else if (e is File) {
        out.add(rel);
      }
    }
  }

  walk(Directory.current, '');
  return out;
}

/// 仓库里所有「可能引用 BUG 号」的文本文件路径：tracked + 未被 ignore 的 untracked
/// （新建但还没 commit 的 bug 文件/测试也在内）+ 本地不入库的已知 bug 文档。
/// git 不可用时退回目录遍历。
Future<List<String>> repoScanPaths() async {
  final paths = <String>{};
  final tracked = await runGit(<String>['ls-files', '-z'], timeout: const Duration(seconds: 60));
  final others = await runGit(<String>[
    'ls-files',
    '-z',
    '--others',
    '--exclude-standard',
  ], timeout: const Duration(seconds: 60));
  if (tracked != null && tracked.exitCode == 0) {
    for (final r in <ProcessResult?>[tracked, others]) {
      if (r == null || r.exitCode != 0) continue;
      paths.addAll((r.stdout as String).split('\u0000').where((String p) => p.isNotEmpty));
    }
  } else {
    paths.addAll(walkFallback());
  }
  for (final extra in extraScanPaths) {
    if (File(extra).existsSync()) paths.add(extra);
  }
  // 先 exists 再 looksTextual：后者要开文件做 NUL 嗅探，路径不存在时白扔一个异常。
  final list = paths.where((String p) => File(p).existsSync()).where(looksTextual).toList()..sort();
  return list;
}

/// 自校验专用的**独立**文件枚举。
///
/// 🔴 刻意不复用 [repoScanPaths] / [looksTextual]：守卫和被守对象共用同一个扫描器时，
/// 扫描器漏掉的文件在守卫里同样看不见，「自校验零残留」就是假的。TODO-2669 实测：
/// 一次改号 9 处引用只落了 7 处，漏掉 `.gitattributes` 与
/// `third_party/m_extension_server/UPSTREAM`，而 renumber 仍打印「自校验零残留」。
///
/// 这里只做两件事：把工作区文件全列出来、逐个确认真实存在。**一个扩展名判据都不用**
/// ——扩展名/黑名单再退化一次，这条路照样看得见残留。二进制在
/// [findResidualRefs] 里按字节现场判。
Future<List<String>> residualScanPaths() async {
  final paths = <String>{};
  final tracked = await runGit(<String>['ls-files', '-z'], timeout: const Duration(seconds: 60));
  final others = await runGit(<String>[
    'ls-files',
    '-z',
    '--others',
    '--exclude-standard',
  ], timeout: const Duration(seconds: 60));
  if (tracked != null && tracked.exitCode == 0) {
    for (final r in <ProcessResult?>[tracked, others]) {
      if (r == null || r.exitCode != 0) continue;
      paths.addAll(splitGitZ(r.stdout as String));
    }
  } else {
    paths.addAll(walkFallback().map(normalizeRelPath));
  }
  for (final extra in extraScanPaths) {
    if (File(extra).existsSync()) paths.add(normalizeRelPath(extra));
  }
  final list = paths
      .where((String p) => !p.startsWith('.git/'))
      .where((String p) => File(p).existsSync())
      .toList()
    ..sort();
  return list;
}

// ---------------------------------------------------------------------------
// renumber 作用域：撞号态下把替换范围钉在「本次改动引入的文件集」
// ---------------------------------------------------------------------------

/// 路径统一成正斜杠（git 吐正斜杠，Dart 在 Windows 上可能拿到反斜杠；两边要能对上）。
String normalizeRelPath(String p) => p.replaceAll(r'\', '/');

/// 默认基线 ref 候选（按顺序取第一个存在的）。
const List<String> defaultBaseRefCandidates = <String>[
  'origin/develop',
  'develop',
  'origin/main',
  'main',
  'origin/master',
  'master',
];

/// 「本次改动引入的文件集」——撞号态下 renumber 的替换范围。
///
/// 判据钉在**不可变事实**上：`merge-base(base, HEAD)` 之后我这条线新增/修改的文件，
/// 加上未跟踪文件（`bug.dart new` 刚建出来还没 commit 的正是这一类）。
/// 不钉在「文件里有没有 BUG-old」上——那正是会把 base 侧合法同号条目卷进来的错误判据。
class RenumberScope {
  RenumberScope({
    required this.paths,
    required this.baseRef,
    required this.mergeBase,
    required this.detail,
  });

  /// 解析失败时的空作用域（[detail] 说明原因）。
  RenumberScope.unavailable(this.detail)
      : paths = const <String>{},
        baseRef = '',
        mergeBase = '';

  /// 相对仓库根、正斜杠的路径集合。
  final Set<String> paths;
  final String baseRef;
  final String mergeBase;

  /// 解析失败原因；成功时是空串。
  final String detail;

  bool get available => detail.isEmpty;

  /// 作用域可用**且非空**才能拿来消歧/限范围。空作用域（例如站在 base 分支本身、
  /// 什么都没改）等同于「不知道哪些文件是我的」，绝不能当成「一个都不改」静默通过。
  bool get usable => available && paths.isNotEmpty;

  bool contains(String path) => paths.contains(normalizeRelPath(path));
}

/// 把 `-z` 分隔的 git 路径输出切成集合。
Set<String> splitGitZ(String raw) =>
    raw.split('\u0000').where((String p) => p.isNotEmpty).map(normalizeRelPath).toSet();

/// 解析基线 ref：显式 `--base` > `HIBIKI_BUG_BASE` > [defaultBaseRefCandidates]。
/// 返回第一个真实存在的 ref 名；都不存在返回 null。
Future<String?> resolveBaseRef(String? explicit) async {
  final env = Platform.environment;
  final fromEnv = (env['HIBIKI_BUG_BASE'] ?? '').trim();
  final wanted = (explicit != null && explicit.trim().isNotEmpty)
      ? explicit.trim()
      : (fromEnv.isNotEmpty ? fromEnv : null);
  final candidates = wanted != null ? <String>[wanted] : defaultBaseRefCandidates;
  for (final ref in candidates) {
    final r = await runGit(<String>[
      'rev-parse',
      '--verify',
      '--quiet',
      '$ref^{commit}',
    ], timeout: const Duration(seconds: 15));
    if (r != null && r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty) {
      return ref;
    }
  }
  return null;
}

/// 算出本次改动引入的文件集。两个 git 调用：
///   1. `git diff --name-only -z <merge-base>` —— merge-base 对比**工作区**，
///      一把覆盖「已提交 + 已 stage + 未 stage」三种状态。
///   2. `git ls-files -o --exclude-standard -z` —— 未跟踪（刚 `new` 出来的 bug 文件）。
Future<RenumberScope> resolveRenumberScope({String? baseRef}) async {
  final inRepo = await runGit(<String>[
    'rev-parse',
    '--is-inside-work-tree',
  ], timeout: const Duration(seconds: 10));
  if (inRepo == null || inRepo.exitCode != 0) {
    return RenumberScope.unavailable('不在 git 仓库里，或找不到 git 可执行文件');
  }
  final resolved = await resolveBaseRef(baseRef);
  if (resolved == null) {
    final tried = (baseRef ?? Platform.environment['HIBIKI_BUG_BASE'] ?? '').trim();
    return RenumberScope.unavailable(
      tried.isNotEmpty
          ? 'base ref `$tried` 不存在'
          : '找不到可用的 base ref（试过 ${defaultBaseRefCandidates.join(' / ')}）',
    );
  }
  final mb = await runGit(<String>[
    'merge-base',
    resolved,
    'HEAD',
  ], timeout: const Duration(seconds: 30));
  if (mb == null || mb.exitCode != 0 || (mb.stdout as String).trim().isEmpty) {
    return RenumberScope.unavailable('git merge-base $resolved HEAD 失败（无共同祖先？）');
  }
  final mergeBase = (mb.stdout as String).trim();
  final diff = await runGit(<String>[
    'diff',
    '--name-only',
    '-z',
    mergeBase,
  ], timeout: const Duration(seconds: 60));
  if (diff == null || diff.exitCode != 0) {
    return RenumberScope.unavailable('git diff --name-only $mergeBase 失败');
  }
  final untracked = await runGit(<String>[
    'ls-files',
    '-o',
    '--exclude-standard',
    '-z',
  ], timeout: const Duration(seconds: 60));
  final paths = splitGitZ(diff.stdout as String);
  if (untracked != null && untracked.exitCode == 0) {
    paths.addAll(splitGitZ(untracked.stdout as String));
  }
  return RenumberScope(paths: paths, baseRef: resolved, mergeBase: mergeBase, detail: '');
}

/// 某路径在 [ref] 那个 commit 上是否存在。撞号消歧的**首选判据**：
/// 「我引入的那一份」＝ base 上还没有的那一份。
Future<bool> pathExistsAtRef(String ref, String path) async {
  final r = await runGit(<String>[
    'cat-file',
    '-e',
    '$ref:${normalizeRelPath(path)}',
  ], timeout: const Duration(seconds: 15));
  return r != null && r.exitCode == 0;
}

/// 范围外文件的指纹：`路径 → "内容命中数:文件名是否命中"`，只留有命中的项。
/// 改号前后各取一次，任何差异都说明「碰到了不该碰的文件」。
Map<String, String> bugRefFingerprint(int number, Iterable<String> paths) {
  final re = bugRefPattern(number);
  final out = <String, String>{};
  for (final p in paths) {
    final f = File(p);
    if (!f.existsSync()) continue;
    String content;
    try {
      content = f.readAsStringSync();
    } on FileSystemException {
      continue;
    } on FormatException {
      continue; // 非 UTF-8 文本，不可能是 BUG 引用载体
    }
    final contentHits = re.allMatches(content).length;
    final nameHit = re.hasMatch(baseName(p)) ? 1 : 0;
    if (contentHits == 0 && nameHit == 0) continue;
    out[normalizeRelPath(p)] = '$contentHits:$nameHit';
  }
  return out;
}

/// 扫出所有仍在引用 `number` 的位置（`path:line` 或 `path（文件名）`）。
/// renumber 的自校验用这个，命中判据与替换一致（同一个 [bugRefPattern]），
/// 但**文件枚举刻意各走各的**：不传 [paths] 时走 [residualScanPaths]，不是
/// [repoScanPaths]。守卫和被守对象共用扫描器 = 守卫永远和 bug 同盲（TODO-2669）。
/// 只看工作区文件——git 历史里的旧号是历史，不算残留。
Future<List<String>> findResidualRefs(int number, {List<String>? paths}) async {
  final files = paths ?? await residualScanPaths();
  final re = bugRefPattern(number);
  final hits = <String>[];
  for (final p in files) {
    final f = File(p);
    if (!f.existsSync()) continue;
    // 自校验自己判二进制（按字节，不看扩展名）：扩展名判据再退化，这里仍看得见。
    if (fileLooksBinary(p)) {
      if (re.hasMatch(baseName(p))) hits.add('$p（文件名）');
      continue;
    }
    String content;
    try {
      // 宽松解码：GBK 等非 UTF-8 文本里的 `BUG-NNN` 是纯 ASCII，照样得算残留。
      // 旧实现在 FormatException 上直接 `continue`，等于对这类文件也瞎。
      content = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
    } on FileSystemException {
      continue;
    }
    if (re.hasMatch(content)) {
      final lines = content.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (re.hasMatch(lines[i])) hits.add('$p:${i + 1}');
      }
    }
    if (re.hasMatch(baseName(p))) hits.add('$p（文件名）');
  }
  return hits;
}

/// 组装 renumber 计划（不落盘）。
/// [paths] 是**已经框定好的**替换范围；不传则退回全仓（只在 old 号唯一时才成立）。
Future<RenumberPlan> buildRenumberPlan(int oldNumber, int newNumber, {List<String>? paths}) async {
  paths ??= await repoScanPaths();
  final re = bugRefPattern(oldNumber);
  final newPad = padNum(newNumber);
  final edits = <BugRefEdit>[];
  final renames = <BugFileRename>[];
  for (final p in paths) {
    String content;
    try {
      content = File(p).readAsStringSync();
    } on FileSystemException {
      continue;
    } on FormatException {
      continue; // 非 UTF-8 文本（GBK 等），不可能是我们要改的 BUG 引用载体，跳过
    }
    if (re.hasMatch(content)) {
      final lines = content.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!re.hasMatch(lines[i])) continue;
        edits.add(
          BugRefEdit(
            p,
            i + 1,
            lines[i].trimRight(),
            lines[i].replaceAllMapped(re, (Match m) => '${m[1]}${m[2]}$newPad').trimRight(),
          ),
        );
      }
    }
    final renamed = renameNumberInPath(p, oldNumber, newNumber);
    if (renamed != null && renamed != p) renames.add(BugFileRename(p, renamed));
  }
  return RenumberPlan(oldNumber, newNumber, edits, renames);
}

/// 列出所有承载 `number` 的 bug 文件（正文 H2 或文件名任一命中即算——文件名与 H2 不一致
/// 正是要修的坏状态）。返回相对仓库根、已排序的路径列表；一个都没有就返回空列表。
///
/// **撞号态返回多份是正常的**，不是错误：PR 侧和 base 侧各占一份同号，正是唯一需要
/// `renumber` 的场景。消歧交给 [pickOwnBugFile]，不在这里抛错退出。
List<String> locateBugFiles(int number) {
  final dir = Directory(bugsDir);
  if (!dir.existsSync()) throw BugToolError('找不到 $bugsDir 目录');
  final matches = <String>[];
  for (final f in dir.listSync().whereType<File>()) {
    final name = baseName(f.path);
    if (!name.endsWith('.md') || name.startsWith('_')) continue;
    final byName = RegExp(r'^BUG-0*(\d+)').firstMatch(name);
    final headingNum = parseHeading(f.readAsStringSync())?.$1;
    final nameNum = byName == null ? null : int.tryParse(byName.group(1)!);
    if (headingNum == number || nameNum == number) matches.add('$bugsDir/$name');
  }
  matches.sort();
  return matches;
}

/// 找唯一承载 `number` 的 bug 文件；不存在或撞号（多份）都抛。
/// 只给「必须唯一」的场景用（例如判断目标号是否已被占用）。
String locateBugFile(int number) {
  final matches = locateBugFiles(number);
  if (matches.isEmpty) throw BugToolError('BUG-${padNum(number)} 在 $bugsDir/ 里不存在');
  if (matches.length > 1) {
    throw BugToolError('BUG-${padNum(number)} 命中多个文件：${matches.join('、')}');
  }
  return matches.first;
}

/// 撞号态消歧：从 [candidates] 里挑出「本次改动引入的那一份」。
///
/// 判据按可靠性排序：
///   1. **base 上不存在** —— 我新建的那一份。这是最硬的事实，和文件内容、行状态都无关。
///   2. 落在作用域（本次改动的文件集）内 —— 兜底，覆盖「base 上有同名文件但被我整体替换」。
/// 两条都判不出唯一解就抛错，让人处理，**绝不猜**——猜错就是改坏 base 侧合法条目。
Future<String> pickOwnBugFile(int number, List<String> candidates, RenumberScope scope) async {
  if (candidates.length == 1) return candidates.first;
  final introduced = <String>[];
  for (final p in candidates) {
    if (!await pathExistsAtRef(scope.mergeBase, p)) introduced.add(p);
  }
  if (introduced.length == 1) return introduced.first;
  final pool = introduced.isEmpty ? candidates : introduced;
  final inScope = pool.where(scope.contains).toList();
  if (inScope.length == 1) return inScope.first;
  throw BugToolError(
    'BUG-${padNum(number)} 撞号：$bugsDir/ 里有 ${candidates.length} 份同号文件'
    '（${candidates.join('、')}），但无法判定哪一份是本次改动引入的'
    '（base=${scope.baseRef}@${shortSha(scope.mergeBase)}：'
    '新增 ${introduced.length} 份 / 作用域内 ${inScope.length} 份）。'
    '换一个更贴切的基线重试（`--base <ref>`），或先人工归并。',
  );
}

/// 取短 sha（错误信息里用，避免整行 40 位）。
String shortSha(String sha) => sha.length <= 9 ? sha : sha.substring(0, 9);

String clipLine(String s) => s.length <= 160 ? s : '${s.substring(0, 157)}...';

/// 优先 `git mv` 保留历史；文件还没入库（untracked）时 git mv 必失败，退回普通改名。
Future<void> renameTracked(String from, String to) async {
  final mv = await runGit(<String>['mv', from, to]);
  if (mv != null && mv.exitCode == 0) return;
  File(from).renameSync(to);
}

/// 改号：文件名 + 正文 H2 + 代码注释 + 测试名 + 测试文件名内嵌号，**五类一把改**，
/// 改完自动 reindex 并**自校验旧号零残留**。前置校验不通过就整体退出，不做半截修改。
///
/// 撞号态（≥2 个 bug 文件占 old）下会自动把替换范围框到「本次改动引入的文件集」，
/// 并对范围外文件做前后指纹断言——见文件头「renumber 的两种模式」。
Future<void> cmdRenumber(List<String> args, {BranchScanner? scanner}) async {
  final positional = <String>[];
  var dryRun = false;
  String? baseOpt;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--dry-run') {
      dryRun = true;
    } else if (a == '--base') {
      if (i + 1 >= args.length) throw BugToolError('--base 后面要跟一个 ref');
      baseOpt = args[++i];
    } else if (a.startsWith('--base=')) {
      baseOpt = a.substring('--base='.length);
    } else if (a.startsWith('--')) {
      throw BugToolError('未知选项：$a');
    } else {
      positional.add(a);
    }
  }
  if (positional.length != 2) {
    throw BugToolError('用法：dart run tool/bug.dart renumber <old> <new> [--base <ref>] [--dry-run]');
  }
  if (!RegExp(r'^\d+$').hasMatch(positional[0]) || !RegExp(r'^\d+$').hasMatch(positional[1])) {
    throw BugToolError('<old> 与 <new> 必须是纯数字（拿到 ${positional[0]} / ${positional[1]}）');
  }
  final oldNumber = int.parse(positional[0]);
  final newNumber = int.parse(positional[1]);
  if (oldNumber <= 0 || newNumber <= 0) {
    throw BugToolError('<old> 与 <new> 必须是正整数');
  }
  if (oldNumber == newNumber) {
    throw BugToolError('<old> 与 <new> 相同（${padNum(oldNumber)}），无事可做');
  }

  // —— 前置校验：old 必须存在；new 必须没被占用（本地 + 跨分支同一口径）。
  final oldMatches = locateBugFiles(oldNumber);
  if (oldMatches.isEmpty) {
    throw BugToolError('BUG-${padNum(oldNumber)} 在 $bugsDir/ 里不存在');
  }
  final collided = oldMatches.length > 1;

  // —— 撞号态：算出「本次改动引入的文件集」，据此消歧 + 框死替换范围。
  //    作用域算不出来时**必须停**：这时候全仓盲替换会改坏 base 侧那条合法同号 bug，
  //    而事后 `check` 仍然报通过——静默的二次破坏，比直接失败糟得多。
  final RenumberScope scope = collided
      ? await resolveRenumberScope(baseRef: baseOpt)
      : RenumberScope.unavailable('old 号唯一，无需框范围');
  if (collided && !scope.usable) {
    throw BugToolError(
      'BUG-${padNum(oldNumber)} 撞号：$bugsDir/ 里有 ${oldMatches.length} 份同号文件'
      '（${oldMatches.join('、')}）。撞号意味着 base 上本来就有一条合法的同号 bug，'
      '此时**必须**把替换范围限定在本次改动引入的文件集里，但算不出来：'
      '${scope.available ? '作用域为空（相对 ${scope.baseRef} 没有任何改动？）' : scope.detail}。'
      '用 `--base <ref>` 指定基线后重试（如 `--base origin/develop`）。',
    );
  }
  final String oldPath = await pickOwnBugFile(oldNumber, oldMatches, scope);
  final List<String> foreignBugFiles = oldMatches.where((String p) => p != oldPath).toList();

  final localNumbers = scanBugs().map((BugEntry e) => e.number).toSet();
  final localNames = Directory(bugsDir)
      .listSync()
      .whereType<File>()
      .map((File f) => baseName(f.path))
      .where((String n) => n.endsWith('.md') && !n.startsWith('_'));
  for (final n in localNames) {
    final m = RegExp(r'^BUG-0*(\d+)').firstMatch(n);
    final parsed = m == null ? null : int.tryParse(m.group(1)!);
    if (parsed != null) localNumbers.add(parsed);
  }
  if (localNumbers.contains(newNumber)) {
    throw BugToolError(
      'BUG-${padNum(newNumber)} 本地已被占用'
      '（${locateBugFiles(newNumber).join('、')}）——换一个号',
    );
  }
  final scan = await (scanner ?? scanBranchBugNumbers)();
  final warning = scan.warning;
  if (warning != null) logWarn(warning);
  if (scan.numbers.contains(newNumber)) {
    final evidence = scan.occupancy.fileNames.containsKey(newNumber)
        ? '\n  ${scan.occupancy.describe(newNumber)}'
        : '';
    throw BugToolError(
      'BUG-${padNum(newNumber)} 已被其它分支占用（或本机其它工作区）——换一个号。$evidence\n'
      '  扫了 ${scan.scopeNote}；当前**已占**最大号是 BUG-${padNum(scan.maxNumber)}，'
      '下一个空号是 BUG-${padNum(scan.maxNumber + 1)}',
    );
  }

  // —— 框定替换范围。
  //    · 索引 docs/BUGS.md 永远排除：它是生成物，由 cmdReindex() 重建；
  //      撞号态下它同时含 base 侧那条的行，文本替换会把那行也改掉。
  //    · 别人的同号 bug 文件永远排除：绝不改不是自己引入的那条。
  final allPaths = await repoScanPaths();
  final Set<String> foreignSet = foreignBugFiles.map(normalizeRelPath).toSet();
  bool isIndex(String p) => normalizeRelPath(p) == indexFile;
  bool inScope(String p) => !collided || scope.contains(p);
  bool isForeign(String p) => foreignSet.contains(normalizeRelPath(p));

  final List<String> effectivePaths =
      allPaths.where((String p) => !isIndex(p) && inScope(p) && !isForeign(p)).toList();
  // 范围外文件（改号前后必须一字不变）。
  // 刻意**不**由 effectivePaths 取反算出来——那样一旦替换范围被改宽，守卫会跟着一起
  // 缩小、失去作用（变异实测抓到过）。两个集合各自独立地从 scope / foreign 判据算出，
  // 互为补集，替换范围漏了什么，守卫就一定看得见。
  final List<String> outsidePaths =
      allPaths.where((String p) => !isIndex(p) && (!inScope(p) || isForeign(p))).toList();

  if (collided) {
    logWarn(
      '⚠ 撞号态：BUG-${padNum(oldNumber)} 在 $bugsDir/ 有 ${oldMatches.length} 份同号文件。'
      '本次只改「$oldPath」以及 ${scope.baseRef}@${shortSha(scope.mergeBase)} 之后'
      '本改动引入的 ${scope.paths.length} 个文件；'
      '${foreignBugFiles.join('、')} 及范围外 ${outsidePaths.length} 个文件一律不碰。',
    );
    logWarn(
      '⚠ 范围内若有指向**别人那条** BUG-${padNum(oldNumber)} 的引用，工具无法从文本上分辨，'
      '会一并改掉——先跑 `--dry-run` 逐行过一遍。',
    );
  }

  final plan = await buildRenumberPlan(oldNumber, newNumber, paths: effectivePaths);
  for (final r in plan.renames) {
    if (File(r.to).existsSync()) {
      throw BugToolError('目标文件已存在：${r.to}——换一个号');
    }
  }
  if (plan.edits.isEmpty && plan.renames.isEmpty) {
    throw BugToolError('没扫到任何 BUG-${padNum(oldNumber)} 引用（$oldPath 也没匹配？）——中止');
  }

  if (dryRun) {
    logOut(
      '[dry-run] BUG-${padNum(oldNumber)} → BUG-${padNum(newNumber)}：'
      '${plan.edits.length} 处引用 / ${plan.renames.length} 个文件改名（未落盘）',
    );
    if (collided) {
      logOut(
        '[dry-run] 作用域：${scope.baseRef}@${shortSha(scope.mergeBase)} 起 '
        '${scope.paths.length} 个文件；不碰 ${foreignBugFiles.join('、')}',
      );
    }
    for (final r in plan.renames) {
      logOut('  改名   ${r.from}  →  ${r.to}');
    }
    for (final e in plan.edits) {
      logOut('  改内容 ${e.path}:${e.line}');
      logOut('    -${clipLine(e.before)}');
      logOut('    +${clipLine(e.after)}');
    }
    logOut('[dry-run] 未写任何文件；去掉 --dry-run 才真正执行');
    return;
  }

  // —— 事后守卫的基线：范围外每个文件的 BUG-<old> 指纹。
  final Map<String, String> outsideBefore = bugRefFingerprint(oldNumber, outsidePaths);

  // —— 落盘：先改内容，再改名（改名后路径变了，内容已改完不受影响）。
  final re = bugRefPattern(oldNumber);
  final newPad = padNum(newNumber);
  final touched = plan.edits.map((BugRefEdit e) => e.path).toSet();
  for (final path in touched) {
    final f = File(path);
    final content = f.readAsStringSync();
    f.writeAsStringSync(content.replaceAllMapped(re, (Match m) => '${m[1]}${m[2]}$newPad'));
  }
  for (final r in plan.renames) {
    await renameTracked(r.from, r.to);
  }

  cmdReindex();

  // —— 守卫①：范围外文件一字未变。撞号时 base 侧那条合法同号 bug 就在这里面；
  //    这是把「静默的二次破坏」变成「显式失败」的那道断言。
  final Map<String, String> outsideAfter = bugRefFingerprint(oldNumber, outsidePaths);
  final drift = <String>[];
  for (final key in <String>{...outsideBefore.keys, ...outsideAfter.keys}) {
    final before = outsideBefore[key];
    final after = outsideAfter[key];
    if (before != after) drift.add('$key：$before → $after');
  }
  if (drift.isNotEmpty) {
    throw BugToolError(
      '🔴 改号误伤了范围外文件（本该一字不变），请立刻 `git checkout --` 回滚这些文件：\n  '
      '${drift.join('\n  ')}',
    );
  }

  // —— 守卫②：自校验旧号在**本次范围内**零残留。撞号态下范围外还留着别人那条的
  //    BUG-<old>，那是合法的，不算残留。
  //    范围里的路径要按改名结果映射一次，否则改完名的文件会因「旧路径已不存在」被跳过、
  //    残留检查形同虚设。
  //    🔴 范围**必须独立于 repoScanPaths 算**：effectivePaths ＝ repoScanPaths ∩ scope，
  //    拿它当自校验范围就把扫描器的盲区一并继承过来，守卫又和 bug 同盲。这里直接取
  //    git diff 出来的 scope.paths，只剔掉索引与别人那条 bug 文件。
  final Map<String, String> renameMap = <String, String>{
    for (final r in plan.renames) normalizeRelPath(r.from): r.to,
  };
  String afterRename(String p) => renameMap[normalizeRelPath(p)] ?? p;
  final residual = await findResidualRefs(
    oldNumber,
    paths: collided
        ? scope.paths.where((String p) => !isIndex(p) && !isForeign(p)).map(afterRename).toList()
        : null,
  );
  if (residual.isNotEmpty) {
    throw BugToolError(
      '改号后仍有 BUG-${padNum(oldNumber)} 残留，请人工处理：\n  '
      '${residual.join('\n  ')}',
    );
  }
  logOut(
    'renumber 完成：BUG-${padNum(oldNumber)} → BUG-${padNum(newNumber)}'
    '（${plan.edits.length} 处引用 / ${plan.renames.length} 个文件改名，自校验零残留）',
  );
  if (collided) {
    logOut(
      '  撞号态：范围外 ${outsidePaths.length} 个文件已断言一字未变'
      '（其中 ${outsideBefore.length} 个仍合法引用 BUG-${padNum(oldNumber)}）',
    );
  }
  for (final r in plan.renames) {
    logOut('  ${r.from} → ${r.to}');
  }
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

/// 守卫：校验 per-file 不变式 + 索引是否同步。返回非 0 表示有问题。
int cmdCheck() {
  var ok = true;
  // 1) docs/BUGS.md 不应再含任何 `## BUG-` 标题（全部已 per-file）。
  final indexContent = File(indexFile).readAsStringSync();
  if (RegExp(r'^##\s+BUG-\d+', multiLine: true).hasMatch(indexContent)) {
    logWarn('✗ $indexFile 仍含 `## BUG-NNN` 标题——应只放索引表，正文须在 $bugsDir/');
    ok = false;
  }
  // 2) 每个文件可解析、号唯一，且文件名的号与正文 H2 的号一致
  //    （只改文件名不改 H2 出过 CI 红；`renumber` 会一起改，别手改）。
  final entries = scanBugs();
  final byNum = <int, String>{};
  for (final e in entries) {
    final prev = byNum[e.number];
    if (prev != null) {
      logWarn(
        '✗ 号撞了：BUG-${e.paddedNum} 出现在 $prev 与 ${e.fileName}'
        '（跑 `dart run tool/bug.dart renumber <old> <new>` 改号）',
      );
      ok = false;
    }
    byNum[e.number] = e.fileName;
    final nameMatch = RegExp(r'^BUG-0*(\d+)').firstMatch(e.fileName);
    final nameNum = nameMatch == null ? null : int.tryParse(nameMatch.group(1)!);
    if (nameNum != null && nameNum != e.number) {
      logWarn(
        '✗ ${e.fileName} 文件名是 BUG-${padNum(nameNum)} 但正文 H2 是 BUG-${e.paddedNum}'
        '——两者必须一致（`renumber` 会同步改）',
      );
      ok = false;
    }
  }
  // 3) 索引是否同步（reindex 应为 no-op）。
  final beginIdx = indexContent.indexOf('BUGS-INDEX:BEGIN');
  final endIdx = indexContent.indexOf('BUGS-INDEX:END');
  if (beginIdx < 0 || endIdx < 0) {
    logWarn('✗ $indexFile 缺少索引 marker');
    ok = false;
  } else {
    final beginLineEnd = indexContent.indexOf('\n', beginIdx);
    final endLineStart = indexContent.lastIndexOf('\n', endIdx) + 1;
    final current = indexContent.substring(beginLineEnd + 1, endLineStart).trim();
    final expected = buildIndexTable(entries).trim();
    if (current != expected) {
      logWarn('✗ 索引与 $bugsDir/ 不同步——跑 `dart run tool/bug.dart reindex`');
      ok = false;
    }
  }
  if (ok) {
    logOut('check 通过：${entries.length} 条，号唯一，索引同步');
    return 0;
  }
  return 1;
}

/// 本地某个号被**别人**占用的一条证据。
class ForeignOccupancy {
  ForeignOccupancy(this.number, this.mine, this.others);

  final int number;

  /// 我这边承载该号的文件名。
  final String mine;

  /// 别的分支/工作区上承载**同一个号**的其它文件名（已排序）。
  final List<String> others;
}

/// 跨分支/跨工作区复核：我工作区里的每个号，是不是还被**别的文件名**占着。
///
/// 判据是「同一个号 + 不同文件名」，不是「同一个号出现在多个 ref 上」——后者是常态
/// （我的分支、origin 上的同一分支、develop 上都有同一份文件），报出来全是噪声。
///
/// [settledFileNames] 是 base（默认 origin/develop）上已有的 bug 文件名集合。
/// 只有**不在 base 上**的 bug 文件才算「我这条 PR 新引入、还能改号」的；已经并进 base
/// 的号是既成事实，陈旧分支上残留的同号文件是**那些分支** rebase 时要改的，不是我的活。
/// 不做这层过滤的实测后果：本仓 develop 上直接吐 72KB、200 多条历史噪声，信号全埋掉。
/// 传 null 表示拿不到 base（此时全量报，宁可吵也不漏）。
List<ForeignOccupancy> foreignOccupancies(
  List<BugEntry> mine,
  BugNumberOccupancy occupancy, {
  Set<String>? settledFileNames,
}) {
  final out = <ForeignOccupancy>[];
  for (final e in mine) {
    if (settledFileNames != null && settledFileNames.contains(e.fileName)) continue;
    final names = occupancy.fileNames[e.number];
    if (names == null) continue;
    final others = names.where((String n) => n != e.fileName).toList()..sort();
    if (others.isNotEmpty) out.add(ForeignOccupancy(e.number, e.fileName, others));
  }
  out.sort((ForeignOccupancy a, ForeignOccupancy b) => a.number.compareTo(b.number));
  return out;
}

/// base ref（`origin/develop` 等）上 `docs/bugs/` 里已有的文件名集合。
/// 拿不到（不在仓库 / 没有该 ref）返回 null——调用方据此退回「全量报」。
Future<Set<String>?> settledBugFileNames({String? baseRef}) async {
  final resolved = await resolveBaseRef(baseRef);
  if (resolved == null) return null;
  final r = await runGit(<String>[
    'ls-tree',
    '--name-only',
    '$resolved:$bugsDir',
  ], timeout: const Duration(seconds: 60));
  if (r == null || r.exitCode != 0) return null;
  return (r.stdout as String)
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toSet();
}

/// `check` 的完整版：本地不变式 + **跨分支/跨工作区占用复核**。
///
/// 退出码纪律：默认只让**本地不变式**决定红绿（和改造前完全一致，不会让 develop 因为
/// 一堆陈旧分支上的历史同号文件永久变红）；跨源占用只报不判死。开 PR 前想要硬门就加
/// `--strict`——那时你确实应该为「我的号还被别人占着」停下来。
Future<int> cmdCheckAll(List<String> args, {BranchScanner? scanner}) async {
  final strict = args.contains('--strict');
  final skipScan = args.contains('--no-scan');
  for (final a in args) {
    if (a.startsWith('--') && a != '--strict' && a != '--no-scan') {
      throw BugToolError('未知选项：$a（check 只认 --strict / --no-scan）');
    }
  }
  final localCode = cmdCheck();
  if (skipScan) {
    logWarn('⚠ --no-scan：本次没做跨分支/工作区复核，本地绿**不代表**号没被别人占。');
    return localCode;
  }

  final scan = await (scanner ?? scanBranchBugNumbers)();
  final warning = scan.warning;
  if (warning != null) logWarn(warning);

  final entries = scanBugs();
  final settled = await settledBugFileNames();
  final foreign = foreignOccupancies(entries, scan.occupancy, settledFileNames: settled);
  final inFlight = settled == null
      ? entries.length
      : entries.where((BugEntry e) => !settled.contains(e.fileName)).length;
  logOut('跨源复核：扫了 ${scan.scopeNote}，共 ${scan.occupancy.fileNames.length} 个号已被占用');
  logOut(
    settled == null
        ? '  ⚠ 拿不到 base（origin/develop 等）上的 bug 文件清单，本次对全部 '
            '${entries.length} 个本地号复核（会带上历史噪声）'
        : '  本工作区有 $inFlight 个号是 base 之外新引入的（其余已并入 base，'
            '陈旧分支上的同号是那些分支 rebase 时的活）',
  );
  if (foreign.isEmpty) {
    logOut('  这些号都没有被别的文件名占用');
    return localCode;
  }
  for (final f in foreign) {
    logWarn(
      '${strict ? '✗' : '⚠'} BUG-${padNum(f.number)}（我的 ${f.mine}）'
      '同时被 ${f.others.length} 个别的文件名占用：',
    );
    for (final name in f.others) {
      final src = (scan.occupancy.sources[name] ?? const <String>{}).toList()..sort();
      logWarn('    $name ← ${src.isEmpty ? '（来源未知）' : src.join(' / ')}');
    }
  }
  logWarn(
    '${strict ? '✗' : '⚠'} 共 ${foreign.length} 个号与在飞分支/工作区相撞——'
    '跑 `dart run tool/bug.dart renumber <old> <new>` 改号'
    '${strict ? '' : '（默认不改退出码；开 PR 前用 `check --strict` 当硬门）'}',
  );
  return strict ? 1 : localCode;
}

const String usage = '用法：dart run tool/bug.dart <new|renumber|reindex|migrate|check> ...\n'
    '  new <slug> [标题...]                 新建（跨本地+远端分支+本机所有工作区取下一个空号）\n'
    '  renumber <old> <new> [--base <ref>] [--dry-run]\n'
    '                                       改号：文件名 / 正文 H2 / 代码引用 / 测试名 /\n'
    '                                       测试文件名内嵌号 五类一把改 + reindex + 自校验\n'
    '  reindex                              重建 docs/BUGS.md 索引\n'
    '  migrate                              一次性：旧单文件拆 per-file\n'
    '  check [--strict] [--no-scan]         守卫：号唯一 / 文件名与 H2 一致 / 索引同步，\n'
    '                                       外加跨分支+工作区占用复核（--strict 让撞号也退非 0）\n'
    '\n'
    '取号的可见范围：所有本地分支 + 远端分支的 commit 树，**加上本机每个 git 工作区磁盘上\n'
    '还没提交的 `docs/bugs/*.md`**——后者是并发撞号的大头（`new` 写文件到 commit 之间隔着\n'
    '几十分钟到几小时）。号的判据是 bug 文件的文件名与正文 H2；代码里的 `BUG-NNN` 引用不算\n'
    '认领。这仍**不是**分布式锁：两个 agent 同一秒取号仍可能撞（TOCTOU 窗口已压到毫秒级）。\n'
    '网络不通时会显式警告并降级（本机分支与工作区仍然扫得到）。开 PR 前和每次 rebase 后重跑 check。\n'
    'renumber 在撞号态（base 上已有一条合法同号 bug）下会自动把替换范围框到本次改动引入的\n'
    '文件集，并断言范围外文件一字未变；base 默认取 origin/develop，用 --base 覆盖。';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    logWarn(usage);
    exit(2);
  }
  try {
    switch (args.first) {
      case 'new':
        await cmdNew(args.sublist(1));
      case 'renumber':
        await cmdRenumber(args.sublist(1));
      case 'reindex':
        cmdReindex();
      case 'migrate':
        cmdMigrate();
      case 'check':
        exit(await cmdCheckAll(args.sublist(1)));
      default:
        logWarn('未知子命令：${args.first}\n$usage');
        exit(2);
    }
  } on BugToolError catch (e) {
    logWarn('错误：${e.message}');
    exit(1);
  }
}

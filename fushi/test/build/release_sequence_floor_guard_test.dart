import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：发布序号必须走 `tool/release_sequence.sh`，且地板高过所有历史发布序号。
///
/// ## 起因
///
/// 序号来自 `git rev-list --count HEAD`。这个数只在「历史只增不减」的前提下
/// 单调；**重写历史会让它倒退**。2026-08-12 develop 被强推成重写后的历史，
/// 计数从 10546 掉到 9466，而当时已发布、已装到用户机器上的最大序号是 10405。
///
/// 序号同时喂三处单调比较，倒退把它们一起锁死：
///   1. Android `versionCode = versionCodeBase + 100 * seq + abiOffset`
///      → 比已装的小，系统安装器直接拒装；
///   2. app 内更新器按 `releaseSequence` 全序比较（update_checker_release.dart）
///      → 判远端「不比本机新」，用户永远收不到更新，且提示「已是最新版本」；
///   3. `tool/merge_update_manifest.py` 的「Never downgrades the advertised
///      top-level release」→ 新包根本写不进清单。
///
/// 三处守卫都没错——它们正确地拒绝了序号更小的包。错的是序号倒退。
///
/// ## 为什么这条守卫必须是静态扫描
///
/// 这类失效**没有任何构建期症状**：CI 全绿、包正常产出、release 正常发布，
/// 只有用户那侧「永远收不到更新」。等症状暴露时，坏包已经发出去了。
void main() {
  final Directory repoRoot = Directory('..');
  final File seqScript = File('../tool/release_sequence.sh');
  final Directory workflowsDir = Directory('../.github/workflows');

  /// 历史上真实出现过的最大序号。
  ///
  /// 10405 = 已发布到 `fushi-debug-rolling` 并装到用户机器上的最大值；
  /// 10546 = 重写前 develop 曾推上去（并跑过发布 workflow）的最大计数。
  /// 取两者较大者当下限：地板必须让**任何分支**的新序号都越过它，否则老装机
  /// 永远收不到更新。再次重写历史后要重新核这个数（见 docs/agent/build.md）。
  const int historicalMaxSequence = 10546;

  test('前置：序号脚本与 workflows 目录都在', () {
    expect(seqScript.existsSync(), isTrue,
        reason: '缺 ${seqScript.absolute.path}——序号算式的单一真相源没了，'
            '本守卫的全部断言失去对象。');
    expect(workflowsDir.existsSync(), isTrue,
        reason: 'expected ${workflowsDir.absolute.path}');
  });

  final String scriptText =
      seqScript.existsSync() ? seqScript.readAsStringSync() : '';

  test('脚本里能解析出 RELEASE_SEQUENCE_FLOOR', () {
    expect(_parseFloor(scriptText), isNotNull,
        reason: '在 tool/release_sequence.sh 里找不到形如 '
            'RELEASE_SEQUENCE_FLOOR=<数字> 的赋值。改了变量名就同步改这条守卫，'
            '否则下面「序号越过历史最大值」的断言会静默跑空。');
  });

  test('当前分支的序号越过历史最大值（计数被截断的 checkout 下自动跳过）', () {
    final int? floor = _parseFloor(scriptText);
    if (floor == null) return; // 上一条已经红了，这里不重复报。

    final ProcessResult count = Process.runSync(
      'git',
      <String>['rev-list', '--count', 'HEAD'],
      workingDirectory: repoRoot.path,
    );
    // 拿不到 git（沙箱里跑测试）时不制造假红。
    if (count.exitCode != 0) return;
    final int? commits = int.tryParse((count.stdout as String).trim());
    if (commits == null) return;

    // CI 的测试 job 用默认 fetch-depth（=1）checkout，计数会是个位数——那时测
    // 计数等于测 checkout 深度，不是测地板，跳过。
    //
    // **不用 `git rev-parse --is-shallow-repository` 当闸门**：那条只看
    // `.git/shallow` 标记在不在，一次历史很久以前的浅拉取会把标记永久留下，
    // 于是本条断言在本机永远静默跳过——守卫看着绿，其实一行都没守。
    // 这个坑是本守卫第一次变异实测（把地板改成 100）时暴露的：变异没被抓住。
    const int truncatedCheckoutCeiling = 1000;
    if (commits < truncatedCheckoutCeiling) return;

    expect(commits + floor, greaterThan(historicalMaxSequence),
        reason: '当前分支序号 = 提交计数 $commits + 地板 $floor = '
            '${commits + floor}，没有越过历史最大已发布序号 '
            '$historicalMaxSequence。从这个分支出的包：Android 装不上'
            '（versionCode 更小）、app 内更新器判「不比本机新」、清单守卫拒收。'
            '把 tool/release_sequence.sh 里的 RELEASE_SEQUENCE_FLOOR 抬到'
            '足够高，并同步更新本守卫的 historicalMaxSequence。');
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

  /// 走共享脚本的赋值点。
  final List<String> viaScript = <String>[];

  /// 绕过地板的裸赋值点。
  final List<String> bareAssignments = <String>[];

  const String scriptCall =
      'RELEASE_SEQUENCE=' r'$(bash tool/release_sequence.sh)';
  const String bareCall = 'RELEASE_SEQUENCE=' r'$(git rev-list';

  for (final File workflow in workflows) {
    final String name = workflow.uri.pathSegments.last;
    final List<String> lines = workflow.readAsLinesSync();
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].contains(scriptCall)) viaScript.add('$name:${i + 1}');
      if (lines[i].contains(bareCall)) bareAssignments.add('$name:${i + 1}');
    }
  }

  test('守卫没跑空：扫到了走共享脚本的序号赋值点', () {
    expect(workflows, isNotEmpty, reason: '一个 workflow 都没扫到');
    expect(viaScript, isNotEmpty,
        reason: '一处 `$scriptCall` 都没扫到。要么 workflow 改了写法，要么本守卫'
            '的匹配串过期了——无论哪种，下面那条「无裸赋值」的断言此刻都是空转，'
            '先修守卫再谈绿。');
  });

  test('workflow 里没有绕过地板的裸 rev-list 赋值', () {
    expect(bareAssignments, isEmpty,
        reason: '这些地方直接用 `git rev-list --count HEAD` 当序号，绕过了 '
            'tool/release_sequence.sh 的一次性地板。历史一旦被重写，这些点算出的'
            '序号会倒退到已发布序号之下，用户侧表现为「永远收不到更新 / 装不上包」，'
            '而 CI 全绿：\n'
            '${bareAssignments.map((String w) => "  $w").join("\n")}');
  });

  test('调用共享脚本的 step 不得设 working-directory（BUG-1596）', () {
    // `bash tool/release_sequence.sh` 是仓库根相对路径。step 一旦设了
    // working-directory（如 release.yml 的 Resolve step 曾设 `fushi`），脚本会被
    // 解析成不存在的 `fushi/tool/`，bash 报 No such file → exit 127，整条发布
    // workflow 首步即挂。BUG-1586 落地当天没人踩到，是因为 push 自动发布恰好
    // 停用、手动 dispatch 又默认 skip_tests——恢复自动发布首跑即红（BUG-1596）。
    //
    // 判定方式：从调用行向上走到所属 step 的起始行（`- name:` / `- uses:`），
    // 途中任何 step 级 `working-directory:` 键都算违规。step 键在 YAML 里必然
    // 排在 `run:` 块之前，所以向上扫描足以覆盖；run 块正文是 bash，不会出现
    // 顶格的 `- name:` 干扰边界判定。
    final List<String> offenders = <String>[];
    for (final File workflow in workflows) {
      final String name = workflow.uri.pathSegments.last;
      final List<String> lines = workflow.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (!lines[i].contains(scriptCall)) continue;
        for (int j = i; j >= 0; j--) {
          final String trimmed = lines[j].trim();
          if (trimmed.startsWith('- name:') || trimmed.startsWith('- uses:')) {
            break;
          }
          if (trimmed.startsWith('working-directory:')) {
            offenders.add('$name:${j + 1}（调用点 $name:${i + 1}）');
            break;
          }
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '这些 step 给根相对的 `bash tool/release_sequence.sh` 设了 '
            'working-directory，脚本会解析到不存在的子目录路径，step 直接 '
            'exit 127（BUG-1596）。要么去掉 working-directory 并把 step 里其余'
            '相对路径改成根相对（对齐 release-desktop.yml 的同名 step），要么'
            '别在这个 step 里调共享序号脚本：\n'
            '${offenders.map((String w) => "  $w").join("\n")}');
  });
}

/// 从脚本正文里解析 `RELEASE_SEQUENCE_FLOOR=<数字>`。
///
/// 不用正则：这文件里所有匹配都走字面量前缀，免得转义在不同工具链之间被吃掉
/// 一层，把守卫悄悄变成空转。
int? _parseFloor(String scriptText) {
  const String key = 'RELEASE_SEQUENCE_FLOOR=';
  for (final String line in scriptText.split('\n')) {
    final String trimmed = line.trim();
    if (trimmed.startsWith('#')) continue;
    if (!trimmed.startsWith(key)) continue;
    return int.tryParse(trimmed.substring(key.length).trim());
  }
  return null;
}

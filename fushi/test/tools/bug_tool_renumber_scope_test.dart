// 行为测试：`tool/bug.dart renumber` 在**撞号态**下的作用域框定。
//
// 下面两个路径只是临时 git 仓库里的 fixture，不是本测试守的东西（守的是
// `tool/bug.dart`）；不声明的话，每个走 BUG 流程的 PR 都会因 reindex 改了真仓库的
// `docs/BUGS.md` 把本套件（起 git 子进程，单跑数分钟）拉进推送前检查。
// tests-for-changes-ignore: docs/BUGS.md docs/bugs
//
// 背景（PR#607 那次改了 66 处手工改号）：撞号是每个 PR 合并前的必经步骤，而 renumber
// 恰恰在撞号态下不可用。两个实测缺陷：
//   ① `locateBugFile` 在 old 号同时存在于 PR 侧与 base 侧时直接抛错退出——而撞号
//      **正是唯一需要 renumber 的场景**，改号根本进不去。
//   ② 🔴 全仓盲替换会改坏 base 侧那条**合法的同号 bug**（撞号的定义就是 base 上本来
//      就有一条占着这个号）。实测对应关系：1246→helper-version-drift、
//      1262/1263→anki-dedup、1264→popup-perdict。盲替换把这些与本 PR 完全无关的既有
//      条目一起改号，制造「base 侧 bug 凭空消失 / 引用指向不存在的号」的二次破坏，
//      而事后 `bug.dart check` 仍报通过（号仍唯一、索引仍同步），**不会报警**。
//
// 这里用真 git 仓库 fixture 复现撞号态，双向断言：
//   · 误伤侧：base 侧那条的文件名 / 正文 H2 / 全部引用**一字未变**（逐字节比对）；
//   · 完整性侧：PR 侧那条的**五类**位置全部改到——文件名、正文 H2、代码注释引用、
//     测试与 group 名、**测试文件名内嵌号**（最容易漏的一类）；
//   · 同形字串侧：`TODO-<old>`、SHA-256 十六进制里恰好出现的数字、文档行号区间
//     （`:1242-9246`）一律不动；
//   · 作用域算不出来时**必须硬失败**，不许静默退回全仓盲替换。
//
// ignore_for_file: always_use_package_imports

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/bug.dart' as bug;

void git(Directory dir, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: dir.path);
  if (r.exitCode != 0) {
    fail('git ${args.join(' ')} 在 ${dir.path} 失败：${r.stdout}${r.stderr}');
  }
}

void writeFile(Directory root, String rel, String content) {
  final f = File('${root.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

void writeBytes(Directory root, String rel, List<int> bytes) {
  final f = File('${root.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}

String readFile(Directory root, String rel) =>
    File('${root.path}/$rel').readAsStringSync();

bool exists(Directory root, String rel) =>
    File('${root.path}/$rel').existsSync();

const String indexShell =
    '# Bug 跟踪\n\n---\n\n'
    '<!-- BUGS-INDEX:BEGIN -->\n<!-- BUGS-INDEX:END -->\n';

// —— base 侧（develop）那条合法的 BUG-9246，以及所有指向它的引用。改号后必须一字不变。
const String baseBugDoc =
    '## BUG-9246 · helper 版本漂移\n'
    '- **[x] ① 已修复** — abc1234\n'
    '- **[x] ② 已加自动化测试** — fushi/test/tools/helper_version_drift_bug_9246_test.dart\n';
const String baseLib =
    '// 修 BUG-9246：helper 版本漂移，根因在 helper.dart:88。\n'
    'void helper() {}\n';
const String baseTest =
    'void main() {\n'
    "  group('BUG-9246 helper 版本漂移', () {\n"
    "    test('BUG-9246 版本一致', () {});\n"
    '  });\n'
    '}\n';
const String baseDoc =
    '# 构建\n\n见 [BUG-9246](../bugs/BUG-9246-helper-version-drift.md)。\n';

/// base 侧全部文件（相对路径 → 内容）。改号后逐个比对。
const Map<String, String> baseSideFiles = <String, String>{
  'docs/bugs/BUG-9246-helper-version-drift.md': baseBugDoc,
  'lib/helper.dart': baseLib,
  'fushi/test/tools/helper_version_drift_bug_9246_test.dart': baseTest,
  'docs/agent/build.md': baseDoc,
};

// —— PR 侧那条 BUG-9246 及其五类位置。
const String prBugDoc =
    '## BUG-9246 · 阅读器恢复位置丢失\n'
    '- **[x] ① 已修复** — def5678\n'
    '- **[x] ② 已加自动化测试** — fushi/test/reader/reader_restore_bug_9246_test.dart\n';
const String prLib =
    '// 见 BUG-9246：恢复位置在 restore.dart:120 被覆盖。\n'
    'void restore() {}\n';
const String prTest =
    'void main() {\n'
    "  group('BUG-9246 阅读器恢复位置', () {\n"
    "    test('BUG-9246 恢复后偏移不丢', () {});\n"
    '  });\n'
    '}\n';

/// 同形字串语料：他域编号 / SHA-256 十六进制 / 文档行号区间。一个都不许改。
const String lookalikeCorpus =
    '// TODO-9246 是待办编号，不是 bug 号。\n'
    '// sha256: 3f9c9246ab7d0e5592468899aabbccddeeff00112233445566778899aabbccdd\n'
    '// 行号区间：docs/agent/build.md:1242-9246 与 9246-9250。\n'
    '// 词尾同形：debug-9246 不是引用。\n'
    '// 真正的引用只有这一处：BUG-9246。\n';

/// 建「base 分支已有 BUG-9246，PR 分支又新增一条 BUG-9246」的真撞号 fixture。
///
/// [baseBranch] 决定基线分支名：用 `develop` 时 bug.dart 能自动找到基线；
/// 用别的名字则三条默认候选（origin/develop、develop、main、master…）全落空，
/// 用来验证「作用域算不出来必须硬失败」。
/// [touchBaseBugFile] 让 PR 顺手改一下 base 侧那条 bug 文件（补一行备注）——
/// 这会把它拽进 `git diff` 的改动集里。此时「在不在作用域内」已经不足以保护它，
/// 必须靠「绝不改不是自己引入的那条 bug 文件」这条独立不变式兜底。
Directory makeCollisionFixture(
  List<Directory> temps, {
  String baseBranch = 'develop',
  bool commitPrSide = true,
  bool touchBaseBugFile = false,
  Map<String, String> extraPrFiles = const <String, String>{},
}) {
  final root = Directory.systemTemp.createTempSync('bug_collide_');
  temps.add(root);
  git(root, <String>['init', '-q', '-b', baseBranch, '.']);
  git(root, <String>['config', 'user.email', 'fixture@example.com']);
  git(root, <String>['config', 'user.name', 'fixture']);
  git(root, <String>['config', 'commit.gpgsign', 'false']);

  writeFile(root, 'docs/BUGS.md', indexShell);
  baseSideFiles.forEach(
    (String rel, String content) => writeFile(root, rel, content),
  );
  git(root, <String>['add', '-A']);
  git(root, <String>['commit', '-qm', 'base: BUG-9246 helper-version-drift']);

  git(root, <String>['checkout', '-q', '-b', 'feature']);
  writeFile(root, 'docs/bugs/BUG-9246-reader-restore.md', prBugDoc);
  writeFile(root, 'fushi/lib/src/reader/restore.dart', prLib);
  writeFile(
    root,
    'fushi/test/reader/reader_restore_bug_9246_test.dart',
    prTest,
  );
  writeFile(root, 'fushi/lib/src/reader/notes.dart', lookalikeCorpus);
  extraPrFiles.forEach(
    (String rel, String content) => writeFile(root, rel, content),
  );
  if (touchBaseBugFile) {
    writeFile(
      root,
      'docs/bugs/BUG-9246-helper-version-drift.md',
      '$baseBugDoc- **备注**：本 PR 顺手补的一行。\n',
    );
  }
  if (commitPrSide) {
    git(root, <String>['add', '-A']);
    git(root, <String>['commit', '-qm', 'feat: BUG-9246 reader-restore']);
  }
  bug.bugRepoRoot = root.path;
  return root;
}

bug.BranchScanner stubScanner(Set<int> numbers) =>
    () async =>
        bug.BranchScan(bug.BranchScanStatus.fresh, numbers, '', refCount: 2);

void main() {
  late List<String> out;
  late List<String> warn;
  final List<Directory> temps = <Directory>[];

  /// 把一条异步 bug.dart 命令挪到后台 isolate 里跑（以当前测试设的 fixture 为根），
  /// 见 [bug.runBugCommandIsolated]：faster-testing 下各 suite 共用一条 UI 线程，
  /// 命令里几十次 await git 子进程留在这条线程上就会被邻居 suite 的同步代码拖住。
  Future<T> runBug<T>(Future<T> Function() command) =>
      bug.runBugCommandIsolated(bug.bugRepoRoot!, command);

  /// 每条测试的 body 跑在自己的 [bug.runInBugRepoScope] 里：fixture 根由 body 内设、
  /// 输出 sink 取 body 开跑时这条测试自己的 [out] / [warn]。
  ///
  /// 超时给默认的 2 倍（60 秒），量过的：本机空载每条 0.3~3 秒；faster-testing 下与源码
  /// 扫描类守卫同进程（它们一段同步代码就是几秒，期间整条 UI 线程归它们）时，命令已挪进
  /// isolate 后 p50 1.8 秒、p90 8.5 秒、最慢 33.8 秒（4 次命令往返 = 8 次回 UI 线程排队）；
  /// 挪之前同一负载下最慢 121 秒。等的是邻居而不是本测试自己的活，真挂死仍会在 60 秒报出。
  void repoTest(String description, dynamic Function() body) {
    test(description, () {
      final List<String> myOut = out;
      final List<String> myWarn = warn;
      return bug.runInBugRepoScope(
        body,
        logOut: myOut.add,
        logWarn: myWarn.add,
      );
    }, timeout: const Timeout.factor(2));
  }

  setUp(() {
    out = <String>[];
    warn = <String>[];
  });

  // 不复位任何 bug.dart 状态：仓库根与输出 sink 绑在每条测试 body 自己的 zone 上
  // （[repoTest]），超时后仍在跑的 body 碰不到真仓库，也碰不到下一条测试的 fixture。
  tearDown(() {
    for (final d in temps) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows 上 git 句柄偶尔滞留，清理失败不影响断言。
      }
    }
    temps.clear();
  });

  group('缺陷①：撞号态下 renumber 必须能跑起来', () {
    repoTest('old 号同时存在于 PR 侧与 base 侧时不再抛错退出，且按 PR 侧那一份消歧', () async {
      final root = makeCollisionFixture(temps);

      // 撞号态确实成立：两份文件都占 9246。
      expect(bug.locateBugFiles(9246), hasLength(2));
      // 旧实现在这里就退出了（locateBugFile 命中多个直接抛）。
      expect(() => bug.locateBugFile(9246), throwsA(isA<bug.BugToolError>()));

      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      // 改的是 PR 侧那一份。
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-9246-reader-restore.md'), isFalse);
      // base 侧那一份还在，名字没动。
      expect(
        exists(root, 'docs/bugs/BUG-9246-helper-version-drift.md'),
        isTrue,
      );
    });
  });

  group('缺陷②：base 侧同号条目一字未变', () {
    repoTest('改号后 base 侧四个文件逐字节相同，文件名也没动', () async {
      final root = makeCollisionFixture(temps);
      final Map<String, List<int>> before = <String, List<int>>{
        for (final rel in baseSideFiles.keys)
          rel: File('${root.path}/$rel').readAsBytesSync(),
      };

      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      for (final rel in baseSideFiles.keys) {
        expect(exists(root, rel), isTrue, reason: 'base 侧 $rel 被改名或删除了');
        expect(
          File('${root.path}/$rel').readAsBytesSync(),
          before[rel],
          reason: 'base 侧 $rel 内容被改动——这就是「develop 侧 BUG 凭空消失」的二次破坏',
        );
      }
      // 正文 H2 与所有引用都还指向 9246。
      expect(
        readFile(root, 'docs/bugs/BUG-9246-helper-version-drift.md'),
        startsWith('## BUG-9246 · '),
      );
      expect(readFile(root, 'lib/helper.dart'), contains('BUG-9246'));
      expect(
        readFile(root, 'docs/agent/build.md'),
        contains('[BUG-9246](../bugs/BUG-9246-helper-version-drift.md)'),
      );
      expect(
        readFile(
          root,
          'fushi/test/tools/helper_version_drift_bug_9246_test.dart',
        ),
        contains("group('BUG-9246 helper 版本漂移'"),
      );
      // git 视角：base 侧文件一个都没进改动集。
      final status = Process.runSync('git', <String>[
        'status',
        '--porcelain',
      ], workingDirectory: root.path);
      for (final rel in baseSideFiles.keys) {
        expect(
          status.stdout as String,
          isNot(contains(rel)),
          reason: 'base 侧 $rel 出现在工作区改动里',
        );
      }
    });

    repoTest('base 侧条目在改号后仍在索引里，且 check 通过', () async {
      final root = makeCollisionFixture(temps);
      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      final index = readFile(root, 'docs/BUGS.md');
      expect(
        index,
        contains('[BUG-9246](bugs/BUG-9246-helper-version-drift.md)'),
        reason: 'base 侧那条不能从索引里消失',
      );
      expect(index, contains('[BUG-9250](bugs/BUG-9250-reader-restore.md)'));
      expect(bug.cmdCheck(), 0);
    });

    repoTest('base 侧那条即使被本 PR 顺手改过（落进了 diff 作用域），也绝不改号', () async {
      final root = makeCollisionFixture(temps, touchBaseBugFile: true);
      const String basePath = 'docs/bugs/BUG-9246-helper-version-drift.md';
      final List<int> before = File('${root.path}/$basePath').readAsBytesSync();
      // 前提成立：它确实在本次改动集里（不是靠「不在作用域」被动躲过去的）。
      final scope = await runBug(() => bug.resolveRenumberScope());
      expect(
        scope.contains(basePath),
        isTrue,
        reason: 'fixture 没造出「base 侧 bug 文件也在 diff 里」的前提',
      );

      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      expect(exists(root, basePath), isTrue, reason: '不是自己引入的 bug 文件被改名了');
      expect(File('${root.path}/$basePath').readAsBytesSync(), before);
      expect(readFile(root, basePath), startsWith('## BUG-9246 · '));
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isTrue);
      expect(bug.cmdCheck(), 0);
    });

    repoTest('reindex 幂等：改号后再跑一次索引不变', () async {
      final root = makeCollisionFixture(temps);
      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );
      final afterRenumber = readFile(root, 'docs/BUGS.md');
      bug.cmdReindex();
      expect(readFile(root, 'docs/BUGS.md'), afterRenumber);
      expect(bug.cmdCheck(), 0);
    });
  });

  group('完整性：PR 侧五类位置全部改到', () {
    repoTest('文件名 / 正文 H2 / 代码引用 / 测试与 group 名 / 测试文件名内嵌号', () async {
      final root = makeCollisionFixture(temps);
      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      // ① 文件名
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isTrue);
      // ② 正文 H2（守卫 bugs_per_file_guard_test 扫这里，只改文件名会 CI 红）
      expect(
        readFile(root, 'docs/bugs/BUG-9250-reader-restore.md'),
        startsWith('## BUG-9250 · '),
      );
      // ③ 代码注释引用
      expect(
        readFile(root, 'fushi/lib/src/reader/restore.dart'),
        contains('见 BUG-9250：'),
      );
      expect(
        readFile(root, 'fushi/lib/src/reader/restore.dart'),
        isNot(contains('BUG-9246')),
      );
      // ④ 测试名与 group 名
      final prTestNow = readFile(
        root,
        'fushi/test/reader/reader_restore_bug_9250_test.dart',
      );
      expect(prTestNow, contains("group('BUG-9250 阅读器恢复位置'"));
      expect(prTestNow, contains("test('BUG-9250 恢复后偏移不丢'"));
      // ⑤ 测试文件名内嵌号（最容易漏的一类）
      expect(
        exists(root, 'fushi/test/reader/reader_restore_bug_9250_test.dart'),
        isTrue,
      );
      expect(
        exists(root, 'fushi/test/reader/reader_restore_bug_9246_test.dart'),
        isFalse,
      );
      // bug 正文里指向测试文件的路径也跟着改
      expect(
        readFile(root, 'docs/bugs/BUG-9250-reader-restore.md'),
        contains('fushi/test/reader/reader_restore_bug_9250_test.dart'),
      );
    });
  });

  group('同形字串不被误改', () {
    repoTest('TODO-<old> / SHA 十六进制 / 行号区间 / debug-<old> 全部原样', () async {
      final root = makeCollisionFixture(temps);
      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      final notes = readFile(root, 'fushi/lib/src/reader/notes.dart');
      expect(notes, contains('TODO-9246'), reason: '他域编号被改了');
      expect(
        notes,
        contains(
          '3f9c9246ab7d0e5592468899aabbccddeeff00112233445566778899aabbccdd',
        ),
        reason: 'SHA-256 十六进制里的数字被改了',
      );
      expect(
        notes,
        contains('docs/agent/build.md:1242-9246'),
        reason: '行号区间被改了',
      );
      expect(notes, contains('9246-9250'), reason: '行号区间被改了');
      expect(notes, contains('debug-9246'), reason: '词尾同形被误伤');
      // 真正的引用改到了，且只改了这一处。
      expect(notes, contains('BUG-9250。'));
      expect(RegExp(r'BUG-9246').allMatches(notes), isEmpty);
    });
  });

  group('作用域算不出来时必须硬失败（不许静默退回全仓盲替换）', () {
    repoTest('撞号 + 找不到基线 ref → 抛错，且一个文件都不动', () async {
      final root = makeCollisionFixture(temps, baseBranch: 'no-such-base');
      final Map<String, List<int>> before = <String, List<int>>{
        for (final rel in baseSideFiles.keys)
          rel: File('${root.path}/$rel').readAsBytesSync(),
      };

      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '9246',
            '9250',
          ], scanner: stubScanner(<int>{9246})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('--base'),
          ),
        ),
      );

      for (final rel in baseSideFiles.keys) {
        expect(File('${root.path}/$rel').readAsBytesSync(), before[rel]);
      }
      expect(exists(root, 'docs/bugs/BUG-9246-reader-restore.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isFalse);
    });

    repoTest('显式 --base 能救回来', () async {
      final root = makeCollisionFixture(temps, baseBranch: 'no-such-base');
      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
          '--base',
          'no-such-base',
        ], scanner: stubScanner(<int>{9246})),
      );
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isTrue);
      expect(readFile(root, 'lib/helper.dart'), contains('BUG-9246'));
    });

    repoTest('撞号但作用域为空（改动全在基线上、什么都没动）→ 抛错', () async {
      final root = Directory.systemTemp.createTempSync('bug_empty_scope_');
      temps.add(root);
      git(root, <String>['init', '-q', '-b', 'develop', '.']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      writeFile(root, 'docs/BUGS.md', indexShell);
      writeFile(root, 'docs/bugs/BUG-9246-helper-version-drift.md', baseBugDoc);
      writeFile(root, 'docs/bugs/BUG-9246-reader-restore.md', prBugDoc);
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'both on base']);
      bug.bugRepoRoot = root.path;

      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '9246',
            '9250',
          ], scanner: stubScanner(<int>{9246})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('撞号'),
          ),
        ),
      );
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isFalse);
    });
  });

  group('未提交的 PR 侧新条目（刚 `new` 出来还没 commit）', () {
    repoTest('untracked 也算本次改动引入，照样能消歧并改到五类位置', () async {
      final root = makeCollisionFixture(temps, commitPrSide: false);
      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isTrue);
      expect(
        exists(root, 'fushi/test/reader/reader_restore_bug_9250_test.dart'),
        isTrue,
      );
      expect(readFile(root, 'lib/helper.dart'), baseLib);
      expect(bug.cmdCheck(), 0);
    });
  });

  group('--dry-run 在撞号态下也不落盘', () {
    repoTest('打印作用域与逐行改动，但一个字节都不写', () async {
      final root = makeCollisionFixture(temps);
      final beforeBase = readFile(root, 'lib/helper.dart');
      final beforePr = readFile(root, 'docs/bugs/BUG-9246-reader-restore.md');

      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
          '--dry-run',
        ], scanner: stubScanner(<int>{9246})),
      );

      final printed = out.join('\n');
      expect(printed, contains('[dry-run]'));
      expect(
        printed,
        contains('docs/bugs/BUG-9246-helper-version-drift.md'),
        reason: 'dry-run 要显式说明 base 侧那份不碰',
      );
      expect(
        printed,
        contains('fushi/test/reader/reader_restore_bug_9246_test.dart'),
      );
      expect(readFile(root, 'lib/helper.dart'), beforeBase);
      expect(readFile(root, 'docs/bugs/BUG-9246-reader-restore.md'), beforePr);
      expect(exists(root, 'docs/bugs/BUG-9250-reader-restore.md'), isFalse);
    });
  });

  // 超时那条测试的 body 不会被取消：package:test 照样跑 tearDown 和下一条测试，它还在等的
  // git 子进程回来后接着往下跑。根要是进程级全局，它就会落到复位后的 cwd（真仓库）或下一条
  // 的 fixture 上（实测：超时那条的 `git mv` 打红了下一条）。这里钉住作用域隔离本身。
  group('仓库根作用域：超时残留的 body 碰不到别处', () {
    test('作用域外读为 null（CLI = cwd）、设值直接抛错', () {
      expect(bug.bugRepoRoot, isNull);
      expect(() => bug.bugRepoRoot = '/tmp/x', throwsStateError);
    });

    test('作用域内没设根就读，抛错而不是回落到进程 cwd', () {
      bug.runInBugRepoScope(
        () {
          expect(() => bug.bugRepoRoot, throwsStateError);
          expect(() => bug.repoPath('docs/BUGS.md'), throwsStateError);
        },
        logOut: (_) {},
        logWarn: (_) {},
      );
    });

    test('两个并发作用域交错 await，各自只看见自己的根与 sink', () async {
      final Completer<void> laterSetUp = Completer<void>();
      final List<String> outA = <String>[];
      final List<String> outB = <String>[];
      // A 扮演「已超时、还在等 git」的 body：B（下一条测试）设好自己的根之后它才醒。
      final Future<String?> a = bug.runInBugRepoScope(
        () async {
          bug.bugRepoRoot = '/fixture/a';
          await laterSetUp.future;
          bug.logOut('from a');
          return bug.bugRepoRoot;
        },
        logOut: outA.add,
        logWarn: outA.add,
      );
      await bug.runInBugRepoScope(
        () async {
          bug.bugRepoRoot = '/fixture/b';
          laterSetUp.complete();
          await Future<void>.delayed(Duration.zero);
          bug.logOut('from b');
          expect(bug.bugRepoRoot, '/fixture/b');
        },
        logOut: outB.add,
        logWarn: outB.add,
      );
      expect(await a, '/fixture/a');
      expect(outA, <String>['from a']);
      expect(outB, <String>['from b']);
      expect(bug.bugRepoRoot, isNull, reason: '作用域外不受任何作用域里的设值影响');
    });
  });

  group('范围外指纹守卫本身', () {
    repoTest('bugRefFingerprint 只统计有命中的文件，内容与文件名分开计数', () {
      final root = Directory.systemTemp.createTempSync('bug_fp_');
      temps.add(root);
      writeFile(root, 'a.dart', '// BUG-9246 与 BUG-9246 两处\n');
      writeFile(root, 'bug_9246_test.dart', '// 无正文引用\n');
      writeFile(root, 'clean.dart', '// TODO-9246 不算\n');
      bug.bugRepoRoot = root.path;

      final fp = bug.bugRefFingerprint(9246, <String>[
        'a.dart',
        'bug_9246_test.dart',
        'clean.dart',
      ]);
      expect(fp['a.dart'], '2:0');
      expect(fp['bug_9246_test.dart'], '0:1');
      expect(fp.containsKey('clean.dart'), isFalse);
    });
  });

  // —— BUG-1437：替换与自校验共用同一副「瞎眼镜」。
  //    旧 `looksTextual` 要求「有点号 + 扩展名在白名单里」，实测 `.gitattributes` /
  //    `third_party/m_extension_server/UPSTREAM` / `LICENSE` / `Makefile` 全判成非文本；
  //    而 `findResidualRefs` 与 `buildRenumberPlan` 吃的是同一个 `repoScanPaths()`，
  //    于是漏改的文件在自校验里同样看不见——实测 9 处引用只落了 7 处，工具仍打印
  //    「自校验零残留」。取号撞了人能发现，自校验骗人没人会去复查。
  group('BUG-1437：扫描口径 + 自校验独立遍历', () {
    const Map<String, String> oddNameFiles = <String, String>{
      'third_party/m_extension_server/UPSTREAM': '上游基线。修复记录见 BUG-9246。\n',
      '.gitattributes': '# 由 BUG-9246 引入的 CRLF 规则\n*.dart text\n',
      'LICENSE': 'MIT License\n\n历史豁免见 BUG-9246。\n',
      'Makefile': 'all:\n\t@echo BUG-9246\n',
    };

    repoTest('无扩展名 / 前导点文件里的引用会被真正改到（白名单判据看不见它们）', () async {
      final root = makeCollisionFixture(temps, extraPrFiles: oddNameFiles);

      // 前提成立：这四类路径在旧判据下全是「非文本」，现在必须判成文本。
      for (final rel in oddNameFiles.keys) {
        expect(bug.looksTextual(rel), isTrue, reason: '$rel 又被判成非文本了');
      }

      await runBug(
        () => bug.cmdRenumber(<String>[
          '9246',
          '9250',
        ], scanner: stubScanner(<int>{9246})),
      );

      for (final rel in oddNameFiles.keys) {
        expect(
          readFile(root, rel),
          contains('BUG-9250'),
          reason: '$rel 里的引用没改到',
        );
        expect(
          readFile(root, rel),
          isNot(contains('BUG-9246')),
          reason: '$rel 里还留着旧号',
        );
      }
    });

    repoTest('替换扫描器漏掉一类文件时，自校验必须报红——不许打印「零残留」', () async {
      // 模拟「扩展名判据又退化了一次」：引用落在一个扩展名进了二进制黑名单、
      // 内容其实是纯文本的文件里。替换侧按黑名单跳过它；自校验走独立遍历 +
      // 字节嗅探，必须照样看得见。守卫与被守对象共用扫描器时这里是假绿。
      makeCollisionFixture(
        temps,
        extraPrFiles: <String, String>{
          'docs/notes.bin': '这一行引用 BUG-9246，替换侧看不见它。\n',
        },
      );
      expect(
        bug.looksTextual('docs/notes.bin'),
        isFalse,
        reason: '前提：替换侧确实跳过它',
      );

      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '9246',
            '9250',
          ], scanner: stubScanner(<int>{9246})),
        ),
        throwsA(
          isA<bug.BugToolError>()
              .having(
                (bug.BugToolError e) => e.message,
                'message',
                contains('残留'),
              )
              .having(
                (bug.BugToolError e) => e.message,
                'message',
                contains('docs/notes.bin'),
              ),
        ),
      );
      expect(out.join('\n'), isNot(contains('自校验零残留')));
    });

    repoTest('非撞号态（全量口径）同样看得见漏改', () async {
      final root = Directory.systemTemp.createTempSync('bug_residual_full_');
      temps.add(root);
      git(root, <String>['init', '-q', '-b', 'develop', '.']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      writeFile(root, 'docs/BUGS.md', indexShell);
      writeFile(root, 'docs/bugs/BUG-9246-reader-restore.md', prBugDoc);
      writeFile(root, 'docs/notes.bin', '漏网的引用 BUG-9246。\n');
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'single BUG-9246']);
      bug.bugRepoRoot = root.path;

      // 前提：这是非撞号态（只有一份同号文件），自校验走全量 residualScanPaths()。
      expect(bug.locateBugFiles(9246), hasLength(1));

      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '9246',
            '9250',
          ], scanner: stubScanner(<int>{9246})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('残留'),
          ),
        ),
      );
    });

    repoTest('findResidualRefs 的枚举不复用 repoScanPaths（这一条直接盯独立性）', () async {
      final root = Directory.systemTemp.createTempSync('bug_residual_indep_');
      temps.add(root);
      git(root, <String>['init', '-q', '-b', 'develop', '.']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      writeFile(root, 'docs/notes.bin', '引用 BUG-9246 在这里。\n');
      writeFile(root, 'UPSTREAM', '引用 BUG-9246 也在这里。\n');
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'seed']);
      bug.bugRepoRoot = root.path;

      final scan = await runBug(() => bug.repoScanPaths());
      expect(
        scan,
        isNot(contains('docs/notes.bin')),
        reason: '前提：替换侧按黑名单跳过 .bin',
      );
      final residual = await runBug(() => bug.findResidualRefs(9246));
      expect(
        residual,
        contains('docs/notes.bin:1'),
        reason: '自校验复用了 repoScanPaths 就会在这里瞎掉',
      );
      expect(residual, contains('UPSTREAM:1'));
    });

    repoTest('真二进制文件既不被改、也不被误报成残留', () async {
      final root = Directory.systemTemp.createTempSync('bug_residual_bin_');
      temps.add(root);
      git(root, <String>['init', '-q', '-b', 'develop', '.']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      // 头部就有 NUL：即使字节里出现 `BUG-9246`，也不是引用载体。
      writeBytes(root, 'assets/blob', <int>[
        0x89,
        0x50,
        0x00,
        0x01,
        ...'BUG-9246'.codeUnits,
      ]);
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'binary blob']);
      bug.bugRepoRoot = root.path;

      expect(bug.looksTextual('assets/blob'), isFalse);
      expect(await runBug(() => bug.findResidualRefs(9246)), isEmpty);
    });

    repoTest('非 UTF-8 文本（GBK 等）里的 ASCII 引用也算残留', () async {
      final root = Directory.systemTemp.createTempSync('bug_residual_gbk_');
      temps.add(root);
      git(root, <String>['init', '-q', '-b', 'develop', '.']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      // GBK 的「中文」+ ASCII 引用；readAsStringSync 会抛 FormatException，
      // 旧实现在那里直接 continue，等于对这类文件也瞎。
      writeBytes(root, 'legacy.txt', <int>[
        0xD6,
        0xD0,
        0xCE,
        0xC4,
        0x20,
        ...'BUG-9246'.codeUnits,
        0x0A,
      ]);
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'gbk']);
      bug.bugRepoRoot = root.path;

      expect(
        await runBug(() => bug.findResidualRefs(9246)),
        contains('legacy.txt:1'),
      );
    });
  });
}

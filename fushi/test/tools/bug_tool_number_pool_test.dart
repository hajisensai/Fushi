// 守卫 + 行为测试：`tool/bug.dart` 的号池并发防撞（跨分支取号）与 `renumber` 改号。
//
// 下面两个路径只是临时 git 仓库里的 fixture，不是本测试守的东西（守的是
// `tool/bug.dart`）；不声明的话，每个走 BUG 流程的 PR 都会因 reindex 改了真仓库的
// `docs/BUGS.md` 把本套件（起 git 子进程，单跑数分钟）拉进推送前检查。
// tests-for-changes-ignore: docs/BUGS.md docs/bugs
//
// 背景：一天内连撞两轮、涉及四个 PR（#461/#462 抢 1138，#463 也 1138，#464 与 #462
// 改号后的 1139 相撞）。根因是取号只看本地工作区，而并发 agent 各自在独立 worktree
// 的独立分支上开工，彼此不可见。
//
// 第二轮（BUG-1429，2026-08-02 一天连撞六次）：扩到扫分支之后**仍然撞**，因为扫的是
// **commit 树**，而 `bug.dart new` 是先写磁盘文件、几十分钟到几小时后才 commit——
// 那整段窗口对并发 agent 完全不可见。修法是把本机每个 git 工作区磁盘上的
// `docs/bugs/*.md` 也算进号池。
//
// 这里守四件事：
//   ① `new` 取号要看得见「本地分支 + 远端分支」上已占的号（网络断了要**显式警告**，不许静默降级）；
//   ② `new` 取号要看得见**并发工作区里还没提交**的 bug 文件（BUG-1429 根因）；
//   ③ `check` 要报出「我新引入的号还被谁占着」，且不能被历史噪声淹掉；
//   ④ 真撞上时 `renumber` 一条命令把四处（文件名 / 正文 H2 / 代码引用 / 测试名与测试文件名）
//      一起改掉并自校验零残留——只改文件名不改正文 H2 出过 CI 红；
//   ⑤ `settle` 的先后判据是无状态的「最早进入基线首父链者保留」：相邻 push 积压的多组撞号、
//      被 concurrency 取消的 run 留下的撞号、同号三份以上，都在下一次 settle 里一把收口
//      （PR #2122 审查：旧的「以 push 前的 sha 为基线」在相邻 push 下会把 develop 永久卡在撞号态）。
//
// 全部用临时目录里的真 git 仓库做 fixture，不碰仓库里真实的 docs/bugs/*.md，也不依赖网络
// （remote 用本地路径的 bare repo）。
//
// ignore_for_file: always_use_package_imports

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/bug.dart' as bug;

/// 在 [dir] 里跑 git，失败直接 fail（fixture 出问题要立刻炸，不要静默）。
void git(Directory dir, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: dir.path);
  if (r.exitCode != 0) {
    fail('git ${args.join(' ')} 在 ${dir.path} 失败：${r.stdout}${r.stderr}');
  }
}

/// 写一个文件（自动建父目录）。
void writeFile(Directory root, String rel, String content) {
  final f = File('${root.path}/$rel');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

String readFile(Directory root, String rel) =>
    File('${root.path}/$rel').readAsStringSync();

bool exists(Directory root, String rel) =>
    File('${root.path}/$rel').existsSync();

const String indexShell =
    '# Bug 跟踪\n\n---\n\n'
    '<!-- BUGS-INDEX:BEGIN -->\n<!-- BUGS-INDEX:END -->\n';

String bugDoc(int n, String title) =>
    '## BUG-${n.toString().padLeft(3, '0')} · $title\n- **[ ] ① 未修复** —\n';

/// 建一个带 docs/BUGS.md 骨架的临时目录（不含 git）。
Directory makeBareFixture(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  writeFile(dir, 'docs/BUGS.md', indexShell);
  Directory('${dir.path}/docs/bugs').createSync(recursive: true);
  return dir;
}

/// 固定返回给定号池的假扫描器（不碰 git）。
bug.BranchScanner stubScanner(
  bug.BranchScanStatus status,
  Set<int> numbers, {
  String detail = '测试桩',
  int refCount = 3,
}) =>
    () async => bug.BranchScan(status, numbers, detail, refCount: refCount);

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
        // Windows 上 git 进程句柄偶尔滞留，清理失败不影响断言。
      }
    }
    temps.clear();
  });

  /// 建一个「已经有 BUG-005（含代码引用 + 同名测试文件）」的 git 仓库 fixture 并切进去。
  Directory enterRenumberFixture() {
    final root = makeBareFixture('bug_renumber_');
    temps.add(root);
    writeFile(
      root,
      'docs/bugs/BUG-005-foo.md',
      '## BUG-005 · 示例标题\n- **[x] ① 已修复** — abc123\n'
          '- **[x] ② 已加自动化测试** — fushi/test/tools/bug_005_foo_test.dart\n',
    );
    writeFile(root, 'docs/bugs/BUG-006-bar.md', bugDoc(6, '另一条'));
    writeFile(
      root,
      'lib/foo.dart',
      '// 修 BUG-005：根因在 foo.dart:42。debug-005 与 BUG-0055 都不该被改。\nvoid main() {}\n',
    );
    writeFile(
      root,
      'fushi/test/tools/bug_005_foo_test.dart',
      "void main() {\n  test('BUG-005 回归守卫', () {});\n}\n",
    );
    git(root, <String>['init', '-q', '.']);
    git(root, <String>['config', 'user.email', 'fixture@example.com']);
    git(root, <String>['config', 'user.name', 'fixture']);
    // 本机全局 commit.gpgsign=true 会让 fixture 提交失败，显式关掉。
    git(root, <String>['config', 'commit.gpgsign', 'false']);
    git(root, <String>['add', '-A']);
    git(root, <String>['commit', '-qm', 'fixture']);
    bug.bugRepoRoot = root.path;
    return root;
  }

  group('bug.dart renumber：一条命令改四处 + 自校验', () {
    repoTest('文件名 / 正文 H2 / 代码引用 / 测试名与测试文件名四处同步改，且 git 记为改名', () async {
      final root = enterRenumberFixture();
      await runBug(
        () => bug.cmdRenumber(<String>[
          '5',
          '9',
        ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6})),
      );

      // ① 文件名
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isFalse);
      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isTrue);
      // ② 正文 H2（守卫测试按 H2 判重号，只改文件名会 CI 红）
      expect(
        readFile(root, 'docs/bugs/BUG-009-foo.md'),
        startsWith('## BUG-009 · '),
      );
      // ③ 代码引用；同时不许误伤 debug-005 / BUG-0055
      final lib = readFile(root, 'lib/foo.dart');
      expect(lib, contains('修 BUG-009：'));
      expect(lib, contains('debug-005'));
      expect(lib, contains('BUG-0055'));
      // ④ 测试名 + 测试文件名
      expect(exists(root, 'fushi/test/tools/bug_009_foo_test.dart'), isTrue);
      expect(
        readFile(root, 'fushi/test/tools/bug_009_foo_test.dart'),
        contains("test('BUG-009 回归守卫'"),
      );
      // bug 文件正文里指向测试文件的路径也跟着改
      expect(
        readFile(root, 'docs/bugs/BUG-009-foo.md'),
        contains('fushi/test/tools/bug_009_foo_test.dart'),
      );
      // 索引自动重建
      expect(
        readFile(root, 'docs/BUGS.md'),
        contains('[BUG-009](bugs/BUG-009-foo.md)'),
      );
      expect(readFile(root, 'docs/BUGS.md'), isNot(contains('BUG-005')));
      // git mv 保留历史（porcelain 里是 R）
      final status = Process.runSync('git', <String>[
        'status',
        '--porcelain',
      ], workingDirectory: root.path);
      expect(status.stdout as String, contains('R'));
      expect(bug.cmdCheck(), 0);
    });

    repoTest('自校验口径：改号前扫得到残留，改号后归零', () async {
      enterRenumberFixture();
      expect(await runBug(() => bug.findResidualRefs(5)), isNotEmpty);
      await runBug(
        () => bug.cmdRenumber(<String>[
          '5',
          '9',
        ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6})),
      );
      expect(await runBug(() => bug.findResidualRefs(5)), isEmpty);
      expect(await runBug(() => bug.findResidualRefs(9)), isNotEmpty);
    });
  });

  group('bug.dart renumber：前置校验不通过就整体退出', () {
    repoTest('目标号本地已被占用 → 抛错且一个文件都不动', () async {
      final root = enterRenumberFixture();
      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '5',
            '6',
          ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('本地已被占用'),
          ),
        ),
      );
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isTrue);
      expect(readFile(root, 'lib/foo.dart'), contains('BUG-005'));
      expect(exists(root, 'fushi/test/tools/bug_005_foo_test.dart'), isTrue);
    });

    repoTest('目标号被其它分支占用（跨分支扫描口径）→ 抛错且不动文件', () async {
      final root = enterRenumberFixture();
      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '5',
            '9',
          ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6, 9})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('已被其它分支占用'),
          ),
        ),
      );
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isFalse);
    });

    repoTest('<old> 不存在 → 抛错', () async {
      enterRenumberFixture();
      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            '404',
            '405',
          ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('不存在'),
          ),
        ),
      );
    });

    repoTest('非纯数字参数 → 抛错', () async {
      enterRenumberFixture();
      await expectLater(
        runBug(
          () => bug.cmdRenumber(<String>[
            'BUG-005',
            '9',
          ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{})),
        ),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('纯数字'),
          ),
        ),
      );
    });
  });

  group('bug.dart renumber --dry-run', () {
    repoTest('列出要改的文件与行，但一个字节都不落盘', () async {
      final root = enterRenumberFixture();
      final beforeLib = readFile(root, 'lib/foo.dart');
      final beforeDoc = readFile(root, 'docs/bugs/BUG-005-foo.md');
      final beforeIndex = readFile(root, 'docs/BUGS.md');

      await runBug(
        () => bug.cmdRenumber(<String>[
          '5',
          '9',
          '--dry-run',
        ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6})),
      );

      final printed = out.join('\n');
      expect(printed, contains('[dry-run]'));
      expect(
        printed,
        contains('docs/bugs/BUG-005-foo.md  →  docs/bugs/BUG-009-foo.md'),
      );
      expect(printed, contains('fushi/test/tools/bug_005_foo_test.dart'));
      expect(printed, contains('lib/foo.dart:1'));
      // 落盘检查：文件名与内容全部原样
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isFalse);
      expect(exists(root, 'fushi/test/tools/bug_005_foo_test.dart'), isTrue);
      expect(readFile(root, 'lib/foo.dart'), beforeLib);
      expect(readFile(root, 'docs/bugs/BUG-005-foo.md'), beforeDoc);
      expect(readFile(root, 'docs/BUGS.md'), beforeIndex);
    });
  });

  group('bug 号引用正则口径', () {
    repoTest(
      '认 BUG-005 / bug_005 / bug-005，不认 debug-005 / BUG-0055 / BUG-5x',
      () {
        final re = bug.bugRefPattern(5);
        expect(re.hasMatch('修 BUG-005 的根因'), isTrue);
        expect(re.hasMatch('BUG-5'), isTrue);
        expect(re.hasMatch('bug_005_foo_test.dart'), isTrue);
        expect(re.hasMatch('bug-005-slug'), isTrue);
        expect(re.hasMatch('debug-005'), isFalse);
        expect(re.hasMatch('BUG-0055'), isFalse);
        expect(re.hasMatch('BUG-50'), isFalse);
        expect(re.hasMatch('XBUG-005'), isFalse);
      },
    );

    repoTest('renameNumberInPath 只动文件名部分', () {
      expect(
        bug.renameNumberInPath('docs/bugs/BUG-005-foo.md', 5, 9),
        'docs/bugs/BUG-009-foo.md',
      );
      expect(bug.renameNumberInPath('bug-005/inner/other.dart', 5, 9), isNull);
      expect(bug.renameNumberInPath('lib/foo.dart', 5, 9), isNull);
    });
  });

  /// 建「bare origin + 已 push 一条 BUG-003 的 worker clone」；
  /// [pushPeerBeforeClone] 决定并发分支 BUG-020 是在 clone 之前还是之后 push——
  /// 之后 push 意味着只有真的 fetch 才看得见它。返回 worker 工作区。
  Directory makeRemoteFixture({required bool pushPeerBeforeClone}) {
    final base = Directory.systemTemp.createTempSync('bug_remote_');
    temps.add(base);
    final origin = Directory('${base.path}/origin.git')..createSync();
    git(origin, <String>['init', '-q', '--bare', '.']);

    final seed = Directory('${base.path}/seed')..createSync();
    git(seed, <String>['clone', '-q', origin.path, '.']);
    git(seed, <String>['config', 'user.email', 'fixture@example.com']);
    git(seed, <String>['config', 'user.name', 'fixture']);
    // 本机全局 commit.gpgsign=true 会让 fixture 提交失败，显式关掉。
    git(seed, <String>['config', 'commit.gpgsign', 'false']);
    writeFile(seed, 'docs/BUGS.md', indexShell);
    writeFile(seed, 'docs/bugs/BUG-003-base.md', bugDoc(3, '基线'));
    git(seed, <String>['add', '-A']);
    git(seed, <String>['commit', '-qm', 'base']);
    git(seed, <String>['push', '-q', 'origin', 'HEAD:refs/heads/main']);

    void pushPeer() {
      git(seed, <String>['checkout', '-q', '-b', 'peer']);
      writeFile(seed, 'docs/bugs/BUG-020-peer.md', bugDoc(20, '并发分支已占的号'));
      git(seed, <String>['add', '-A']);
      git(seed, <String>['commit', '-qm', 'peer']);
      git(seed, <String>['push', '-q', 'origin', 'peer']);
    }

    if (pushPeerBeforeClone) pushPeer();
    final worker = Directory('${base.path}/worker')..createSync();
    git(worker, <String>['clone', '-q', '-b', 'main', origin.path, '.']);
    git(worker, <String>['config', 'user.email', 'fixture@example.com']);
    git(worker, <String>['config', 'user.name', 'fixture']);
    // 本机全局 commit.gpgsign=true 会让 fixture 提交失败，显式关掉。
    git(worker, <String>['config', 'commit.gpgsign', 'false']);
    if (!pushPeerBeforeClone) pushPeer();
    return worker;
  }

  group('bug.dart new --scan：跨分支取号', () {
    repoTest('clone 之后别人才 push 的号也能扫到（真 fetch）→ 取全局最大 +1，无降级警告', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: false);
      bug.bugRepoRoot = worker.path;

      await runBug(() => bug.cmdNew(<String>['some-slug', '标题', '--scan']));

      // 本地只看得到 BUG-003；远端 peer 分支占了 020 → 必须取 021 而不是 004。
      expect(exists(worker, 'docs/bugs/BUG-021-some-slug.md'), isTrue);
      expect(exists(worker, 'docs/bugs/BUG-004-some-slug.md'), isFalse);
      expect(out.join('\n'), contains('BUG-021'));
      expect(warn, isEmpty, reason: '远端扫描成功时不该有降级警告，实际：$warn');
    });

    repoTest('远端不可达（fetch 失败）→ 降级到已缓存的 remote-tracking 引用，并显式警告可能撞号', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      git(worker, <String>[
        'remote',
        'set-url',
        'origin',
        '${worker.path}/does-not-exist.git',
      ]);

      await runBug(() => bug.cmdNew(<String>['offline-slug', '标题', '--scan']));

      final warned = warn.join('\n');
      expect(warned, contains('未能刷新远端分支'));
      expect(warned, contains('可能与并发分支相撞'), reason: '静默降级会让人误以为已经防住了撞号');
      // 缓存的 origin/peer 里有 020，所以仍然取 021。
      expect(exists(worker, 'docs/bugs/BUG-021-offline-slug.md'), isTrue);
    });

    repoTest('完全不在 git 仓库里 → 只用本地号，且显式警告未能扫描远端分支', () async {
      final root = makeBareFixture('bug_nogit_');
      temps.add(root);
      writeFile(root, 'docs/bugs/BUG-003-base.md', bugDoc(3, '基线'));
      bug.bugRepoRoot = root.path;

      await runBug(() => bug.cmdNew(<String>['nogit-slug', '标题', '--scan']));

      final warned = warn.join('\n');
      expect(warned, contains('未能扫描分支/工作区'));
      expect(warned, contains('可能与并发分支相撞'));
      expect(exists(root, 'docs/bugs/BUG-004-nogit-slug.md'), isTrue);
    });

    repoTest('默认口径不在 git 仓库里 → 只按本地取号，并说明拿不到基线', () async {
      final root = makeBareFixture('bug_nogit_default_');
      temps.add(root);
      writeFile(root, 'docs/bugs/BUG-003-base.md', bugDoc(3, '基线'));
      bug.bugRepoRoot = root.path;

      await runBug(() => bug.cmdNew(<String>['nogit-slug', '标题']));

      expect(warn.join('\n'), contains('拿不到基线'));
      expect(exists(root, 'docs/bugs/BUG-004-nogit-slug.md'), isTrue);
    });

    repoTest('扫描器返回 stale/unavailable 时仍取号，fresh 时不警告', () async {
      final root = makeBareFixture('bug_stub_');
      temps.add(root);
      writeFile(root, 'docs/bugs/BUG-003-base.md', bugDoc(3, '基线'));
      bug.bugRepoRoot = root.path;

      await runBug(
        () => bug.cmdNew(<String>[
          'stub-slug',
        ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{3, 41})),
      );
      expect(
        exists(root, 'docs/bugs/BUG-042-stub-slug.md'),
        isTrue,
        reason: '要取「本地最大与跨分支最大」的全局最大 +1',
      );
      expect(warn, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // BUG-1429：取号盲区——只扫 commit 树，看不见并发工作区磁盘上还没提交的 bug 文件。
  // -------------------------------------------------------------------------

  /// 在 [worker] 旁边挂一个 `git worktree`，并在里面写一个**未提交**的 bug 文件。
  /// 这就是 `bug.dart new` 写完文件、还没 commit 的那几十分钟的真实状态。
  Directory addSiblingWorktreeWithUncommittedBug(
    Directory worker,
    int number,
    String slug,
  ) {
    final sibling = Directory('${worker.parent.path}/wt-$slug');
    git(worker, <String>['worktree', 'add', '--detach', sibling.path, 'HEAD']);
    writeFile(
      sibling,
      'docs/bugs/BUG-${number.toString().padLeft(3, '0')}-$slug.md',
      bugDoc(number, '并发工作区里刚 new 出来、还没 commit'),
    );
    return sibling;
  }

  group('bug.dart new --scan：号池盲区（BUG-1429）', () {
    repoTest('并发工作区里**未提交**的 bug 文件必须算已占（一天连撞六次的根因）', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      // 邻居工作区刚 `new` 出 BUG-050，还没 commit——任何 commit 树里都没有它。
      addSiblingWorktreeWithUncommittedBug(worker, 50, 'neighbour');

      await runBug(() => bug.cmdNew(<String>['mine', '标题', '--scan']));

      expect(
        exists(worker, 'docs/bugs/BUG-051-mine.md'),
        isTrue,
        reason: '未提交的 BUG-050 必须算已占；取 021/050 都是撞号',
      );
      expect(exists(worker, 'docs/bugs/BUG-050-mine.md'), isFalse);
    });

    repoTest('未提交文件的占用证据要写清「哪个工作区」，不是只给一个数字', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      final sibling = addSiblingWorktreeWithUncommittedBug(
        worker,
        50,
        'neighbour',
      );

      final scan = await runBug(() => bug.scanBranchBugNumbers());

      expect(scan.numbers, contains(50));
      final described = scan.occupancy.describe(50);
      expect(described, contains('已被'));
      expect(described, contains('BUG-050-neighbour.md'));
      expect(
        described,
        contains(sibling.path.replaceAll(r'\', '/')),
        reason: '得说清是哪个工作区占的，否则没法判断该找谁改号',
      );
      expect(
        scan.worktreeCount,
        greaterThanOrEqualTo(2),
        reason: '主工作区 + 邻居工作区都要扫到，实际 ${scan.worktreeCount}',
      );
    });

    repoTest('远端不可达（降级）时，本机并发工作区的未提交号仍然看得见', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      addSiblingWorktreeWithUncommittedBug(worker, 60, 'neighbour');
      git(worker, <String>[
        'remote',
        'set-url',
        'origin',
        '${worker.path}/does-not-exist.git',
      ]);

      await runBug(() => bug.cmdNew(<String>['mine', '标题', '--scan']));

      expect(warn.join('\n'), contains('未能刷新远端分支'), reason: '降级必须显式警告');
      expect(
        exists(worker, 'docs/bugs/BUG-061-mine.md'),
        isTrue,
        reason: '网络断了不影响本机工作区扫描——本机并发才是撞号的大头',
      );
    });
  });

  group('bug.dart new：什么算「认领一个号」', () {
    repoTest('已提交分支上 bug 文件的正文 H2 号也算已占（文件名与 H2 不一致的坏态）', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      // 邻居分支上有一份坏态文件：文件名说 030，正文 H2 说 031。两个号都被认领了。
      git(worker, <String>['checkout', '-q', '-b', 'mismatch']);
      writeFile(
        worker,
        'docs/bugs/BUG-030-mismatch.md',
        bugDoc(31, '文件名与 H2 不一致'),
      );
      git(worker, <String>['add', '-A']);
      git(worker, <String>['commit', '-qm', 'mismatch']);
      git(worker, <String>['checkout', '-q', '-']);
      // 切回来后工作区里没有那个文件，只有 commit 树里有。
      expect(exists(worker, 'docs/bugs/BUG-030-mismatch.md'), isFalse);

      final scan = await runBug(() => bug.scanBranchBugNumbers());

      expect(scan.numbers, contains(30), reason: '文件名口径');
      expect(scan.numbers, contains(31), reason: 'H2 口径——只认文件名会把 031 当空号发出去');
      expect(scan.occupancy.describe(31), contains('BUG-030-mismatch.md'));
    });

    repoTest('代码/文档里的 BUG-NNN **引用**不算认领——否则每条 bug 白烧一批号', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      git(worker, <String>['checkout', '-q', '-b', 'refs-only']);
      writeFile(
        worker,
        'lib/foo.dart',
        '// 修 BUG-777 的根因在这里。\nvoid main() {}\n',
      );
      writeFile(worker, 'docs/notes.md', '见 BUG-778 与 bug_779_foo_test.dart\n');
      git(worker, <String>['add', '-A']);
      git(worker, <String>['commit', '-qm', 'refs']);

      final scan = await runBug(() => bug.scanBranchBugNumbers());

      expect(scan.numbers, isNot(contains(777)));
      expect(scan.numbers, isNot(contains(778)));
      expect(scan.numbers, isNot(contains(779)));
      expect(scan.numbers, contains(20), reason: '真正的 bug 文件仍然要算');
    });
  });

  group('bug.dart check --scan：跨分支/工作区占用复核', () {
    /// base(main) 上有 BUG-003；陈旧分支上有同号但不同文件名的 BUG-003-stale.md（历史噪声，
    /// 不该报）；我的工作区有未提交的 BUG-050-mine.md，而邻居工作区也占了 050（该报）。
    Future<Directory> makeCheckFixture() async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      git(worker, <String>['checkout', '-q', '-b', 'stale']);
      writeFile(worker, 'docs/bugs/BUG-003-stale.md', bugDoc(3, '陈旧分支上的历史同号'));
      git(worker, <String>['add', '-A']);
      git(worker, <String>['commit', '-qm', 'stale']);
      git(worker, <String>['checkout', '-q', 'main']);
      addSiblingWorktreeWithUncommittedBug(worker, 50, 'neighbour');
      writeFile(worker, 'docs/bugs/BUG-050-mine.md', bugDoc(50, '我这条 PR 新引入的'));
      bug.cmdReindex();
      out.clear();
      warn.clear();
      return worker;
    }

    repoTest('报出「我新引入的号被别的文件名占了」，并写清占用者与来源', () async {
      await makeCheckFixture();

      final code = await runBug(() => bug.cmdCheckAll(<String>['--scan']));

      final warned = warn.join('\n');
      expect(warned, contains('BUG-050'));
      expect(warned, contains('BUG-050-neighbour.md'), reason: '要说清是谁占的');
      expect(warned, contains('工作区'), reason: '要说清在哪占的');
      expect(code, 0, reason: '默认只让本地不变式决定红绿');
    });

    repoTest('base 上已定案的号不报——陈旧分支的历史同号是那些分支的活', () async {
      await makeCheckFixture();

      await runBug(() => bug.cmdCheckAll(<String>['--scan']));

      expect(
        warn.join('\n'),
        isNot(contains('BUG-003')),
        reason: 'BUG-003 已在 base 上定案；不过滤会在真仓库吐 72KB 历史噪声，信号全埋掉',
      );
    });

    repoTest('--strict 让跨源撞号也退非 0（开 PR 前的硬门）', () async {
      await makeCheckFixture();

      expect(await runBug(() => bug.cmdCheckAll(<String>['--strict'])), 1);
    });

    repoTest('没有跨源撞号时 --strict 也是 0', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      writeFile(worker, 'docs/bugs/BUG-099-mine.md', bugDoc(99, '没人抢的号'));
      bug.cmdReindex();
      out.clear();
      warn.clear();

      expect(await runBug(() => bug.cmdCheckAll(<String>['--strict'])), 0);
    });

    repoTest('默认（与兼容的 --no-scan）只做本地校验，并指向合并时的 settle', () async {
      await makeCheckFixture();

      for (final args in <List<String>>[
        <String>[],
        <String>['--no-scan'],
      ]) {
        out.clear();
        warn.clear();
        expect(await runBug(() => bug.cmdCheckAll(args)), 0);
        expect(out.join('\n'), contains('settle'));
        expect(
          warn.join('\n'),
          isNot(contains('BUG-050-neighbour.md')),
          reason: '默认不该遍历其它工作区',
        );
      }
    });
  });

  group('git 对象解析：不靠在二进制里瞎正则', () {
    repoTest('parseTreeEntries 按结构切 tree，20 字节 sha 里的 `BUG-` 字节不会被当成号', () {
      // `<mode> SP <name> NUL <20 字节 sha>`；第二条的 sha 里故意塞进 "BUG-9999" 字节。
      // NUL 用 fromCharCode 拼，绝不往 .dart 源码里写裸 NUL——git 会把整个文件判成
      // binary，并发合并时静默丢掉对方的改动。
      final nul = String.fromCharCode(0);
      String sha(String seed) => (seed + 'x' * 20).substring(0, 20);
      final body =
          '100644 BUG-007-real.md$nul${sha('abcdefghij')}'
          '100644 readme.md$nul${sha('..BUG-9999..')}';

      final entries = bug.parseTreeEntries(body);

      expect(entries.map((bug.TreeEntry e) => e.name).toList(), <String>[
        'BUG-007-real.md',
        'readme.md',
      ]);
      expect(entries.first.sha.length, 40, reason: '20 字节要展开成 40 位十六进制');
      expect(
        entries
            .map((bug.TreeEntry e) => e.name)
            .where((String n) => n.contains('9999')),
        isEmpty,
        reason: 'sha 里的 BUG-9999 是随机字节，不是文件名',
      );
    });

    repoTest('parseBatchBlocks 按 header 里的 size 精确切块，块内含换行也不串块', () {
      final blocks = bug.parseBatchBlocks(
        'aa11 blob 5\nab\ncd\nbb22 blob 2\nef\n',
      );

      expect(blocks.length, 2);
      expect(blocks[0].sha, 'aa11');
      expect(blocks[0].body, 'ab\ncd');
      expect(blocks[1].sha, 'bb22');
      expect(blocks[1].body, 'ef');
    });
  });

  group('bug.dart renumber：还没 commit 的新 bug 文件', () {
    repoTest('untracked 文件 git mv 会失败，退回普通改名，四处照样改到', () async {
      final root = makeBareFixture('bug_untracked_');
      temps.add(root);
      // 只把 lib/ 入库；bug 文件与测试文件保持 untracked（刚 `new` 出来还没 commit 的真实状态）。
      writeFile(root, 'lib/foo.dart', '// 见 BUG-005。\nvoid main() {}\n');
      git(root, <String>['init', '-q', '.']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      // 本机全局 commit.gpgsign=true 会让 fixture 提交失败，显式关掉。
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      git(root, <String>['add', 'lib/foo.dart', 'docs/BUGS.md']);
      git(root, <String>['commit', '-qm', 'partial']);
      writeFile(root, 'docs/bugs/BUG-005-foo.md', bugDoc(5, '刚建还没提交'));
      writeFile(
        root,
        'fushi/test/tools/bug_005_foo_test.dart',
        '// BUG-005 守卫\n',
      );
      bug.bugRepoRoot = root.path;

      await runBug(
        () => bug.cmdRenumber(<String>[
          '5',
          '9',
        ], scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{})),
      );

      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isFalse);
      expect(
        readFile(root, 'docs/bugs/BUG-009-foo.md'),
        startsWith('## BUG-009 · '),
      );
      expect(exists(root, 'fushi/test/tools/bug_009_foo_test.dart'), isTrue);
      expect(readFile(root, 'lib/foo.dart'), contains('BUG-009'));
      expect(await runBug(() => bug.findResidualRefs(5)), isEmpty);
      expect(bug.cmdCheck(), 0);
    });
  });

  group('bug.dart new：默认口径（本地 + 基线树，不遍历）', () {
    repoTest('看得见 origin/main 上的号，看不见别的分支与邻居工作区——那些交给合并时的 settle', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      bug.bugRepoRoot = worker.path;
      // 基线（origin/main）上再加一条 BUG-010：worker 只要 fetch 过就看得见。
      git(worker, <String>['checkout', '-q', '-b', 'tmp-base']);
      writeFile(worker, 'docs/bugs/BUG-010-on-base.md', bugDoc(10, '基线上的号'));
      git(worker, <String>['add', '-A']);
      git(worker, <String>['commit', '-qm', 'base 010']);
      git(worker, <String>['push', '-q', 'origin', 'HEAD:main']);
      git(worker, <String>['checkout', '-q', 'main']);
      git(worker, <String>['branch', '-q', '-D', 'tmp-base']);
      git(worker, <String>['fetch', '-q', 'origin']);
      addSiblingWorktreeWithUncommittedBug(worker, 50, 'neighbour');

      await runBug(() => bug.cmdNew(<String>['mine', '标题']));

      expect(
        exists(worker, 'docs/bugs/BUG-011-mine.md'),
        isTrue,
        reason: '取「本地 003 与基线 010」最大 +1；peer 分支的 020、邻居工作区的 050 都不扫',
      );
      expect(out.join('\n'), contains('settle'));
    });
  });

  group('bug.dart settle：合并时收口撞号', () {
    /// 基线 main 上有 BUG-005-theirs（lib/theirs.dart 引用它）；feature 分支各自取到 005，
    /// 建了 BUG-005-mine（lib/mine.dart 与同号测试文件引用它）。返回仓库根，停在 feature 上、
    /// 尚未合并 main。
    Directory makeCollisionFixture() {
      final root = makeBareFixture('bug_settle_');
      temps.add(root);
      writeFile(root, 'docs/bugs/BUG-004-old.md', bugDoc(4, '老条目'));
      git(root, <String>['init', '-q', '-b', 'main', '.']);
      // 本机全局 core.autocrlf 会在切分支时把 fixture 文件转成 CRLF，索引逐字节比较就失真。
      git(root, <String>['config', 'core.autocrlf', 'false']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      // 本机全局 commit.gpgsign=true 会让 fixture 提交失败，显式关掉。
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      bug.bugRepoRoot = root.path;
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'seed']);

      git(root, <String>['checkout', '-q', '-b', 'feature']);
      writeFile(root, 'docs/bugs/BUG-005-mine.md', bugDoc(5, '我这条'));
      writeFile(
        root,
        'lib/mine.dart',
        '// 修 BUG-005：我这条的根因。\nvoid main() {}\n',
      );
      writeFile(
        root,
        'fushi/test/tools/bug_005_mine_test.dart',
        '// BUG-005 回归守卫\n',
      );
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'mine']);

      git(root, <String>['checkout', '-q', 'main']);
      writeFile(root, 'docs/bugs/BUG-005-theirs.md', bugDoc(5, '别人那条'));
      writeFile(
        root,
        'lib/theirs.dart',
        '// 修 BUG-005：别人那条的根因。\nvoid main() {}\n',
      );
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'theirs']);
      git(root, <String>['checkout', '-q', 'feature']);
      return root;
    }

    void expectSettled(Directory root) {
      expect(
        exists(root, 'docs/bugs/BUG-005-theirs.md'),
        isTrue,
        reason: '基线那条不动',
      );
      expect(exists(root, 'docs/bugs/BUG-005-mine.md'), isFalse);
      expect(
        readFile(root, 'docs/bugs/BUG-006-mine.md'),
        startsWith('## BUG-006 · '),
      );
      expect(readFile(root, 'lib/mine.dart'), contains('BUG-006'));
      expect(exists(root, 'fushi/test/tools/bug_006_mine_test.dart'), isTrue);
      expect(
        readFile(root, 'lib/theirs.dart'),
        contains('BUG-005'),
        reason: '指向基线那条的引用一个字都不能改',
      );
      expect(readFile(root, 'docs/BUGS.md'), contains('BUG-006-mine.md'));
      expect(bug.cmdCheck(), 0);
    }

    repoTest(
      '本地：合进基线（docs/BUGS.md 按 union 合并不冲突）后 settle，把我这份改到下一个空号',
      () async {
        final root = makeCollisionFixture();
        writeFile(root, '.gitattributes', 'docs/BUGS.md merge=union\n');
        git(root, <String>['merge', '-q', '--no-edit', 'main']);
        expect(bug.collidedBugNumbers(), <int>[5]);

        expect(
          await runBug(() => bug.cmdSettle(<String>['--base', 'main'])),
          0,
        );

        expectSettled(root);
        out.clear();
        expect(
          await runBug(() => bug.cmdSettle(<String>['--base', 'main'])),
          0,
          reason: '幂等',
        );
        expect(out.join('\n'), contains('无撞号'));
      },
    );

    repoTest('CI：站在 develop 尖端上（HEAD == 基线）跑，后进入首父链的那份改号', () async {
      final root = makeCollisionFixture();
      git(root, <String>['checkout', '-q', 'main']);
      // 模拟 PR 合进 develop：一个 merge commit 把 feature 带进来（索引按 union 合并）。
      // 两份 BUG-005 此时**都已在基线上**——不靠「push 前的 sha」，只看谁先进首父链。
      writeFile(root, '.gitattributes', 'docs/BUGS.md merge=union\n');
      git(root, <String>['merge', '-q', '--no-ff', '--no-edit', 'feature']);

      expect(await runBug(() => bug.cmdSettle(<String>['--base', 'main'])), 0);

      expectSettled(root);
    });

    repoTest('--dry-run 一个字节都不落盘', () async {
      final root = makeCollisionFixture();
      writeFile(root, '.gitattributes', 'docs/BUGS.md merge=union\n');
      git(root, <String>['merge', '-q', '--no-edit', 'main']);

      expect(
        await runBug(
          () => bug.cmdSettle(<String>['--base', 'main', '--dry-run']),
        ),
        0,
      );

      expect(exists(root, 'docs/bugs/BUG-005-mine.md'), isTrue);
      expect(readFile(root, 'lib/mine.dart'), contains('BUG-005'));
    });

    repoTest('无撞号时只重建索引（union 合并留下的乱序行被理顺）', () async {
      final root = makeCollisionFixture();
      final index = readFile(root, 'docs/BUGS.md');
      // 把两行索引的顺序倒过来，模拟 union 合并后的行序。
      final lines = index.split('\n');
      final rows = lines.where((String l) => l.startsWith('| [BUG-')).toList();
      expect(rows, hasLength(2));
      writeFile(
        root,
        'docs/BUGS.md',
        index
            .replaceFirst(rows[0], '@@ROW0@@')
            .replaceFirst(rows[1], rows[0])
            .replaceFirst('@@ROW0@@', rows[1]),
      );
      expect(bug.cmdCheck(), 1);

      expect(await runBug(() => bug.cmdSettle(<String>['--base', 'main'])), 0);

      expect(readFile(root, 'docs/BUGS.md'), index);
    });
  });

  // -------------------------------------------------------------------------
  // PR #2122 审查：settle 的先后判据必须无状态。
  //
  // 旧实现以「push 前的 sha」为基线、只改「这次 push 带进来的那份」。相邻两次 push 之间：
  // job2 把 B 的 101 改成 102 时看不到同时合进来的 C（也是 102），推上去后 develop 有两份 102；
  // job3 的基线已同时含两份，判不出谁是新的 → 抛错，develop 永久卡在撞号态。被 concurrency
  // 取消的 run 带进来的撞号也永远没人收。现在的判据只看 develop 首父链上谁先进来。
  // -------------------------------------------------------------------------
  group('bug.dart settle：最早进入基线首父链者保留（无状态判据）', () {
    String pad(int n) => n.toString().padLeft(3, '0');

    String headSha(Directory root) =>
        (Process.runSync('git', <String>[
                  'rev-parse',
                  'HEAD',
                ], workingDirectory: root.path).stdout
                as String)
            .trim();

    /// develop（这里叫 main）的种子：已有 BUG-100，索引按 union 合并。停在 main 上。
    Directory makeDevelopFixture() {
      final root = makeBareFixture('bug_settle_chain_');
      temps.add(root);
      writeFile(root, '.gitattributes', 'docs/BUGS.md merge=union\n');
      writeFile(root, 'docs/bugs/BUG-100-seed.md', bugDoc(100, '种子'));
      git(root, <String>['init', '-q', '-b', 'main', '.']);
      git(root, <String>['config', 'core.autocrlf', 'false']);
      git(root, <String>['config', 'user.email', 'fixture@example.com']);
      git(root, <String>['config', 'user.name', 'fixture']);
      git(root, <String>['config', 'commit.gpgsign', 'false']);
      bug.bugRepoRoot = root.path;
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'seed']);
      return root;
    }

    /// 从 [forkAt] 分出 PR 分支：新建 BUG-[number]-[slug] 与引用它的 `lib/[slug].dart`，
    /// 再以 `--no-ff` 合进 main（等同 GitHub 的合并提交，PR 的改动在首父 diff 里）。
    void mergePr(Directory root, String forkAt, int number, String slug) {
      git(root, <String>['checkout', '-q', '-b', 'pr-$slug', forkAt]);
      writeFile(
        root,
        'docs/bugs/BUG-${pad(number)}-$slug.md',
        bugDoc(number, slug),
      );
      writeFile(
        root,
        'lib/$slug.dart',
        '// 修 BUG-${pad(number)}：$slug 的根因。\nvoid main() {}\n',
      );
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'pr $slug']);
      git(root, <String>['checkout', '-q', 'main']);
      git(root, <String>['merge', '-q', '--no-ff', '--no-edit', 'pr-$slug']);
    }

    void expectBug(Directory root, int number, String slug) {
      final rel = 'docs/bugs/BUG-${pad(number)}-$slug.md';
      expect(exists(root, rel), isTrue, reason: '$slug 应落在 BUG-${pad(number)}');
      expect(readFile(root, rel), startsWith('## BUG-${pad(number)} · '));
      expect(
        readFile(root, 'lib/$slug.dart'),
        contains('修 BUG-${pad(number)}：'),
        reason: '$slug 的代码引用要跟着它的号走',
      );
    }

    repoTest(
      '相邻 push 积压：旧 job 推上去的「102」与同时合进来的 C 的 102 撞号 → 下一次 settle 收口',
      () async {
        final root = makeDevelopFixture();
        final seed = headSha(root);
        mergePr(root, seed, 101, 'a'); // push1：A 合入，无撞号
        final afterA = headSha(root);
        mergePr(root, seed, 101, 'b'); // push2：B 合入，与 A 撞 101
        mergePr(root, afterA, 102, 'c'); // push3：C（A 合入后 new 出 102）合入
        // 旧 job2 只看 push2 的树，把 B 改成 102，rebase 到 push3 之后推了上去：
        git(root, <String>[
          'mv',
          'docs/bugs/BUG-101-b.md',
          'docs/bugs/BUG-102-b.md',
        ]);
        writeFile(root, 'docs/bugs/BUG-102-b.md', bugDoc(102, 'b'));
        writeFile(root, 'lib/b.dart', '// 修 BUG-102：b 的根因。\nvoid main() {}\n');
        bug.cmdReindex();
        git(root, <String>['add', '-A']);
        git(root, <String>[
          'commit',
          '-qm',
          'chore(bugs): stale settle pushed after C',
        ]);
        expect(bug.collidedBugNumbers(), <int>[
          102,
        ], reason: '前提：develop 上两份 102');

        expect(
          await runBug(() => bug.cmdSettle(<String>['--base', 'main'])),
          0,
        );

        expectBug(root, 101, 'a');
        expectBug(root, 102, 'c'); // 先进首父链（merge C）的保留
        expectBug(root, 103, 'b'); // 改号提交才进来的那份再改一次
        expect(exists(root, 'docs/bugs/BUG-102-b.md'), isFalse);
        expect(bug.cmdCheck(), 0);
      },
    );

    repoTest('被取消的 run 留下多组撞号：一次 settle 全部收口，先进来的保留（与文件名字典序无关）', () async {
      final root = makeDevelopFixture();
      final seed = headSha(root);
      // 四次 push 挨着来，中间的 settle 全被 concurrency 取消——两组撞号都积在 develop 上。
      // 先进来的 slug 字典序反而靠后，防「按文件名排」冒充「按进入先后排」。
      mergePr(root, seed, 101, 'zeta');
      mergePr(root, seed, 101, 'alpha');
      mergePr(root, seed, 102, 'gamma');
      mergePr(root, seed, 102, 'beta');
      expect(bug.collidedBugNumbers(), <int>[101, 102]);

      expect(await runBug(() => bug.cmdSettle(<String>['--base', 'main'])), 0);

      expectBug(root, 101, 'zeta');
      expectBug(root, 102, 'gamma');
      expectBug(root, 103, 'alpha');
      expectBug(root, 104, 'beta');
      expect(bug.collidedBugNumbers(), isEmpty);
      expect(bug.cmdCheck(), 0);
    });

    repoTest('同号三份：最早的保留，其余两份依次改号，不留第三份给 check 报红', () async {
      final root = makeDevelopFixture();
      final seed = headSha(root);
      mergePr(root, seed, 101, 'x');
      mergePr(root, seed, 101, 'y');
      mergePr(root, seed, 101, 'z');
      expect(bug.locateBugFiles(101), hasLength(3));

      expect(await runBug(() => bug.cmdSettle(<String>['--base', 'main'])), 0);

      expectBug(root, 101, 'x');
      expectBug(root, 102, 'y');
      expectBug(root, 103, 'z');
      expect(bug.cmdCheck(), 0);

      out.clear();
      expect(
        await runBug(() => bug.cmdSettle(<String>['--base', 'main'])),
        0,
        reason: '幂等',
      );
      expect(out.join('\n'), contains('无撞号'));
    });

    repoTest('改号提交本身也按「这时才进来」算（--no-renames），不会被改名检测追溯回旧号的提交', () async {
      final root = makeDevelopFixture();
      final seed = headSha(root);
      mergePr(root, seed, 101, 'old');
      mergePr(root, seed, 102, 'later');
      // 有人手动把 BUG-101-old 改名成 102（git mv）：改名提交在 later 之后。
      git(root, <String>[
        'mv',
        'docs/bugs/BUG-101-old.md',
        'docs/bugs/BUG-102-old.md',
      ]);
      writeFile(root, 'docs/bugs/BUG-102-old.md', bugDoc(102, 'old'));
      writeFile(
        root,
        'lib/old.dart',
        '// 修 BUG-102：old 的根因。\nvoid main() {}\n',
      );
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'manual rename']);

      expect(await runBug(() => bug.cmdSettle(<String>['--base', 'main'])), 0);

      expectBug(root, 102, 'later');
      expectBug(root, 103, 'old');
    });

    repoTest('本地分支：基线自身的撞号不在本地改（归 develop 上的 settle），只改还没进基线的那份', () async {
      final root = makeDevelopFixture();
      final seed = headSha(root);
      git(root, <String>['checkout', '-q', '-b', 'feature', seed]);
      writeFile(root, 'docs/bugs/BUG-101-mine.md', bugDoc(101, 'mine'));
      writeFile(
        root,
        'lib/mine.dart',
        '// 修 BUG-101：mine 的根因。\nvoid main() {}\n',
      );
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'mine']);
      git(root, <String>['checkout', '-q', 'main']);
      mergePr(root, seed, 101, 'first');
      mergePr(root, seed, 101, 'second'); // develop 自己也撞了，还没被 CI 收口
      git(root, <String>['checkout', '-q', 'feature']);
      git(root, <String>['merge', '-q', '--no-edit', 'main']);

      final code = await runBug(
        () => bug.cmdSettle(<String>['--base', 'main']),
      );

      expectBug(root, 101, 'first');
      expectBug(root, 101, 'second'); // 不动：两边各改一次会在合并时撞成 rename/rename 冲突
      expectBug(root, 102, 'mine');
      expect(warn.join('\n'), contains('基线自身的撞号'));
      expect(code, 1, reason: '基线自身仍撞号，check 如实报红');
    });

    repoTest('同一个提交带进来两份同号：判不出先后 → 整体报错，一个文件都不动', () async {
      final root = makeDevelopFixture();
      writeFile(root, 'docs/bugs/BUG-101-p.md', bugDoc(101, 'p'));
      writeFile(root, 'docs/bugs/BUG-101-q.md', bugDoc(101, 'q'));
      bug.cmdReindex();
      git(root, <String>['add', '-A']);
      git(root, <String>['commit', '-qm', 'two at once']);

      await expectLater(
        runBug(() => bug.cmdSettle(<String>['--base', 'main'])),
        throwsA(
          isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message,
            'message',
            contains('同时进来'),
          ),
        ),
      );
      expect(exists(root, 'docs/bugs/BUG-101-p.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-101-q.md'), isTrue);
    });

    repoTest('renumber 手动改号在三份同号时只改最晚进来的那份，并提示用 settle 收口', () async {
      final root = makeDevelopFixture();
      final seed = headSha(root);
      mergePr(root, seed, 101, 'x');
      mergePr(root, seed, 101, 'y');
      mergePr(root, seed, 101, 'z');

      await runBug(
        () => bug.cmdRenumber(<String>['101', '150', '--base', 'main']),
      );

      expectBug(root, 101, 'x');
      expectBug(root, 101, 'y');
      expectBug(root, 150, 'z');
      expect(warn.join('\n'), contains('settle'));
    });

    repoTest('先后比较：基线上的按首父序号，没进基线的排最后；同位置判为同时进来', () {
      bug.BugFileArrival at(String path, int? position) => bug.BugFileArrival(
        path: path,
        commit: position == null ? '' : 'c$position',
        position: position,
      );
      final ranked = <bug.BugFileArrival>[
        at('docs/bugs/BUG-101-local.md', null),
        at('docs/bugs/BUG-101-late.md', 7),
        at('docs/bugs/BUG-101-early.md', 3),
      ]..sort(bug.compareArrivals);
      expect(ranked.map((bug.BugFileArrival a) => a.path).toList(), <String>[
        'docs/bugs/BUG-101-early.md',
        'docs/bugs/BUG-101-late.md',
        'docs/bugs/BUG-101-local.md',
      ]);
      expect(bug.sameArrival(at('a', 3), at('b', 3)), isTrue);
      expect(bug.sameArrival(at('a', null), at('b', null)), isTrue);
      expect(bug.sameArrival(at('a', 3), at('b', null)), isFalse);
      expect(
        () => bug.requireDistinctArrivals(101, <bug.BugFileArrival>[
          at('a', 3),
          at('b', 3),
        ], 'main'),
        throwsA(isA<bug.BugToolError>()),
      );
    });
  });
}

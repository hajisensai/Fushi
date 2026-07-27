// 守卫 + 行为测试：`tool/bug.dart` 的号池并发防撞（跨分支取号）与 `renumber` 改号。
//
// 背景：一天内连撞两轮、涉及四个 PR（#461/#462 抢 1138，#463 也 1138，#464 与 #462
// 改号后的 1139 相撞）。根因是取号只看本地工作区，而并发 agent 各自在独立 worktree
// 的独立分支上开工，彼此不可见。这里守两件事：
//   ① `new` 取号要看得见「本地分支 + 远端分支」上已占的号（网络断了要**显式警告**，不许静默降级）；
//   ② 真撞上时 `renumber` 一条命令把四处（文件名 / 正文 H2 / 代码引用 / 测试名与测试文件名）
//      一起改掉并自校验零残留——只改文件名不改正文 H2 出过 CI 红。
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

String readFile(Directory root, String rel) => File('${root.path}/$rel').readAsStringSync();

bool exists(Directory root, String rel) => File('${root.path}/$rel').existsSync();

const String indexShell = '# Bug 跟踪\n\n---\n\n'
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
  final Directory originalCwd = Directory.current;
  late List<String> out;
  late List<String> warn;
  final List<Directory> temps = <Directory>[];

  setUp(() {
    out = <String>[];
    warn = <String>[];
    bug.logOut = out.add;
    bug.logWarn = warn.add;
  });

  tearDown(() {
    Directory.current = originalCwd;
    bug.logOut = stdout.writeln;
    bug.logWarn = stderr.writeln;
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
    writeFile(root, 'docs/bugs/BUG-005-foo.md',
        '## BUG-005 · 示例标题\n- **[x] ① 已修复** — abc123\n'
        '- **[x] ② 已加自动化测试** — hibiki/test/tools/bug_005_foo_test.dart\n');
    writeFile(root, 'docs/bugs/BUG-006-bar.md', bugDoc(6, '另一条'));
    writeFile(root, 'lib/foo.dart',
        '// 修 BUG-005：根因在 foo.dart:42。debug-005 与 BUG-0055 都不该被改。\nvoid main() {}\n');
    writeFile(root, 'hibiki/test/tools/bug_005_foo_test.dart',
        "void main() {\n  test('BUG-005 回归守卫', () {});\n}\n");
    git(root, <String>['init', '-q', '.']);
    git(root, <String>['config', 'user.email', 'fixture@example.com']);
    git(root, <String>['config', 'user.name', 'fixture']);
    // 本机全局 commit.gpgsign=true 会让 fixture 提交失败，显式关掉。
    git(root, <String>['config', 'commit.gpgsign', 'false']);
    git(root, <String>['add', '-A']);
    git(root, <String>['commit', '-qm', 'fixture']);
    Directory.current = root;
    return root;
  }

  group('bug.dart renumber：一条命令改四处 + 自校验', () {
    test('文件名 / 正文 H2 / 代码引用 / 测试名与测试文件名四处同步改，且 git 记为改名', () async {
      final root = enterRenumberFixture();
      await bug.cmdRenumber(
        <String>['5', '9'],
        scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6}),
      );

      // ① 文件名
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isFalse);
      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isTrue);
      // ② 正文 H2（守卫测试按 H2 判重号，只改文件名会 CI 红）
      expect(readFile(root, 'docs/bugs/BUG-009-foo.md'), startsWith('## BUG-009 · '));
      // ③ 代码引用；同时不许误伤 debug-005 / BUG-0055
      final lib = readFile(root, 'lib/foo.dart');
      expect(lib, contains('修 BUG-009：'));
      expect(lib, contains('debug-005'));
      expect(lib, contains('BUG-0055'));
      // ④ 测试名 + 测试文件名
      expect(exists(root, 'hibiki/test/tools/bug_009_foo_test.dart'), isTrue);
      expect(readFile(root, 'hibiki/test/tools/bug_009_foo_test.dart'),
          contains("test('BUG-009 回归守卫'"));
      // bug 文件正文里指向测试文件的路径也跟着改
      expect(readFile(root, 'docs/bugs/BUG-009-foo.md'),
          contains('hibiki/test/tools/bug_009_foo_test.dart'));
      // 索引自动重建
      expect(readFile(root, 'docs/BUGS.md'), contains('[BUG-009](bugs/BUG-009-foo.md)'));
      expect(readFile(root, 'docs/BUGS.md'), isNot(contains('BUG-005')));
      // git mv 保留历史（porcelain 里是 R）
      final status = Process.runSync('git', <String>['status', '--porcelain'],
          workingDirectory: root.path);
      expect(status.stdout as String, contains('R'));
      expect(bug.cmdCheck(), 0);
    });

    test('自校验口径：改号前扫得到残留，改号后归零', () async {
      enterRenumberFixture();
      expect(await bug.findResidualRefs(5), isNotEmpty);
      await bug.cmdRenumber(
        <String>['5', '9'],
        scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6}),
      );
      expect(await bug.findResidualRefs(5), isEmpty);
      expect(await bug.findResidualRefs(9), isNotEmpty);
    });
  });

  group('bug.dart renumber：前置校验不通过就整体退出', () {
    test('目标号本地已被占用 → 抛错且一个文件都不动', () async {
      final root = enterRenumberFixture();
      await expectLater(
        bug.cmdRenumber(
          <String>['5', '6'],
          scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6}),
        ),
        throwsA(isA<bug.BugToolError>()
            .having((bug.BugToolError e) => e.message, 'message', contains('本地已被占用'))),
      );
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isTrue);
      expect(readFile(root, 'lib/foo.dart'), contains('BUG-005'));
      expect(exists(root, 'hibiki/test/tools/bug_005_foo_test.dart'), isTrue);
    });

    test('目标号被其它分支占用（跨分支扫描口径）→ 抛错且不动文件', () async {
      final root = enterRenumberFixture();
      await expectLater(
        bug.cmdRenumber(
          <String>['5', '9'],
          scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6, 9}),
        ),
        throwsA(isA<bug.BugToolError>().having(
            (bug.BugToolError e) => e.message, 'message', contains('已被其它分支占用'))),
      );
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isFalse);
    });

    test('<old> 不存在 → 抛错', () async {
      enterRenumberFixture();
      await expectLater(
        bug.cmdRenumber(
          <String>['404', '405'],
          scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{}),
        ),
        throwsA(isA<bug.BugToolError>()
            .having((bug.BugToolError e) => e.message, 'message', contains('不存在'))),
      );
    });

    test('非纯数字参数 → 抛错', () async {
      enterRenumberFixture();
      await expectLater(
        bug.cmdRenumber(
          <String>['BUG-005', '9'],
          scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{}),
        ),
        throwsA(isA<bug.BugToolError>()
            .having((bug.BugToolError e) => e.message, 'message', contains('纯数字'))),
      );
    });
  });

  group('bug.dart renumber --dry-run', () {
    test('列出要改的文件与行，但一个字节都不落盘', () async {
      final root = enterRenumberFixture();
      final beforeLib = readFile(root, 'lib/foo.dart');
      final beforeDoc = readFile(root, 'docs/bugs/BUG-005-foo.md');
      final beforeIndex = readFile(root, 'docs/BUGS.md');

      await bug.cmdRenumber(
        <String>['5', '9', '--dry-run'],
        scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{5, 6}),
      );

      final printed = out.join('\n');
      expect(printed, contains('[dry-run]'));
      expect(printed, contains('docs/bugs/BUG-005-foo.md  →  docs/bugs/BUG-009-foo.md'));
      expect(printed, contains('hibiki/test/tools/bug_005_foo_test.dart'));
      expect(printed, contains('lib/foo.dart:1'));
      // 落盘检查：文件名与内容全部原样
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isFalse);
      expect(exists(root, 'hibiki/test/tools/bug_005_foo_test.dart'), isTrue);
      expect(readFile(root, 'lib/foo.dart'), beforeLib);
      expect(readFile(root, 'docs/bugs/BUG-005-foo.md'), beforeDoc);
      expect(readFile(root, 'docs/BUGS.md'), beforeIndex);
    });
  });

  group('bug 号引用正则口径', () {
    test('认 BUG-005 / bug_005 / bug-005，不认 debug-005 / BUG-0055 / BUG-5x', () {
      final re = bug.bugRefPattern(5);
      expect(re.hasMatch('修 BUG-005 的根因'), isTrue);
      expect(re.hasMatch('BUG-5'), isTrue);
      expect(re.hasMatch('bug_005_foo_test.dart'), isTrue);
      expect(re.hasMatch('bug-005-slug'), isTrue);
      expect(re.hasMatch('debug-005'), isFalse);
      expect(re.hasMatch('BUG-0055'), isFalse);
      expect(re.hasMatch('BUG-50'), isFalse);
      expect(re.hasMatch('XBUG-005'), isFalse);
    });

    test('renameNumberInPath 只动文件名部分', () {
      expect(bug.renameNumberInPath('docs/bugs/BUG-005-foo.md', 5, 9),
          'docs/bugs/BUG-009-foo.md');
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

  group('bug.dart new：跨分支取号', () {
    test('clone 之后别人才 push 的号也能扫到（真 fetch）→ 取全局最大 +1，无降级警告', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: false);
      Directory.current = worker;

      await bug.cmdNew(<String>['some-slug', '标题']);

      // 本地只看得到 BUG-003；远端 peer 分支占了 020 → 必须取 021 而不是 004。
      expect(exists(worker, 'docs/bugs/BUG-021-some-slug.md'), isTrue);
      expect(exists(worker, 'docs/bugs/BUG-004-some-slug.md'), isFalse);
      expect(out.join('\n'), contains('BUG-021'));
      expect(warn, isEmpty, reason: '远端扫描成功时不该有降级警告，实际：$warn');
    });

    test('远端不可达（fetch 失败）→ 降级到已缓存的 remote-tracking 引用，并显式警告可能撞号', () async {
      final worker = makeRemoteFixture(pushPeerBeforeClone: true);
      Directory.current = worker;
      git(worker, <String>['remote', 'set-url', 'origin', '${worker.path}/does-not-exist.git']);

      await bug.cmdNew(<String>['offline-slug', '标题']);

      final warned = warn.join('\n');
      expect(warned, contains('未能刷新远端分支'));
      expect(warned, contains('可能与并发分支相撞'),
          reason: '静默降级会让人误以为已经防住了撞号');
      // 缓存的 origin/peer 里有 020，所以仍然取 021。
      expect(exists(worker, 'docs/bugs/BUG-021-offline-slug.md'), isTrue);
    });

    test('完全不在 git 仓库里 → 只用本地号，且显式警告未能扫描远端分支', () async {
      final root = makeBareFixture('bug_nogit_');
      temps.add(root);
      writeFile(root, 'docs/bugs/BUG-003-base.md', bugDoc(3, '基线'));
      Directory.current = root;

      await bug.cmdNew(<String>['nogit-slug', '标题']);

      final warned = warn.join('\n');
      expect(warned, contains('未能扫描远端分支'));
      expect(warned, contains('可能与并发分支相撞'));
      expect(exists(root, 'docs/bugs/BUG-004-nogit-slug.md'), isTrue);
    });

    test('扫描器返回 stale/unavailable 时仍取号，fresh 时不警告', () async {
      final root = makeBareFixture('bug_stub_');
      temps.add(root);
      writeFile(root, 'docs/bugs/BUG-003-base.md', bugDoc(3, '基线'));
      Directory.current = root;

      await bug.cmdNew(
        <String>['stub-slug'],
        scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{3, 41}),
      );
      expect(exists(root, 'docs/bugs/BUG-042-stub-slug.md'), isTrue,
          reason: '要取「本地最大与跨分支最大」的全局最大 +1');
      expect(warn, isEmpty);
    });
  });

  group('bug.dart renumber：还没 commit 的新 bug 文件', () {
    test('untracked 文件 git mv 会失败，退回普通改名，四处照样改到', () async {
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
      writeFile(root, 'hibiki/test/tools/bug_005_foo_test.dart', '// BUG-005 守卫\n');
      Directory.current = root;

      await bug.cmdRenumber(
        <String>['5', '9'],
        scanner: stubScanner(bug.BranchScanStatus.fresh, <int>{}),
      );

      expect(exists(root, 'docs/bugs/BUG-009-foo.md'), isTrue);
      expect(exists(root, 'docs/bugs/BUG-005-foo.md'), isFalse);
      expect(readFile(root, 'docs/bugs/BUG-009-foo.md'), startsWith('## BUG-009 · '));
      expect(exists(root, 'hibiki/test/tools/bug_009_foo_test.dart'), isTrue);
      expect(readFile(root, 'lib/foo.dart'), contains('BUG-009'));
      expect(await bug.findResidualRefs(5), isEmpty);
      expect(bug.cmdCheck(), 0);
    });
  });
}

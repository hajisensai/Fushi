import 'dart:io';

import 'package:test/test.dart';

import '../../tool/test_flow/heavy_analyze_path.dart';
import '../../tool/test_flow/heavy_budget.dart' show HeavyKind;

/// tool/heavy.dart 在本机跑 analyze 时经轻槽的固定 junction 跑（分析缓存按绝对路径记，
/// 新 worktree 第一次跑是冷的）。改指 junction 时只能删 junction 本身，删到目标
/// worktree 里的内容就是丢用户代码，所以下面的文件系统用例是这条路的底线。
void main() {
  group('planHeavyAnalyzeVia', () {
    HeavyAnalyzeVia? plan({
      HeavyKind kind = HeavyKind.analyze,
      bool win = true,
      int? slot = 100,
      String? checkout = r'D:\wt',
      String cwd = r'D:\wt\fushi',
      String stateDir = r'C:\L\fushi-heavy',
      Map<String, String> env = const <String, String>{},
    }) => planHeavyAnalyzeVia(
      kind: kind,
      isWindows: win,
      slot: slot,
      checkout: checkout,
      cwd: cwd,
      stateDir: stateDir,
      environment: env,
    );

    test('Windows 本机 analyze：junction 在状态目录 analyze-<槽号>，cwd 同相对位置', () {
      final HeavyAnalyzeVia v = plan()!;
      expect(v.link, 'C:/L/fushi-heavy/analyze-100');
      expect(v.checkout, 'D:/wt');
      expect(v.cwd, 'C:/L/fushi-heavy/analyze-100/fushi');
      expect(
        plan(slot: 101, cwd: r'D:\WT\fushi\lib\')!.cwd,
        'C:/L/fushi-heavy/analyze-101/fushi/lib',
      );
      expect(plan(cwd: r'D:\wt')!.cwd, 'C:/L/fushi-heavy/analyze-100');
    });

    test('不走 junction 的情形', () {
      expect(plan(win: false), isNull);
      expect(plan(kind: HeavyKind.test), isNull);
      expect(plan(kind: HeavyKind.build), isNull);
      expect(plan(slot: null), isNull, reason: '没拿租约（CI / FUSHI_HEAVY=off）');
      expect(plan(checkout: null), isNull);
      expect(plan(cwd: r'D:\other\fushi'), isNull);
      expect(plan(cwd: r'D:\wt2\fushi'), isNull, reason: '前缀相同不算在 checkout 里');
      expect(
        plan(env: const <String, String>{kHeavyAnalyzeViaEnv: 'OFF'}),
        isNull,
      );
      expect(
        plan(
          checkout: r'C:\L\fushi-heavy\analyze-100',
          cwd: r'C:\L\fushi-heavy\analyze-100\fushi',
        ),
        isNull,
        reason: '已经从 junction 里启动，不能把 junction 指向自己',
      );
    });
  });

  group('unaliasHeavyAnalyzeOutput', () {
    const HeavyAnalyzeVia v = HeavyAnalyzeVia(
      link: 'C:/L/fushi-heavy/analyze-100',
      checkout: 'D:/wt',
      cwd: 'C:/L/fushi-heavy/analyze-100/fushi',
    );

    test('junction 路径写回原 worktree，保留打印时的分隔符', () {
      expect(
        unaliasHeavyAnalyzeOutput(
          r'error - x - C:\L\fushi-heavy\analyze-100\fushi\lib\a.dart:1:2 - y',
          v,
        ),
        r'error - x - D:\wt\fushi\lib\a.dart:1:2 - y',
      );
      expect(
        unaliasHeavyAnalyzeOutput(
          'file:///c:/l/FUSHI-HEAVY/analyze-100/fushi',
          v,
        ),
        'file:///D:/wt/fushi',
      );
    });

    test('相对路径与别的槽号原样', () {
      const String rel =
          r'warning - Unused import - lib\a.dart:1:8 - unused_import';
      expect(unaliasHeavyAnalyzeOutput(rel, v), rel);
      const String other = r'C:\L\fushi-heavy\analyze-1000\fushi';
      expect(unaliasHeavyAnalyzeOutput(other, v), other);
      const String sibling = r'C:\L\fushi-heavy\analyze-101\fushi';
      expect(unaliasHeavyAnalyzeOutput(sibling, v), sibling);
    });
  });

  group('junction 的建 / 改指 / 删（Windows）', () {
    late Directory tmp;
    late String a;
    late String b;
    late String link;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('heavy_analyze_path_');
      a = '${tmp.path}/wtA';
      b = '${tmp.path}/wtB';
      File('$a/fushi/lib/keep.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('A');
      File('$b/fushi/lib/keep.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('B');
      link = '${tmp.path}/state/analyze-100';
    });

    tearDown(() {
      // The link first, so the recursive delete below never meets it.
      removeHeavyAnalyzeLink(link);
      tmp.deleteSync(recursive: true);
    });

    test('建出来的是 junction，经它读到的是目标 worktree', () {
      pointHeavyAnalyzeLink(link, a);
      expect(
        FileSystemEntity.typeSync(link, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(File('$link/fushi/lib/keep.dart').readAsStringSync(), 'A');
      final ProcessResult dir = Process.runSync('cmd', <String>[
        '/c',
        'dir',
        '/AL',
        Directory(link).parent.path.replaceAll('/', r'\'),
      ]);
      expect('${dir.stdout}', contains('<JUNCTION>'));
    });

    test('改指只删 junction 本身，旧目标的文件一个不少', () {
      pointHeavyAnalyzeLink(link, a);
      pointHeavyAnalyzeLink(link, b);
      expect(File('$link/fushi/lib/keep.dart').readAsStringSync(), 'B');
      expect(File('$a/fushi/lib/keep.dart').readAsStringSync(), 'A');
      removeHeavyAnalyzeLink(link);
      expect(
        FileSystemEntity.typeSync(link, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(File('$a/fushi/lib/keep.dart').readAsStringSync(), 'A');
      expect(File('$b/fushi/lib/keep.dart').readAsStringSync(), 'B');
    });

    test('目标已被删掉的悬空 junction 也能改指', () {
      pointHeavyAnalyzeLink(link, a);
      Directory(a).deleteSync(recursive: true);
      pointHeavyAnalyzeLink(link, b);
      expect(File('$link/fushi/lib/keep.dart').readAsStringSync(), 'B');
    });

    test('路径上是真目录时拒绝动它，open 退回真实路径', () {
      File('$link/mine.txt')
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      expect(
        () => pointHeavyAnalyzeLink(link, a),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('$link/mine.txt').readAsStringSync(), 'mine');
      final List<String> logs = <String>[];
      final HeavyAnalyzeVia? v = openHeavyAnalyzeVia(
        HeavyAnalyzeVia(link: link, checkout: a, cwd: '$link/fushi'),
        log: logs.add,
      );
      expect(v, isNull);
      expect(logs.single, contains('analyzing from the real path'));
      expect(File('$link/mine.txt').readAsStringSync(), 'mine');
      Directory(link).deleteSync(recursive: true);
    });

    test('closeHeavyAnalyzeVia 跑完删掉 junction，目标不动', () {
      final HeavyAnalyzeVia? v = openHeavyAnalyzeVia(
        HeavyAnalyzeVia(link: link, checkout: a, cwd: '$link/fushi'),
        log: (String l) => fail(l),
      );
      expect(v, isNotNull);
      closeHeavyAnalyzeVia(v, log: (String l) => fail(l));
      expect(
        FileSystemEntity.typeSync(link, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(File('$a/fushi/lib/keep.dart').readAsStringSync(), 'A');
    });
  }, skip: Platform.isWindows ? false : 'junction 只在 Windows 上用');
}

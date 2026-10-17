// 守卫：golden-tests.yml 的「golden 只能放在 test/goldens」那一步真能抓到所有写法。
//
// 背景（BUG-3494）：golden workflow 只跑 `flutter test --tags golden test/goldens`，
// 放在别处的 golden 会被静默漏跑，所以 workflow 先用 grep 找「带 golden 标签却不在
// test/goldens 下」的文件。最初那条 grep 按行匹配，而 dart format 会把
// 多标签的 `@Tags(<String>[...])` 拆成多行——那种写法整个漏掉，守卫恒绿。
// 现在用 `grep -z`（整个文件一条记录，`[^;]*` 可以跨行）。
//
// 本测试：
//   1. 从 workflow 里抠出那条 grep 的正则（单一真相源，不在这里另写一份）；
//   2. 用正 / 负样本钉住它的语义，含「按行匹配会漏」的变异对照；
//   3. 本机有 grep 时，用真 grep 跑同一批样本，证明 `-z` 的跨行语义成立；
//   4. 扫 test/ 全树，断言所有带 golden 标签的文件都在 test/goldens 下。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 从当前 cwd 向上找仓库根（含 .github/workflows/golden-tests.yml）。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/.github/workflows/golden-tests.yml').existsSync()) {
      return dir;
    }
    dir = dir.parent;
  }
  throw StateError('找不到仓库根（.github/workflows/golden-tests.yml）');
}

/// workflow 里 golden 位置守卫那条 grep 的 bash 源文本。
final RegExp _grepLine = RegExp(r'grep -rl(\w*)E "((?:[^"\\]|\\.)*)" test');

/// bash 双引号串里的 `\"` / `\\` 还原成 grep 实际收到的字符。
String _bashUnescape(String s) =>
    s.replaceAllMapped(RegExp(r'\\(["\\$`])'), (Match m) => m.group(1)!);

/// 样本里的标签名经拼接产生：本文件自身的源码不能含带引号的标签字面量，
/// 否则 workflow 的 grep 与下面的全树扫描都会把本文件当成放错地方的 golden。
const String _g =
    'gold'
    'en';

void main() {
  final Directory root = _repoRoot();
  final String workflow = File(
    '${root.path}/.github/workflows/golden-tests.yml',
  ).readAsStringSync();
  final RegExpMatch? grep = _grepLine.firstMatch(workflow);

  test('workflow 用 grep -z（整文件一条记录），否则多行 @Tags 漏网', () {
    expect(grep, isNotNull, reason: 'golden-tests.yml 里找不到位置守卫的 grep');
    expect(
      grep!.group(1),
      contains('z'),
      reason: '按行 grep 抓不到被 dart format 拆成多行的 @Tags([...])',
    );
  });

  final String pattern = _bashUnescape(grep?.group(2) ?? r'$^');
  final RegExp tagged = RegExp(pattern);

  final Map<String, String> positives = <String, String>{
    'library 单行 @Tags': "@Tags(<String>['$_g'])\nlibrary;\n",
    'library 多行 @Tags（dart format 拆行）':
        "@Tags(<String>[\n  '$_g',\n  'realdata',\n])\nlibrary;\n",
    '标签不在首位且跨行': "@Tags(<String>[\n  'chrome',\n  '$_g',\n])\nlibrary;\n",
    '用例级 tags: 单行': "testWidgets('x', (t) async {}, tags: <String>['$_g']);\n",
    '用例级 tags: 跨行':
        "testWidgets('x', (t) async {},\n    tags: <String>[\n  '$_g',\n]);\n",
    '双引号': '@Tags(<String>["$_g"])\nlibrary;\n',
  };
  final Map<String, String> negatives = <String, String>{
    '别的标签': "@Tags(<String>['ffmpeg'])\nlibrary;\n",
    '只用 matchesGoldenFile 不打标签':
        "void main() { expectLater(f, matchesGoldenFile('golden_files/a.png')); }\n",
    '标签语句之后另一条语句里出现标签名':
        "test('x', () {}, tags: <String>['chrome']);\nconst String k = '$_g';\n",
    '标签名只是前缀相同': "@Tags(<String>['${_g}_extra'])\nlibrary;\n",
  };

  group('workflow 正则的语义', () {
    positives.forEach((String name, String src) {
      test('命中：$name', () {
        expect(tagged.hasMatch(src), isTrue, reason: src);
      });
    });
    negatives.forEach((String name, String src) {
      test('不命中：$name', () {
        expect(tagged.hasMatch(src), isFalse, reason: src);
      });
    });

    test('变异对照：同一正则按行匹配会漏掉多行写法（这正是改 -z 的原因）', () {
      bool lineWise(String src) => src.split('\n').any(tagged.hasMatch);
      final List<String> missedLineWise = positives.entries
          .where((MapEntry<String, String> e) => !lineWise(e.value))
          .map((MapEntry<String, String> e) => e.key)
          .toList();
      expect(missedLineWise, isNotEmpty, reason: '若按行也全命中，多行样本就没起到变异对照作用');
      for (final String name in missedLineWise) {
        expect(
          tagged.hasMatch(positives[name]!),
          isTrue,
          reason: '整文件匹配必须抓到「$name」',
        );
      }
    });
  });

  test('真 grep -z 与上面的语义一致（本机无 grep 时跳过）', () {
    final Directory tmp = Directory.systemTemp.createTempSync('golden_grep_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final Map<String, bool> expected = <String, bool>{};
    int i = 0;
    positives.forEach((String name, String src) {
      final String f = '${tmp.path}/p${i++}_test.dart';
      File(f).writeAsStringSync(src);
      expected[f] = true;
    });
    negatives.forEach((String name, String src) {
      final String f = '${tmp.path}/n${i++}_test.dart';
      File(f).writeAsStringSync(src);
      expected[f] = false;
    });
    final ProcessResult r;
    try {
      r = Process.runSync('grep', <String>[
        '-l${grep!.group(1)}E',
        pattern,
        ...expected.keys,
      ]);
    } on ProcessException {
      markTestSkipped('本机 PATH 上没有 grep');
      return;
    }
    expect(r.exitCode, anyOf(0, 1), reason: '${r.stderr}');
    final Set<String> hits = (r.stdout as String)
        .split(RegExp(r'\r?\n'))
        .where((String l) => l.isNotEmpty)
        .map((String l) => File(l).absolute.path)
        .toSet();
    expected.forEach((String f, bool want) {
      expect(
        hits.contains(File(f).absolute.path),
        want,
        reason: '真 grep 对 ${File(f).readAsStringSync()} 的判定与预期不符',
      );
    });
  });

  test('test/ 下所有带 golden 标签的文件都在 test/goldens 里', () {
    final Directory testDir = Directory('${root.path}/fushi/test');
    final List<String> tagged0 = <String>[];
    final List<String> stray = <String>[];
    for (final FileSystemEntity e in testDir.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('_test.dart')) continue;
      if (!tagged.hasMatch(e.readAsStringSync())) continue;
      final String rel = e.path
          .substring(testDir.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      tagged0.add(rel);
      if (!rel.startsWith('goldens/')) stray.add(rel);
    }
    expect(tagged0, isNotEmpty, reason: '一个 golden 都没扫到，正则或路径失真');
    expect(
      stray,
      isEmpty,
      reason: '这些 golden 不在 test/goldens 下，golden workflow 不会跑到：$stray',
    );
  });
}

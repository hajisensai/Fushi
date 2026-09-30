import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（BUG-2804）：workflow 里不得把一个变量 `printf` 进 `grep -q`。
///
/// GitHub Actions 的 bash 默认带 `-o pipefail`。`grep -q` 一命中就退出，若写端（这里
/// 是 `printf "$var"`）还没把内容写完——内容一过 64KB 管道缓冲就会发生——写端收到
/// SIGPIPE，整条管道的退出码变成非零，`if ! … | grep -q` 于是把「找到了」读成「没有」。
/// 2026-09-29 release.yml 的「fushi_p2p 是否进 APK」校验就这样在 2f08d46 / 248238cf7
/// 连续假红（日志 `printf: write error: Broken pipe`），而 APK 里其实有那个 .so。
/// 本地 1.2MB 清单复现：旧写法 200/200 误判、here-string 0/200。
///
/// 正确写法：`grep -q PATTERN <<< "$var"`（没有管道，也就没有 SIGPIPE）。
/// 只抓「变量经 printf 喂给 grep -q」：`file x | grep -q` 这类写端输出极短的不在此列。
final RegExp _printfVarIntoGrepQ = RegExp(
  r'''printf\s+[^|\n]*"\$\{?\w+\}?"[^|\n]*\|\s*grep\s+-[A-Za-z]*q''',
);

List<String> _offenders(String yaml, String label) {
  final List<String> hits = <String>[];
  final List<String> lines = yaml.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    if (line.trimLeft().startsWith('#')) continue;
    if (_printfVarIntoGrepQ.hasMatch(line)) {
      hits.add('$label:${i + 1}: ${line.trim()}');
    }
  }
  return hits;
}

void main() {
  test('判据自校验：抓得到违规写法，放过正确写法（合成语料）', () {
    const String bad = '''
      if ! printf '%s\\n' "\$listing" | grep -qx "lib/\$abi/libfushi_p2p.so"; then
      printf '%s' "\${out}" | grep -q needle
      printf "%s\\n" "\$x" | grep -Eq 'a|b'
''';
    const String good = '''
      if ! grep -qx "lib/\$abi/libfushi_p2p.so" <<< "\$listing"; then
      if file "\$candidate" | grep -q 'Mach-O'; then
      # printf '%s\\n' "\$listing" | grep -qx "commented out"
      printf '%s\\n' "\$listing" | sed -n 's#x#y#p'
''';
    expect(_offenders(bad, 'bad'), hasLength(3));
    expect(_offenders(good, 'good'), isEmpty);
  });

  test('所有 workflow 都不把变量 printf 进 grep -q', () {
    final List<File> workflows = Directory('../.github/workflows')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
        .toList();
    // 规模哨兵：枚举塌了（路径变了）时「零命中」与「全干净」退出码一样。
    expect(workflows.length, greaterThan(10));
    final List<String> hits = <String>[
      for (final File f in workflows)
        ..._offenders(f.readAsStringSync(), f.uri.pathSegments.last),
    ];
    expect(
      hits,
      isEmpty,
      reason:
          'pipefail 下 `printf "\$var" | grep -q` 会因 SIGPIPE 把命中读成未命中'
          '（BUG-2804）。改用 `grep -q PATTERN <<< "\$var"`：\n${hits.join('\n')}',
    );
  });
}

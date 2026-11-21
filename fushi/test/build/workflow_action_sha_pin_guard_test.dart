import 'dart:io';

import 'package:test/test.dart';

/// 守卫：`.github/` 下所有 workflow 与组合 action 引用的外部 action / 可复用
/// workflow 必须钉 40 位 commit SHA，并在行尾注释写版本（`@<sha> # v6.1.0`）。
///
/// 起因（拍板台 ci-pin-actions，2026-11-17 维护者选 A）：全仓几十处
/// `dtolnay/rust-toolchain@master`、`Swatinem/rust-cache@v2`、`actions/checkout@v6`
/// 这类浮动引用，包括会接触签名密钥的 release*.yml。上游分支 / tag 一旦被篡改，
/// 下一次 CI 就会执行任意代码。tag 可以被强推移动，只有 commit SHA 不可变。
///
/// 升级由 `.github/dependabot.yml` 的 github-actions 条目每周合成一个 PR；
/// 行尾版本注释是 Dependabot 识别版本、同步改注释的依据，所以也必须写。
/// 本仓自己的组合 action（`uses: ./...`）与 `docker://` 镜像不在此列。
final RegExp _uses = RegExp(r'^\s*(?:-\s+)?uses:\s*(\S+)(.*)$');
final RegExp _pinned = RegExp(r'^[^@\s]+@[0-9a-f]{40}$');
final RegExp _versionComment = RegExp(r'^\s+#\s*\S+');

/// 返回 `yaml` 里不合规的 `uses:` 行（`行号: 原文`）。
List<String> _unpinned(String yaml) {
  final List<String> bad = <String>[];
  final List<String> lines = yaml.split('\n');
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i].trimRight();
    if (line.trimLeft().startsWith('#')) continue;
    final RegExpMatch? m = _uses.firstMatch(line);
    if (m == null) continue;
    final String ref = m.group(1)!;
    if (ref.startsWith('./') || ref.startsWith('docker://')) continue;
    if (!_pinned.hasMatch(ref) || !_versionComment.hasMatch(m.group(2)!)) {
      bad.add('${i + 1}: ${line.trim()}');
    }
  }
  return bad;
}

List<File> _githubYamlFiles() {
  return Directory('../.github')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
      .where(
        (File f) => !f.path.replaceAll('\\', '/').endsWith('dependabot.yml'),
      )
      .toList();
}

void main() {
  test('判据自校验（合成语料）', () {
    const String sha = 'd23441a48e516b6c34aea4fa41551a30e30af803';
    const String yaml =
        '''
jobs:
  a:
    steps:
      - uses: actions/checkout@$sha # v6.1.0
      - uses: ./.github/actions/gen-i18n
      - uses: docker://alpine:3.20
      # - uses: actions/checkout@v6
      - name: x
        uses: org/repo/sub/path@$sha # v1.2.3
      - uses: actions/checkout@v6
      - uses: dtolnay/rust-toolchain@master
      - uses: actions/checkout@$sha
      - uses: actions/checkout@d23441a48e51 # v6
  reusable:
    uses: org/repo/.github/workflows/x.yml@develop
''';
    expect(_unpinned(yaml), <String>[
      '10: - uses: actions/checkout@v6',
      '11: - uses: dtolnay/rust-toolchain@master',
      '12: - uses: actions/checkout@$sha',
      '13: - uses: actions/checkout@d23441a48e51 # v6',
      '15: uses: org/repo/.github/workflows/x.yml@develop',
    ]);
  });

  test('.github 下所有外部 action 都钉 40 位 SHA 并注明版本', () {
    final List<File> files = _githubYamlFiles();
    expect(files.length, greaterThan(30), reason: '应扫到全部 workflow 与组合 action');
    final List<String> failures = <String>[];
    int checked = 0;
    for (final File f in files) {
      final String yaml = f.readAsStringSync().replaceAll('\r\n', '\n');
      checked += RegExp(
        r'^\s*(?:-\s+)?uses:\s*(?!\./)',
        multiLine: true,
      ).allMatches(yaml).length;
      for (final String hit in _unpinned(yaml)) {
        failures.add('${f.path}:$hit');
      }
    }
    expect(checked, greaterThan(100), reason: '扫描到的外部 uses: 过少，解析可能失效');
    expect(
      failures,
      isEmpty,
      reason:
          '外部 action 必须写成 `owner/repo@<40 位 SHA> # <版本>`'
          '（gh api repos/<owner>/<repo>/commits/<tag> 取 SHA），'
          '浮动的 tag / 分支可被上游改写：\n${failures.join('\n')}',
    );
  });

  test('Dependabot 覆盖 workflows 与组合 action 并提到 develop', () {
    final String cfg = File(
      '../.github/dependabot.yml',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(cfg, contains('package-ecosystem: github-actions'));
    expect(cfg, contains('- "/"\n'));
    expect(cfg, contains('- "/.github/actions/*"'));
    expect(cfg, contains('target-branch: develop'));
  });
}

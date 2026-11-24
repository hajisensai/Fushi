import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 拍板台 RRYro9vSEU（选 a）：滚动调试版 release 每次发布后把 tag 挪到「现在」的提交，
/// 让它排在 GitHub Releases 列表顶部附近。
///
/// 跑的是**真脚本** `tool/bump_rolling_release_tag.sh`，PATH 最前面放一个假 `gh`
/// （记下每次调用的参数、按端点回固定值、可指定某个端点失败），断言：
/// - 只挪 tag（git/refs PATCH），从不删 release / 删资产——release id、资产与
///   `releases/download/<tag>/<name>` 下载链接都不受影响；
/// - 新提交的 tree 与父提交都取默认分支尖端（不让 tag 指向 develop 提交，见脚本头注释）；
/// - 非 `*-debug-rolling` 的 tag 一律不碰；
/// - 任何一步失败都只 ::warning、退出 0（资产已发完，下一次发布自愈）。
///
/// 另钉两条 workflow 都在 softprops 发布之后、只在 rolling debug 时调用它。
void main() {
  // 相对路径字面量 `../tool/…` 让 ci-config-gate.yml 的磁盘枚举把本测试收进去。
  final File script = File('../tool/bump_rolling_release_tag.sh').absolute;

  const String oldSha = '1111111111111111111111111111111111111111';
  const String baseSha = '2222222222222222222222222222222222222222';
  const String treeSha = '3333333333333333333333333333333333333333';
  const String newSha = '4444444444444444444444444444444444444444';
  const String buildSha = '5555555555555555555555555555555555555555';

  late Directory tmp;
  late File log;

  setUpAll(() {
    expect(script.existsSync(), isTrue, reason: '缺 ${script.path}');
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('bump_rolling_tag_');
    log = File(p.join(tmp.path, 'gh.log'));
    final File fakeGh = File(p.join(tmp.path, 'bin', 'gh'))
      ..createSync(recursive: true);
    // 每次调用一行，参数之间用 \x1f 分隔，便于还原带空格 / 换行的参数（提交信息）。
    fakeGh.writeAsStringSync(r'''#!/usr/bin/env bash
{ for a in "$@"; do printf '%s\037' "${a//$'\n'/\\n}"; done; printf '\n'; } >> "$FAKE_GH_LOG"
all="$*"
if [ -n "${FAKE_GH_FAIL:-}" ] && [[ "$all" == *"$FAKE_GH_FAIL"* ]]; then
  echo "HTTP 403: Resource not accessible by integration" >&2
  exit 1
fi
case "$all" in
  *"-X PATCH"*"/git/refs/tags/"*) echo "${FAKE_PATCH_SHA:-$FAKE_NEW}" ;;
  *"-X POST"*"/git/commits"*) echo "$FAKE_NEW" ;;
  *"/git/ref/tags/"*) echo "$FAKE_OLD" ;;
  *"/git/ref/heads/"*) echo "$FAKE_BASE" ;;
  *"/git/commits/"*) echo "$FAKE_TREE" ;;
  *) echo "unexpected gh call: $all" >&2; exit 2 ;;
esac
''');
    if (!Platform.isWindows) {
      Process.runSync('chmod', <String>['+x', fakeGh.path]);
    }
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<ProcessResult> run({
    String tag = 'fushi-debug-rolling',
    String? fail,
    String? patchSha,
  }) {
    final String sep = Platform.isWindows ? ';' : ':';
    return Process.run(
      _bashExecutable(),
      <String>[script.path],
      environment: <String, String>{
        'PATH': '${p.join(tmp.path, 'bin')}$sep${Platform.environment['PATH']}',
        'FAKE_GH_LOG': log.path,
        'FAKE_OLD': oldSha,
        'FAKE_BASE': baseSha,
        'FAKE_TREE': treeSha,
        'FAKE_NEW': newSha,
        if (fail != null) 'FAKE_GH_FAIL': fail,
        if (patchSha != null) 'FAKE_PATCH_SHA': patchSha,
        'REPO': 'owner/repo',
        'PUBLISH_TAG': tag,
        'DEFAULT_BRANCH': 'main',
        'BUILD_SHA': buildSha,
        'GH_TOKEN': 'test-token',
      },
    );
  }

  List<List<String>> calls() => log.existsSync()
      ? log
            .readAsLinesSync()
            .where((String l) => l.isNotEmpty)
            .map((String l) => l.split('\x1f')..removeLast())
            .toList()
      : <List<String>>[];

  test('挪 tag：新提交 tree / 父 = 默认分支尖端，force 更新 ref，不删 release', () async {
    final ProcessResult r = await run();
    expect(r.exitCode, 0, reason: _io(r));
    expect(r.stdout, isNot(contains('::warning')), reason: _io(r));
    expect(r.stdout, contains('Moved fushi-debug-rolling: $oldSha -> $newSha'));

    final List<List<String>> c = calls();
    expect(c, hasLength(5), reason: c.join('\n'));
    expect(c[0], <String>[
      'api',
      'repos/owner/repo/git/ref/tags/fushi-debug-rolling',
      '--jq',
      '.object.sha',
    ]);
    expect(c[1], <String>[
      'api',
      'repos/owner/repo/git/ref/heads/main',
      '--jq',
      '.object.sha',
    ]);
    expect(c[2], <String>[
      'api',
      'repos/owner/repo/git/commits/$baseSha',
      '--jq',
      '.tree.sha',
    ]);

    final List<String> post = c[3];
    expect(post.take(3), <String>['api', '-X', 'POST']);
    expect(post[3], 'repos/owner/repo/git/commits');
    expect(post, contains('tree=$treeSha'));
    expect(post, contains('parents[]=$baseSha'));
    final String message = post.firstWhere(
      (String a) => a.startsWith('message='),
    );
    expect(message, contains('debug build of $buildSha'));

    expect(c[4], <String>[
      'api',
      '-X',
      'PATCH',
      'repos/owner/repo/git/refs/tags/fushi-debug-rolling',
      '-f',
      'sha=$newSha',
      '-F',
      'force=true',
      '--jq',
      '.object.sha',
    ]);

    for (final List<String> call in c) {
      expect(call.first, 'api', reason: '只许走 git 数据 API：$call');
      expect(
        call.where((String a) => a.startsWith('repos/')).single,
        startsWith('repos/owner/repo/git/'),
        reason: '$call',
      );
      expect(call, isNot(contains('DELETE')), reason: '$call');
    }
  });

  test('非 *-debug-rolling 的 tag 一律不碰', () async {
    for (final String tag in <String>['v3.3.0', 'v3.4.0-beta.1', 'debug']) {
      log.writeAsStringSync('');
      final ProcessResult r = await run(tag: tag);
      expect(r.exitCode, 0, reason: _io(r));
      expect(r.stdout, contains('::warning'), reason: _io(r));
      expect(calls(), isEmpty, reason: tag);
    }
  });

  group('任何一步失败：只 ::warning、退出 0、不往下走', () {
    final Map<String, int> expectedCalls = <String, int>{
      // tag 还不存在（release 没建出来）：不凭空造 tag。
      '/git/ref/tags/': 1,
      '/git/ref/heads/': 2,
      'commits/$baseSha': 3,
      '-X POST': 4,
      '-X PATCH': 5,
    };
    for (final MapEntry<String, int> e in expectedCalls.entries) {
      test(e.key, () async {
        final ProcessResult r = await run(fail: e.key);
        expect(r.exitCode, 0, reason: _io(r));
        expect(r.stdout, contains('::warning'), reason: _io(r));
        expect(r.stdout, isNot(contains('Moved ')), reason: _io(r));
        expect(calls(), hasLength(e.value), reason: calls().join('\n'));
      });
    }

    test('PATCH 回来的 sha 不是新提交也算失败', () async {
      final ProcessResult r = await run(patchSha: oldSha);
      expect(r.exitCode, 0, reason: _io(r));
      expect(r.stdout, contains('::warning'), reason: _io(r));
      expect(r.stdout, isNot(contains('Moved ')), reason: _io(r));
    });
  });

  group('两条发布 workflow 都在 softprops 发布之后挪 rolling tag', () {
    const Map<String, String> publishStep = <String, String>{
      'release.yml': 'name: Publish Android channel release',
      'release-desktop.yml': 'name: Publish desktop channel release',
    };
    for (final MapEntry<String, String> e in publishStep.entries) {
      test(e.key, () {
        final String yaml = File(
          '../.github/workflows/${e.key}',
        ).readAsStringSync().replaceAll('\r\n', '\n');
        const String stepName =
            'name: Bump rolling debug tag to keep it near the top of Releases';
        expect(stepName.allMatches(yaml), hasLength(1));
        final int publish = yaml.indexOf(e.value);
        final int bump = yaml.indexOf(stepName);
        expect(publish, greaterThan(0));
        expect(
          bump,
          greaterThan(publish),
          reason: '首次发布时 tag 由 softprops 建出来，挪 tag 必须排在它之后',
        );
        final int next = yaml.indexOf('- name:', bump + stepName.length);
        final String step = yaml.substring(bump, next < 0 ? yaml.length : next);
        expect(
          step,
          contains(
            "if: steps.channel.outputs.publish_managed_release == 'true' "
            "&& steps.channel.outputs.rolling_debug == 'true'",
          ),
          reason: '只挪 rolling debug 的 tag，beta / 正式版 tag 不动',
        );
        expect(step, contains('continue-on-error: true'));
        expect(
          step,
          contains(
            r'DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}',
          ),
        );
        expect(
          step,
          contains(r'PUBLISH_TAG: ${{ steps.channel.outputs.publish_tag }}'),
        );
        expect(step, contains('run: bash tool/bump_rolling_release_tag.sh'));
        // 方案 a 的落地方式是挪 tag，不是删 release 重建：删了会连带另一条
        // workflow 并行传上来的资产，还会留出下载 404 的窗口期。
        expect(yaml, isNot(contains(r'gh release delete "$PUBLISH_TAG"')));
        expect(yaml, isNot(contains('gh release delete fushi-debug-rolling')));
      });
    }
  });
}

String _io(ProcessResult r) =>
    'exit=${r.exitCode}\nstdout=${r.stdout}\nstderr=${r.stderr}';

/// Windows 上 `Process.start('bash')` 先命中 System32 的 WSL bash，顺着 git 的安装
/// 位置找 Git Bash（同 feedback_mark_released_script_test.dart）。
String _bashExecutable() {
  if (!Platform.isWindows) return 'bash';
  final ProcessResult where = Process.runSync('where', <String>['git']);
  for (final String line in (where.stdout as String).split(RegExp(r'\r?\n'))) {
    final String gitPath = line.trim();
    if (gitPath.isEmpty) continue;
    Directory dir = File(gitPath).parent;
    for (int i = 0; i < 3; i++) {
      final File bash = File(p.join(dir.path, 'bin', 'bash.exe'));
      if (bash.existsSync()) return bash.path;
      dir = dir.parent;
    }
  }
  return 'bash';
}

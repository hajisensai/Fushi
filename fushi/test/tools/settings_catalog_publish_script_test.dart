import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 设置项目录同步链路（app 设置 schema → update-manifest 分支 → 官网
/// fushi.moe/settings.md）的两段守卫：
///
/// 1. 真跑 `tool/publish_settings_catalog.sh`，对着本地裸仓库（不联网）断言：只动
///    本通道的两个目录文件、分支上别的文件原样保留、内容没变不产生提交、坏输入
///    不覆盖好目录；
/// 2. 靠字符串对上的接线：导出器的环境变量名、release.yml 传的 artifact 名，以及
///    release.yml 里发布 job 的触发条件 / 权限。任何一处走样，目录就静静地不再更新。
///    发布不能放进 `workflow_run` workflow：它只认默认分支 main 上的定义，main 落后
///    develop 一个发布周期，合进 develop 后要等下一个正式版才第一次触发。
void main() {
  final Directory workspace = Directory.current.parent;
  final File script = File(
    p.join(workspace.path, 'tool', 'publish_settings_catalog.sh'),
  );

  const String goodJson =
      '{\n "schema": 1,\n "settings": [{"key": "a.b"}]\n}\n';
  const String goodMd = '# Fushi settings reference\n\n| Key | Name |\n';

  group('publish_settings_catalog.sh', () {
    late Directory root;
    late Directory origin;
    late String originUrl;

    Future<String> git(List<String> args, {Directory? cwd}) async {
      final ProcessResult r = await Process.run(
        'git',
        args,
        workingDirectory: (cwd ?? root).path,
      );
      expect(r.exitCode, 0, reason: 'git ${args.join(' ')}\n${r.stderr}');
      return (r.stdout as String).trim();
    }

    Directory catalogDir(String name, {String? json, String? md}) {
      final Directory dir = Directory(p.join(root.path, name))
        ..createSync(recursive: true);
      if (json != null) {
        File(p.join(dir.path, 'settings-catalog.json')).writeAsStringSync(json);
      }
      if (md != null) {
        File(p.join(dir.path, 'settings-catalog.md')).writeAsStringSync(md);
      }
      return dir;
    }

    Future<ProcessResult> publish(Directory dir, String channel) => Process.run(
      'bash',
      <String>[script.path],
      workingDirectory: root.path,
      environment: <String, String>{
        'GITHUB_TOKEN': 'dummy-token',
        'REPO': 'owner/repo',
        'CATALOG_DIR': dir.path,
        'CHANNEL': channel,
        'MANIFEST_REMOTE_OVERRIDE': originUrl,
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@example.com',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@example.com',
      },
    );

    Future<List<String>> branchFiles() async => (await git(<String>[
      '-C',
      origin.path,
      'ls-tree',
      '--name-only',
      'update-manifest',
    ])).split('\n').where((String s) => s.isNotEmpty).toList();

    Future<String> show(String file) =>
        git(<String>['-C', origin.path, 'show', 'update-manifest:$file']);

    Future<int> commitCount() async => int.parse(
      await git(<String>[
        '-C',
        origin.path,
        'rev-list',
        '--count',
        'update-manifest',
      ]),
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fushi_settings_catalog_');
      origin = Directory(p.join(root.path, 'origin.git'));
      await git(<String>['init', '-q', '--bare', origin.path]);
      originUrl = Uri.file(origin.path, windows: Platform.isWindows).toString();
      // 分支上已有发布流程写的清单：目录发布绝不能碰它。
      final Directory seed = Directory(p.join(root.path, 'seed'))..createSync();
      await git(<String>['init', '-q', '.'], cwd: seed);
      await git(<String>[
        'checkout',
        '-q',
        '--orphan',
        'update-manifest',
      ], cwd: seed);
      File(
        p.join(seed.path, 'latest-stable-fushi.json'),
      ).writeAsStringSync('{"tag":"v1"}\n');
      await git(<String>['add', 'latest-stable-fushi.json'], cwd: seed);
      await git(<String>[
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '-q',
        '-m',
        'seed',
      ], cwd: seed);
      await git(<String>[
        'push',
        '-q',
        originUrl,
        'update-manifest',
      ], cwd: seed);
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('写本通道的两个文件，保留分支上别的文件；内容没变不再提交', () async {
      final Directory dir = catalogDir('cat', json: goodJson, md: goodMd);
      final ProcessResult first = await publish(dir, 'debug');
      expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
      expect(await branchFiles(), <String>[
        'latest-stable-fushi.json',
        'settings-catalog-debug.json',
        'settings-catalog-debug.md',
      ]);
      expect(await show('latest-stable-fushi.json'), '{"tag":"v1"}');
      expect(
        await show('settings-catalog-debug.md'),
        contains('# Fushi settings reference'),
      );
      expect(await commitCount(), 2);

      final ProcessResult again = await publish(dir, 'debug');
      expect(again.exitCode, 0, reason: '${again.stdout}\n${again.stderr}');
      expect(again.stdout, contains('unchanged'));
      expect(await commitCount(), 2);
    });

    test('stable 与 debug 各写各的文件', () async {
      final Directory debug = catalogDir('d', json: goodJson, md: goodMd);
      final Directory stable = catalogDir(
        's',
        json: goodJson,
        md: '$goodMd| `only.stable` |\n',
      );
      expect((await publish(debug, 'debug')).exitCode, 0);
      expect((await publish(stable, 'stable')).exitCode, 0);
      expect(await show('settings-catalog-stable.md'), contains('only.stable'));
      expect(
        await show('settings-catalog-debug.md'),
        isNot(contains('only.stable')),
      );
    });

    test('不像目录的输入、缺文件、未知通道：退出非零且分支不动', () async {
      final Directory good = catalogDir('good', json: goodJson, md: goodMd);
      expect((await publish(good, 'debug')).exitCode, 0);
      final int before = await commitCount();

      final Directory truncated = catalogDir(
        'truncated',
        json: '{"error": "oops"}',
        md: goodMd,
      );
      expect((await publish(truncated, 'debug')).exitCode, isNot(0));
      final Directory missing = catalogDir('missing', json: goodJson);
      expect((await publish(missing, 'debug')).exitCode, isNot(0));
      expect((await publish(good, 'beta')).exitCode, isNot(0));

      expect(await commitCount(), before);
      expect(await show('settings-catalog-debug.json'), contains('"a.b"'));
    });

    test('与 publish-android 并发推同一分支：被拒后在远端新 tip 上重放，不丢对方的文件', () async {
      // 远端 pre-receive 钩子模拟发布 job 抢先一步：第一次推送时先往 update-manifest
      // 写进一份 latest-debug-fushi.json（相当于 publish-android 刚推完），再拒掉这次推送。
      // 钩子在隔离区里跑，要写真实对象库与 ref 得先摘掉隔离区环境变量。
      final File hook = File(p.join(origin.path, 'hooks', 'pre-receive'));
      hook.writeAsStringSync(r'''#!/bin/sh
cat >/dev/null
[ -f raced ] && exit 0
touch raced
env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES sh -ec '
blob=$(printf "{\"tag\":\"debug-2\"}\n" | git hash-object -w --stdin)
tree=$( { git ls-tree update-manifest; printf "100644 blob %s\tlatest-debug-fushi.json\n" "$blob"; } | git mktree)
commit=$(git commit-tree "$tree" -p update-manifest -m "release job")
git update-ref refs/heads/update-manifest "$commit"
'
echo "simulated race: update-manifest moved" >&2
exit 1
''');
      if (!Platform.isWindows) {
        expect(
          (await Process.run('chmod', <String>['+x', hook.path])).exitCode,
          0,
        );
      }

      final Directory dir = catalogDir('cat', json: goodJson, md: goodMd);
      final ProcessResult r = await publish(dir, 'debug');
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(r.stdout, contains('attempt 2'));
      expect(await branchFiles(), <String>[
        'latest-debug-fushi.json',
        'latest-stable-fushi.json',
        'settings-catalog-debug.json',
        'settings-catalog-debug.md',
      ]);
      expect(await show('latest-debug-fushi.json'), '{"tag":"debug-2"}');
      // seed + 抢先的发布提交 + 目录提交：目录提交接在对方提交之后，不是覆盖。
      expect(await commitCount(), 3);
    });
  });

  group('接线', () {
    String read(String relative) =>
        File(p.join(workspace.path, relative)).readAsStringSync();

    test('release.yml 用导出器认的环境变量落盘，并传名为 settings-catalog 的 artifact', () {
      final String exporter = read(
        'fushi/test/settings/settings_catalog_export_test.dart',
      );
      final String env = RegExp(
        r"kSettingsCatalogDirEnv =\s*'([A-Z_]+)'",
      ).firstMatch(exporter)!.group(1)!;
      final String release = read('.github/workflows/release.yml');
      expect(release, contains('$env: '));
      expect(
        release,
        contains('test/settings/settings_catalog_export_test.dart'),
      );
      expect(release, contains('name: settings-catalog'));
      final String publishJob = _jobBlock(release, 'publish-settings-catalog');
      expect(publishJob, contains('actions/download-artifact@'));
      expect(publishJob, contains('name: settings-catalog\n'));
      expect(publishJob, contains('bash tool/publish_settings_catalog.sh'));
    });

    test('发布在 release.yml 同一 run 里做，不靠只认默认分支（main）的 workflow_run', () {
      final Directory workflows = Directory(
        p.join(workspace.path, '.github', 'workflows'),
      );
      final List<String> callers = <String>[
        for (final FileSystemEntity f in workflows.listSync())
          if (f is File &&
              f.readAsStringSync().contains('publish_settings_catalog.sh'))
            p.basename(f.path),
      ];
      expect(callers, <String>['release.yml']);
      final String release = read('.github/workflows/release.yml');
      final String publishJob = _jobBlock(release, 'publish-settings-catalog');
      expect(publishJob, contains('    needs: tests\n'));
      final String condition = RegExp(
        r'^    if:\s*(.+)$',
        multiLine: true,
      ).firstMatch(publishJob)!.group(1)!;
      // tests 是矩阵：任一单测分片红，裸 needs 会让发布被跳过；只有取消才不发。
      expect(condition, contains('always()'));
      expect(condition, contains("needs.tests.result != 'cancelled'"));
      expect(condition, contains("github.event_name == 'push'"));
      expect(condition, contains("github.ref_name == 'develop'"));
      expect(condition, contains("github.ref_name == 'main'"));
      // 写权限只给发布 job，跑全量单测的 tests job 仍只读。
      expect(publishJob, contains('    permissions:\n      contents: write\n'));
      expect(_jobBlock(release, 'tests'), isNot(contains('contents: write')));
    });

    test('导出器写的文件名与发布脚本读的一致', () {
      final String exporter = read(
        'fushi/test/settings/settings_catalog_export_test.dart',
      );
      final String publisher = read('tool/publish_settings_catalog.sh');
      for (final String file in <String>[
        'settings-catalog.json',
        'settings-catalog.md',
      ]) {
        expect(exporter, contains('/$file'));
        expect(publisher, contains('/$file'));
      }
    });
  });
}

/// release.yml 里一个 job 的文本块（从 `  <name>:` 到下一个 job 头或文件尾）。
String _jobBlock(String yaml, String name) {
  final List<String> lines = yaml.split('\n');
  final int start = lines.indexOf('  $name:');
  expect(start, isNot(-1), reason: 'release.yml 里没有 job `$name`');
  final RegExp header = RegExp(r'^  [A-Za-z0-9_-]+:\s*$');
  int end = start + 1;
  while (end < lines.length && !header.hasMatch(lines[end])) {
    end++;
  }
  return '${lines.sublist(start, end).join('\n')}\n';
}

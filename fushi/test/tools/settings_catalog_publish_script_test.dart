import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 设置项目录同步链路（app 设置 schema → update-manifest 分支 → 官网
/// fushi.moe/settings.md）的两段守卫：
///
/// 1. 真跑 `tool/publish_settings_catalog.sh`，对着本地裸仓库（不联网）断言：只动
///    本通道的两个目录文件、分支上别的文件原样保留、内容没变不产生提交、坏输入
///    不覆盖好目录；
/// 2. 三处靠字符串对上的接线：导出器的环境变量名、release.yml 传的 artifact 名、
///    settings-catalog.yml 订阅的 workflow 名。任何一处改名，目录就静静地不再更新。
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
      expect(
        read('.github/workflows/settings-catalog.yml'),
        contains('--name settings-catalog '),
      );
    });

    test('settings-catalog.yml 订阅的 workflow 名就是 release.yml 的 name', () {
      final String name = RegExp(
        r'^name:\s*(.+)$',
        multiLine: true,
      ).firstMatch(read('.github/workflows/release.yml'))!.group(1)!.trim();
      expect(
        read('.github/workflows/settings-catalog.yml'),
        contains("workflows: ['$name']"),
      );
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

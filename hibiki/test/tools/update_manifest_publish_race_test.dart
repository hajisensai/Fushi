import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// TODO-781 regression: two platform publish jobs (android / desktop) push the
/// same update-manifest branch for the SAME release tag. The loser used to
/// clobber the winner's assets, so Android debug auto-update silently received
/// a manifest with no APK and never offered an update.
///
/// These guards drive the REAL tool/publish_update_manifest.sh against a
/// temporary local bare repo (no network, no GitHub) and assert the final
/// manifest carries every platform's assets.
void main() {
  late Directory workspace;
  late File script;

  setUpAll(() {
    workspace = Directory.current.parent;
    script = File(p.join(workspace.path, 'tool', 'publish_update_manifest.sh'));
    expect(script.existsSync(), isTrue,
        reason: 'publish_update_manifest.sh must exist at ${script.path}');
    expect(
      File(p.join(workspace.path, 'tool', 'merge_update_manifest.py'))
          .existsSync(),
      isTrue,
      reason: 'merge_update_manifest.py helper must exist',
    );
  });

  test('sequential same-tag publishes preserve both platform assets', () async {
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult android = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android',
      assetGlob: 'hibiki-*.apk',
    );
    expect(android.exitCode, 0, reason: _io(android));

    final ProcessResult desktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'hibiki-*-windows-setup.exe',
    );
    expect(desktop.exitCode, 0, reason: _io(desktop));

    final List<String> assets = await fx.finalAssetNames();
    expect(assets, containsAll(<String>[fx.apkName, fx.exeName]),
        reason: 'final manifest dropped a platform: $assets');
    expect(assets.length, 2);
  });

  test('reverse order desktop-first also preserves both assets', () async {
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult desktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'hibiki-*-windows-setup.exe',
    );
    expect(desktop.exitCode, 0, reason: _io(desktop));

    final ProcessResult android = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android',
      assetGlob: 'hibiki-*.apk',
    );
    expect(android.exitCode, 0, reason: _io(android));

    final List<String> assets = await fx.finalAssetNames();
    expect(assets, containsAll(<String>[fx.apkName, fx.exeName]),
        reason: 'final manifest dropped a platform: $assets');
    expect(assets.length, 2);
  });

  test('concurrent same-tag publishes survive the push race without clobber',
      () async {
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final List<ProcessResult> results =
        await Future.wait(<Future<ProcessResult>>[
      fx.publish(
        label: 'android',
        artifactsSubdir: 'art_android',
        assetGlob: 'hibiki-*.apk',
      ),
      fx.publish(
        label: 'desktop',
        artifactsSubdir: 'art_desktop',
        assetGlob: 'hibiki-*-windows-setup.exe',
      ),
    ]);
    for (final ProcessResult r in results) {
      expect(r.exitCode, 0, reason: _io(r));
    }

    final List<String> assets = await fx.finalAssetNames();
    expect(assets, containsAll(<String>[fx.apkName, fx.exeName]),
        reason: 'concurrent publish clobbered a platform: $assets');
    expect(assets.length, 2);
  });

  test('a newer tag fully supersedes stale prior-tag assets', () async {
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult oldAndroid = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android_old',
      assetGlob: 'hibiki-*.apk',
      tag: 'v0.11.1-debug.5630+08dc73c',
      version: '0.11.1-debug.5630',
      releaseSequence: 5630,
    );
    expect(oldAndroid.exitCode, 0, reason: _io(oldAndroid));

    final ProcessResult newDesktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'hibiki-*-windows-setup.exe',
    );
    expect(newDesktop.exitCode, 0, reason: _io(newDesktop));

    final List<String> assets = await fx.finalAssetNames();
    expect(assets, <String>[fx.exeName],
        reason: 'stale prior-tag asset should be superseded: $assets');
    expect(await fx.finalTag(), 'v0.11.1-debug.5633+3cf5905');
  });
}

String _io(ProcessResult r) =>
    'exit=${r.exitCode}\nstdout=${r.stdout}\nstderr=${r.stderr}';

/// A throwaway local origin + artifact tree to drive the publish script offline.
class _Fixture {
  _Fixture._(this.root, this.script, this.originUrl);

  final Directory root;
  final File script;
  final String originUrl;

  static const String defaultTag = 'v0.11.1-debug.5633+3cf5905';
  static const String defaultVersion = '0.11.1-debug.5633';
  static const int defaultSeq = 5633;

  final String apkName = 'hibiki-0.11.1-debug.5633-3cf5905-debug.apk';
  final String exeName = 'hibiki-0.11.1-debug.5633-windows-setup.exe';

  static Future<_Fixture> create() async {
    final Directory workspace = Directory.current.parent;
    final File script =
        File(p.join(workspace.path, 'tool', 'publish_update_manifest.sh'));
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki_manifest_race_');

    final Directory origin = Directory(p.join(root.path, 'origin.git'));
    await _git(root, <String>['init', '-q', '--bare', origin.path]);

    _writeAsset(
        root, 'art_android', 'hibiki-0.11.1-debug.5633-3cf5905-debug.apk');
    _writeAsset(
        root, 'art_android_old', 'hibiki-0.11.1-debug.5630-08dc73c-debug.apk');
    _writeAsset(
        root, 'art_desktop', 'hibiki-0.11.1-debug.5633-windows-setup.exe');

    final String originUrl =
        Uri.file(origin.path, windows: Platform.isWindows).toString();
    return _Fixture._(root, script, originUrl);
  }

  static void _writeAsset(Directory root, String subdir, String name) {
    final Directory dir = Directory(p.join(root.path, subdir))
      ..createSync(recursive: true);
    File(p.join(dir.path, name)).writeAsStringSync('x');
  }

  Future<ProcessResult> publish({
    required String label,
    required String artifactsSubdir,
    required String assetGlob,
    String tag = defaultTag,
    String version = defaultVersion,
    int releaseSequence = defaultSeq,
  }) {
    final Map<String, String> env = <String, String>{
      'CHANNEL': 'debug',
      'TAG': tag,
      'PRERELEASE': 'true',
      'NOTES': 'test',
      'RELEASE_SEQUENCE': '$releaseSequence',
      'VERSION': version,
      'REPO': 'owner/repo',
      'GITHUB_TOKEN': 'dummy-token',
      'ARTIFACTS_DIR': p.join(root.path, artifactsSubdir),
      'ASSET_GLOB': assetGlob,
      'PLATFORM_LABEL': label,
      'MANIFEST_REMOTE_OVERRIDE': originUrl,
      'GIT_AUTHOR_NAME': 'Test',
      'GIT_AUTHOR_EMAIL': 'test@example.com',
      'GIT_COMMITTER_NAME': 'Test',
      'GIT_COMMITTER_EMAIL': 'test@example.com',
    };
    return Process.run(
      'bash',
      <String>[script.path],
      environment: env,
      workingDirectory: root.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  Future<Map<String, dynamic>> _finalManifest() async {
    final ProcessResult show = await Process.run(
      'git',
      <String>[
        '-C',
        p.join(root.path, 'origin.git'),
        'show',
        'update-manifest:latest-debug.json',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(show.exitCode, 0,
        reason: 'could not read final manifest: ${show.stderr}');
    return json.decode(show.stdout as String) as Map<String, dynamic>;
  }

  Future<List<String>> finalAssetNames() async {
    final Map<String, dynamic> m = await _finalManifest();
    final List<dynamic> assets = m['assets'] as List<dynamic>;
    final List<String> names = assets
        .map((dynamic a) => (a as Map<String, dynamic>)['name'] as String)
        .toList()
      ..sort();
    return names;
  }

  Future<String> finalTag() async {
    final Map<String, dynamic> m = await _finalManifest();
    return m['tag'] as String;
  }

  Future<void> dispose() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  }
}

Future<void> _git(Directory cwd, List<String> args) async {
  final ProcessResult r = await Process.run('git', args,
      workingDirectory: cwd.path, stdoutEncoding: utf8, stderrEncoding: utf8);
  if (r.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${r.stdout}\n${r.stderr}');
  }
}

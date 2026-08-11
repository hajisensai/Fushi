import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
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
      assetGlob: 'fushi-*.apk',
    );
    expect(android.exitCode, 0, reason: _io(android));

    final ProcessResult desktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'fushi-*-windows-setup.exe',
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
      assetGlob: 'fushi-*-windows-setup.exe',
    );
    expect(desktop.exitCode, 0, reason: _io(desktop));

    final ProcessResult android = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android',
      assetGlob: 'fushi-*.apk',
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
        assetGlob: 'fushi-*.apk',
      ),
      fx.publish(
        label: 'desktop',
        artifactsSubdir: 'art_desktop',
        assetGlob: 'fushi-*-windows-setup.exe',
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

  test('a newer tag from another platform keeps the lagging platform asset',
      () async {
    // TODO-1173: a newer DESKTOP tag must not fully supersede the older ANDROID
    // asset -- that android build is android's only release, so dropping it
    // leaves android clients with no update. Keep both (cross-platform union),
    // advertise the newest tag.
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult oldAndroid = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android_old',
      assetGlob: 'fushi-*.apk',
      tag: 'v0.11.1-debug.5630+08dc73c',
      version: '0.11.1-debug.5630',
      releaseSequence: 5630,
    );
    expect(oldAndroid.exitCode, 0, reason: _io(oldAndroid));

    final ProcessResult newDesktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'fushi-*-windows-setup.exe',
    );
    expect(newDesktop.exitCode, 0, reason: _io(newDesktop));

    final List<String> assets = await fx.finalAssetNames();
    expect(
      assets,
      containsAll(<String>[
        'fushi-0.11.1-debug.5630-08dc73c-debug.apk',
        fx.exeName,
      ]),
      reason: 'cross-platform union dropped the lagging platform: $assets',
    );
    expect(assets.length, 2);
    expect(await fx.finalTag(), 'v0.11.1-debug.5633+3cf5905');
    expect(await fx.finalReleaseSequence(), 5633);
  });

  test('a late older-sequence publish never downgrades the manifest', () async {
    // TODO-1173 core guard: the reported bug was an installed newer build being
    // shown an OLDER latest. It happened when a slow older-sequence platform job
    // finished after a newer push and overwrote the whole manifest. The merge
    // must keep advertising the newest sequence and only add the late asset.
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult newDesktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'fushi-*-windows-setup.exe',
    );
    expect(newDesktop.exitCode, 0, reason: _io(newDesktop));

    final ProcessResult oldAndroid = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android_old',
      assetGlob: 'fushi-*.apk',
      tag: 'v0.11.1-debug.5630+08dc73c',
      version: '0.11.1-debug.5630',
      releaseSequence: 5630,
    );
    expect(oldAndroid.exitCode, 0, reason: _io(oldAndroid));

    expect(await fx.finalTag(), 'v0.11.1-debug.5633+3cf5905');
    expect(await fx.finalReleaseSequence(), 5633);
    final List<String> assets = await fx.finalAssetNames();
    expect(
      assets,
      containsAll(<String>[
        'fushi-0.11.1-debug.5630-08dc73c-debug.apk',
        fx.exeName,
      ]),
      reason: 'late older publish lost an asset: $assets',
    );
    expect(assets.length, 2);
  });

  test('BUG-1516: a pruned platform asset is dropped, not advertised as 404',
      () async {
    // Reported shape: desktop published, then stopped; Android kept publishing.
    // The rolling release prunes per platform, so the desktop file was deleted
    // while the manifest still advertised it. The client's only in-app action
    // was downloading that URL -> hard 404, no recovery (real case: an old
    // Hibiki debug client pinned to hibiki-1.3.2-debug.10182-windows-setup.exe
    // while the manifest's top level already read 1.3.3-debug.10192).
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult desktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'fushi-*-windows-setup.exe',
    );
    expect(desktop.exitCode, 0, reason: _io(desktop));
    expect(await fx.finalAssetNames(), contains(fx.exeName),
        reason: 'precondition: desktop asset advertised before the prune');

    // Android publishes later; by then the desktop asset is gone from the
    // release, so it must not survive into the merged manifest.
    final ProcessResult android = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android',
      assetGlob: 'fushi-*.apk',
      liveAssetsJson: json.encode(<String>[fx.apkName]),
    );
    expect(android.exitCode, 0, reason: _io(android));

    final List<String> assets = await fx.finalAssetNames();
    expect(assets, isNot(contains(fx.exeName)),
        reason: '被 prune 的资产仍留在清单里 → 客户端下载必 404：$assets');
    expect(assets, contains(fx.apkName), reason: '刚上传的资产不得被存活性过滤误删：$assets');
  });

  test('BUG-1516: an unavailable live list must not wipe retained assets',
      () async {
    // Fail-open half of the same guard. `gh release view` can fail for reasons
    // unrelated to the manifest (rate limit, 5xx, tag not created yet). Reading
    // that as "nothing is live" would delete every platform that did not
    // publish in this run — a much bigger outage than the stale entry.
    final _Fixture fx = await _Fixture.create();
    addTearDown(fx.dispose);

    final ProcessResult desktop = await fx.publish(
      label: 'desktop',
      artifactsSubdir: 'art_desktop',
      assetGlob: 'fushi-*-windows-setup.exe',
    );
    expect(desktop.exitCode, 0, reason: _io(desktop));

    final ProcessResult android = await fx.publish(
      label: 'android',
      artifactsSubdir: 'art_android',
      assetGlob: 'fushi-*.apk',
      liveAssetsJson: '', // query failed → filter must switch off entirely
    );
    expect(android.exitCode, 0, reason: _io(android));

    final List<String> assets = await fx.finalAssetNames();
    expect(assets, containsAll(<String>[fx.apkName, fx.exeName]),
        reason: '存活列表取不到时必须放行全部保留资产（fail-open）：$assets');
  });

  test('production retry backoff stays polite to the real GitHub remote', () {
    // BUG-1178 guard: this suite lowers MANIFEST_RETRY_BACKOFF_MS so a local
    // bare repo is not slept on for 3s per race. That seam must never be used
    // to make CI "faster" by hammering github.com -- the DEFAULT stays 3000ms.
    final String source = File(
      p.join(
          Directory.current.parent.path, 'tool', 'publish_update_manifest.sh'),
    ).readAsStringSync();
    expect(source,
        contains(r'RETRY_BACKOFF_MS="${MANIFEST_RETRY_BACKOFF_MS:-3000}"'),
        reason: 'default publish retry backoff must remain 3000ms');
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

  /// Publish subprocesses that have been started but not yet reaped.
  ///
  /// A test that times out abandons its `await` but NOT the OS process: bash
  /// keeps running with [root] as its working directory. On Windows a
  /// directory that is any live process's CWD cannot be deleted, so the
  /// abandoned child used to make [dispose] throw and keep burning CPU while
  /// sibling tests ran -- one timeout cascaded into a spray of unrelated
  /// failures. Owning the handles lets [dispose] kill survivors instead.
  final Set<Process> _running = <Process>{};

  static const String defaultTag = 'v0.11.1-debug.5633+3cf5905';
  static const String defaultVersion = '0.11.1-debug.5633';
  static const int defaultSeq = 5633;

  final String apkName = 'fushi-0.11.1-debug.5633-3cf5905-debug.apk';
  final String exeName = 'fushi-0.11.1-debug.5633-windows-setup.exe';
  final String oldApkName = 'fushi-0.11.1-debug.5630-08dc73c-debug.apk';

  /// Every asset this fixture can upload — the default "nothing was pruned"
  /// answer handed to the script's liveness filter (BUG-1516).
  List<String> get allFixtureAssetNames =>
      <String>[apkName, exeName, oldApkName];

  static Future<_Fixture> create() async {
    final Directory workspace = Directory.current.parent;
    final File script =
        File(p.join(workspace.path, 'tool', 'publish_update_manifest.sh'));
    final Directory root =
        await Directory.systemTemp.createTemp('hibiki_manifest_race_');

    final Directory origin = Directory(p.join(root.path, 'origin.git'));
    await _git(root, <String>['init', '-q', '--bare', origin.path]);

    _writeAsset(
        root, 'art_android', 'fushi-0.11.1-debug.5633-3cf5905-debug.apk');
    _writeAsset(
        root, 'art_android_old', 'fushi-0.11.1-debug.5630-08dc73c-debug.apk');
    _writeAsset(
        root, 'art_desktop', 'fushi-0.11.1-debug.5633-windows-setup.exe');

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
    String? liveAssetsJson,
  }) async {
    final Map<String, String> env = <String, String>{
      // The script's 3s production backoff is politeness toward a real GitHub
      // remote; this fixture pushes to a local bare repo. Keep the retry
      // semantics (re-fetch tip, re-merge, never clobber) and drop the wait.
      'MANIFEST_RETRY_BACKOFF_MS': '50',
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
      // BUG-1516 seam. ALWAYS set, so the script never reaches for `gh release
      // view` (no network in this suite, and an unauthenticated gh would just
      // fail into the same empty value anyway — but slowly, once per publish).
      // Default = "every fixture asset is still on the release", which is the
      // pre-BUG-1516 behaviour the union guards above assert.
      'MANIFEST_LIVE_ASSETS_OVERRIDE':
          liveAssetsJson ?? json.encode(allFixtureAssetNames),
      'GIT_AUTHOR_NAME': 'Test',
      'GIT_AUTHOR_EMAIL': 'test@example.com',
      'GIT_COMMITTER_NAME': 'Test',
      'GIT_COMMITTER_EMAIL': 'test@example.com',
    };
    final Process process = await Process.start(
      'bash',
      <String>[script.path],
      environment: env,
      workingDirectory: root.path,
    );
    _running.add(process);
    final Future<String> out = process.stdout.transform(utf8.decoder).join();
    final Future<String> err = process.stderr.transform(utf8.decoder).join();
    final int exitCode = await process.exitCode;
    // Only drop the handle once the process has really exited; if this test is
    // killed by a timeout mid-await, `dispose` must still find it.
    _running.remove(process);
    return ProcessResult(process.pid, exitCode, await out, await err);
  }

  Future<Map<String, dynamic>> _finalManifest() async {
    final ProcessResult show = await Process.run(
      'git',
      <String>[
        '-C',
        p.join(root.path, 'origin.git'),
        'show',
        // BUG-1481: the filename the REAL script writes must carry the product
        // family. Deriving it from the client-side constant makes this the
        // cross-side pin: if publish_update_manifest.sh and the Dart client ever
        // disagree about the suffix again, this read fails and the test reds --
        // which is the exact failure that let two products share one file.
        'update-manifest:latest-debug$kFushiManifestSuffix.json',
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

  Future<int> finalReleaseSequence() async {
    final Map<String, dynamic> m = await _finalManifest();
    return m['releaseSequence'] as int;
  }

  Future<void> dispose() async {
    for (final Process process in _running.toList(growable: false)) {
      process.kill(ProcessSignal.sigkill);
    }
    _running.clear();
    if (!root.existsSync()) return;
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Best effort. A grandchild git process can still hold a handle for a
      // moment on Windows; systemTemp is reaped by the OS anyway. Throwing here
      // would convert one test's failure into a tearDown error that also fails
      // the surrounding group -- exactly the cascade this fixture must not have.
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

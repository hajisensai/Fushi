import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/tracking/plugin/bundled_tracking_plugins.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

import 'tracking_plugin_test_support.dart';

/// [TrackingPluginManager] on the real sandbox engine.
void main() {
  late Directory root;
  late RecordingEngine engine;
  late List<TrackingPluginManager> managers;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi-tracking-plugins-');
    engine = RecordingEngine.real();
    managers = <TrackingPluginManager>[];
  });

  tearDown(() async {
    for (final TrackingPluginManager manager in managers) {
      await manager.dispose();
    }
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  TrackingPluginManager makeManager() {
    final TrackingPluginManager manager = TrackingPluginManager(
      rootDir: root,
      engine: engine,
    );
    managers.add(manager);
    return manager;
  }

  Future<TrackingPluginInfo> install(
    TrackingPluginManager manager,
    Uint8List zip,
  ) async => manager.install(zip, (await manager.inspect(zip)).digest);

  File credentialsFile(String id) => File('${root.path}/.credentials/$id.json');

  Future<void> signIn(TrackingPluginManager manager, String id) async {
    final TrackingPluginRuntime runtime = await manager.runtime(id);
    await runtime.invoke('login', <String, Object?>{
      'op': 'submit',
      'method': 'token',
      'platform': 'test',
      'action': 'ok',
      'inputs': <String, Object?>{'token': 't1'},
    });
    await runtime.invoke('trackingEntry', <String, Object?>{
      'op': 'set',
      'id': 2,
      'kind': 'manga',
      'create': true,
      'status': 'current',
      'progress': 1,
    });
    await manager.setAccount(
      id,
      const TrackingPluginAccount(loggedIn: true, name: 'user-t1'),
    );
  }

  test('inspect, install and list a tracking plugin', () async {
    final TrackingPluginManager manager = makeManager();
    final Uint8List zip = buildPluginZip(fakeManifest());
    final TrackingPluginInfo info = await manager.inspect(zip);
    expect(info.id, fakePluginId);
    expect(info.isTracking, isTrue);
    expect(info.signer, isNull);
    expect(info.site!.siteId, fakeSiteId);
    expect(info.site!.siteHost, 'example.org');
    expect(info.site!.kinds, <TrackingKind>{
      TrackingKind.anime,
      TrackingKind.manga,
      TrackingKind.novel,
    });
    expect(info.site!.requestsPerMinute, 30);
    expect(info.networkDomains, <String>['api.example.org']);
    expect(Directory('${root.path}/$fakePluginId').existsSync(), isFalse);

    await expectLater(
      manager.install(zip, 'not-the-digest'),
      throwsA(
        isA<TrackingPluginException>().having(
          (TrackingPluginException e) => e.code,
          'code',
          TrackingPluginErrorCode.invalidPackage,
        ),
      ),
    );
    int changes = 0;
    manager.changes.addListener(() => changes++);
    await manager.install(zip, info.digest);
    expect(changes, greaterThan(0));

    final List<InstalledTrackingPlugin> listed = await manager.list();
    expect(listed.single.id, fakePluginId);
    expect(listed.single.enabled, isTrue, reason: 'missing state = enabled');
    expect(listed.single.registered, isTrue);
    expect(manager.registered.single.id, fakePluginId);

    final TrackingPluginRuntime runtime = await manager.runtime(fakePluginId);
    expect(runtime.isAlive, isTrue);
    expect(identical(await manager.runtime(fakePluginId), runtime), isTrue);
  });

  test('refuses a music-kind package', () async {
    final TrackingPluginManager manager = makeManager();
    final Uint8List zip = buildPluginZip(
      fakeManifest(
        id: 'moe.test.music',
        kind: 'music',
        capabilities: const <String>['lyrics'],
      ),
      js: 'module.exports = { lyrics() { return null; } };',
    );
    await expectLater(
      manager.inspect(zip),
      throwsA(
        isA<TrackingPluginException>().having(
          (TrackingPluginException e) => e.code,
          'code',
          TrackingPluginErrorCode.notTrackingPlugin,
        ),
      ),
    );
    await expectLater(
      manager.install(zip, 'x'),
      throwsA(isA<TrackingPluginException>()),
    );
    expect(Directory('${root.path}/moe.test.music').existsSync(), isFalse);
  });

  test('a package that fails verification is listed as unusable', () async {
    final TrackingPluginManager manager = makeManager();
    await install(manager, buildPluginZip(fakeManifest()));
    File('${root.path}/$fakePluginId/main.js').writeAsStringSync('tampered');
    final InstalledTrackingPlugin plugin = (await manager.list()).single;
    expect(plugin.info, isNull);
    expect(plugin.error, isNotNull);
    expect(plugin.registered, isFalse);
    await expectLater(
      manager.runtime(fakePluginId),
      throwsA(isA<TrackingPluginException>()),
    );
  });

  test('disable closes the runtime and refuses new ones; enable '
      'reopens', () async {
    final TrackingPluginManager manager = makeManager();
    await install(manager, buildPluginZip(fakeManifest()));
    final TrackingPluginRuntime first = await manager.runtime(fakePluginId);

    await manager.setEnabled(fakePluginId, false);
    expect(first.isAlive, isFalse);
    expect(manager.registered, isEmpty);
    expect(manager.installed.single.enabled, isFalse);
    await expectLater(
      manager.runtime(fakePluginId),
      throwsA(
        isA<TrackingPluginException>().having(
          (TrackingPluginException e) => e.code,
          'code',
          TrackingPluginErrorCode.disabled,
        ),
      ),
    );
    // The state survives a new manager.
    expect((await makeManager().list()).single.enabled, isFalse);

    await manager.setEnabled(fakePluginId, true);
    final TrackingPluginRuntime second = await manager.runtime(fakePluginId);
    expect(second.isAlive, isTrue);
    expect(manager.registered.single.id, fakePluginId);
  });

  test('uninstall removes package, storage, credentials and account '
      'state', () async {
    final TrackingPluginManager manager = makeManager();
    await install(manager, buildPluginZip(fakeManifest()));
    await signIn(manager, fakePluginId);
    final TrackingPluginRuntime runtime = await manager.runtime(fakePluginId);
    expect(manager.storageFileFor(fakePluginId).existsSync(), isTrue);
    expect(credentialsFile(fakePluginId).existsSync(), isTrue);
    expect(manager.accountOf(fakePluginId).loggedIn, isTrue);

    await manager.uninstall(fakePluginId);
    expect(runtime.isAlive, isFalse);
    expect(Directory('${root.path}/$fakePluginId').existsSync(), isFalse);
    expect(manager.storageFileFor(fakePluginId).existsSync(), isFalse);
    expect(credentialsFile(fakePluginId).existsSync(), isFalse);
    expect(manager.accountOf(fakePluginId).loggedIn, isFalse);
    expect(await manager.list(), isEmpty);
    expect(makeManager().accountOf(fakePluginId).loggedIn, isFalse);
    await makeManager().list();
    expect(managers.last.accountOf(fakePluginId).loggedIn, isFalse);

    // Reinstalled: starts signed out with empty storage.
    await install(manager, buildPluginZip(fakeManifest()));
    final TrackingPluginRuntime again = await manager.runtime(fakePluginId);
    expect(
      await again.invoke('account', <String, Object?>{}),
      <String, Object?>{'loggedIn': false},
    );
  });

  test('two enabled plugins of one site: the second is not '
      'registered', () async {
    final TrackingPluginManager manager = makeManager();
    await install(manager, buildPluginZip(fakeManifest(id: 'moe.test.a')));
    await install(manager, buildPluginZip(fakeManifest(id: 'moe.test.b')));
    final Map<String, InstalledTrackingPlugin> byId =
        <String, InstalledTrackingPlugin>{
          for (final InstalledTrackingPlugin p in await manager.list()) p.id: p,
        };
    expect(byId['moe.test.a']!.registered, isTrue);
    expect(byId['moe.test.b']!.registered, isFalse);
    expect(byId['moe.test.b']!.conflictsWith, 'moe.test.a');
    expect(
      manager.registered.map((InstalledTrackingPlugin p) => p.id),
      <String>['moe.test.a'],
    );

    // Disabling the first frees the site for the second.
    await manager.setEnabled('moe.test.a', false);
    expect(
      manager.registered.map((InstalledTrackingPlugin p) => p.id),
      <String>['moe.test.b'],
    );
  });

  test('a side-loaded plugin claiming a reserved site id is refused at '
      'install and never registered', () async {
    final TrackingPluginManager manager = makeManager();
    final Uint8List zip = buildPluginZip(fakeManifest(siteId: 'bangumi'));
    await expectLater(
      manager.inspect(zip),
      throwsA(
        isA<TrackingPluginException>().having(
          (TrackingPluginException e) => e.code,
          'code',
          TrackingPluginErrorCode.reservedSite,
        ),
      ),
    );
    // Copied into the folder by hand (no installer): listed, never used.
    final TrackingPluginInfo info = await engine.inspect(zip);
    await engine.install(zip, root.path, info.digest);
    final InstalledTrackingPlugin plugin = (await manager.list()).single;
    expect(plugin.reservedSite, isTrue);
    expect(plugin.builtIn, isFalse);
    expect(plugin.registered, isFalse);
    expect(manager.registered, isEmpty);
  });

  test('reinstall by the same signer keeps data; a changed signer wipes '
      'storage, credentials and account state', () async {
    final TrackingPluginManager manager = makeManager();
    final Uint8List v1 = buildPluginZip(fakeManifest());
    await install(manager, v1);
    await signIn(manager, fakePluginId);
    final TrackingPluginRuntime before = await manager.runtime(fakePluginId);

    // Same (absent) signer, new version: data kept, runtime replaced.
    final Uint8List v2 = buildPluginZip(fakeManifest(version: '0.2.0'));
    expect(await manager.signerChanged(await manager.inspect(v2)), isFalse);
    await install(manager, v2);
    expect(before.isAlive, isFalse);
    expect(manager.storageFileFor(fakePluginId).existsSync(), isTrue);
    expect(manager.accountOf(fakePluginId).loggedIn, isTrue);
    expect(manager.installed.single.info!.version, '0.2.0');

    // Signed by someone: treated as a new plugin.
    final Uint8List v3 = buildPluginZip(fakeManifest(version: '0.3.0'));
    engine.signerOf[(await manager.inspect(v3)).digest] = 'c29tZW9uZQ==';
    expect(await manager.signerChanged(await manager.inspect(v3)), isTrue);
    await install(manager, v3);
    expect(manager.storageFileFor(fakePluginId).existsSync(), isFalse);
    expect(credentialsFile(fakePluginId).existsSync(), isFalse);
    expect(manager.accountOf(fakePluginId).loggedIn, isFalse);
    final TrackingPluginRuntime after = await manager.runtime(fakePluginId);
    expect(
      await after.invoke('account', <String, Object?>{}),
      <String, Object?>{'loggedIn': false},
    );
  });

  test('account state persists across manager instances and is not in '
      'synced preferences', () async {
    final TrackingPluginManager manager = makeManager();
    await install(manager, buildPluginZip(fakeManifest()));
    await manager.setAccount(
      fakePluginId,
      const TrackingPluginAccount(loggedIn: true, name: 'alice'),
    );
    final TrackingPluginManager other = makeManager();
    await other.list();
    expect(
      other.accountOf(fakePluginId),
      const TrackingPluginAccount(loggedIn: true, name: 'alice'),
    );
    expect(
      File('${root.path}/.state.json').readAsStringSync(),
      contains('alice'),
    );

    await other.setAccount(fakePluginId, TrackingPluginAccount.signedOut);
    final TrackingPluginManager third = makeManager();
    await third.list();
    expect(third.accountOf(fakePluginId).loggedIn, isFalse);
  });

  test('a stopped runtime is reopened on next use', () async {
    final TrackingPluginManager manager = makeManager();
    await install(manager, buildPluginZip(fakeManifest()));
    final TrackingPluginRuntime first = await manager.runtime(fakePluginId);
    await first.close();
    final TrackingPluginRuntime second = await manager.runtime(fakePluginId);
    expect(identical(first, second), isFalse);
    expect(second.isAlive, isTrue);
    expect(engine.opened, 2);
  });
  group('bundled package (spec 2026-11-11 §3)', () {
    const String bundledId = 'moe.fushi.tracking.bangumi';
    Map<String, Object?> bundledManifest({String version = '1.0.0'}) =>
        fakeManifest(
          id: bundledId,
          siteId: 'bangumi',
          name: 'Bangumi',
          version: version,
        );

    test('installed when missing, built in and registered for bangumi; '
        'not reinstalled when unchanged', () async {
      final TrackingPluginManager manager = makeManager();
      final Uint8List zip = buildPluginZip(bundledManifest());
      expect(await manager.ensureBundled(zip), isTrue);
      final InstalledTrackingPlugin plugin = manager.installed.single;
      expect(plugin.id, bundledId);
      expect(plugin.builtIn, isTrue);
      expect(plugin.reservedSite, isFalse);
      expect(plugin.registered, isTrue);
      expect(plugin.info!.site!.siteId, 'bangumi');
      expect(manager.isBundled(bundledId), isTrue);

      // A second start with the same app build: nothing to install.
      final TrackingPluginManager next = makeManager();
      expect(await next.ensureBundled(zip), isFalse);
      expect(next.installed.single.registered, isTrue);
    });

    test('a newer bundled copy replaces the installed one, keeps its data '
        'and keeps it turned off', () async {
      final TrackingPluginManager manager = makeManager();
      await manager.ensureBundled(buildPluginZip(bundledManifest()));
      await signIn(manager, bundledId);
      await manager.setEnabled(bundledId, false);

      final TrackingPluginManager upgraded = makeManager();
      expect(
        await upgraded.ensureBundled(
          buildPluginZip(bundledManifest(version: '1.1.0')),
        ),
        isTrue,
      );
      final InstalledTrackingPlugin plugin = upgraded.installed.single;
      expect(plugin.info!.version, '1.1.0');
      expect(plugin.builtIn, isTrue);
      expect(plugin.enabled, isFalse);
      expect(plugin.registered, isFalse);
      expect(upgraded.accountOf(bundledId).loggedIn, isTrue);
      expect(credentialsFile(bundledId).existsSync(), isTrue);
    });

    test('another package under the bundled id is replaced at start; until '
        'then it is a reserved site', () async {
      final TrackingPluginManager manager = makeManager();
      final Uint8List fake = buildPluginZip(
        bundledManifest(),
        js: '$fakeSiteJs\n// changed',
      );
      final TrackingPluginInfo info = await engine.inspect(fake);
      await engine.install(fake, root.path, info.digest);
      expect((await manager.list()).single.reservedSite, isTrue);

      final Uint8List real = buildPluginZip(bundledManifest());
      expect(await manager.ensureBundled(real), isTrue);
      final InstalledTrackingPlugin plugin = manager.installed.single;
      expect(plugin.info!.digest, (await engine.inspect(real)).digest);
      expect(plugin.builtIn, isTrue);
      expect(plugin.registered, isTrue);
    });

    test('a side-loaded package claiming bangumi is refused even with the '
        'bundled id', () async {
      final TrackingPluginManager manager = makeManager();
      await manager.ensureBundled(buildPluginZip(bundledManifest()));
      final Uint8List other = buildPluginZip(bundledManifest(version: '9.0.0'));
      await expectLater(
        manager.inspect(other),
        throwsA(
          isA<TrackingPluginException>().having(
            (TrackingPluginException e) => e.code,
            'code',
            TrackingPluginErrorCode.reservedSite,
          ),
        ),
      );
      final Uint8List otherId = buildPluginZip(
        fakeManifest(id: 'moe.evil.bangumi', siteId: 'bangumi'),
      );
      await expectLater(
        manager.inspect(otherId),
        throwsA(isA<TrackingPluginException>()),
      );
    });

    test('the bundled plugin cannot be removed', () async {
      final TrackingPluginManager manager = makeManager();
      await manager.ensureBundled(buildPluginZip(bundledManifest()));
      await expectLater(
        manager.uninstall(bundledId),
        throwsA(
          isA<TrackingPluginException>().having(
            (TrackingPluginException e) => e.code,
            'code',
            TrackingPluginErrorCode.builtIn,
          ),
        ),
      );
      expect(Directory('${root.path}/$bundledId').existsSync(), isTrue);
    });

    test('a bundled package that fails to load is reported; the plugins are '
        'listed anyway', () async {
      final TrackingPluginManager manager = makeManager();
      await install(manager, buildPluginZip(fakeManifest()));
      final TrackingPluginManager next = makeManager();
      final List<Object> errors = <Object>[];
      await installBundledTrackingPlugins(
        next,
        load: () async => throw const FileSystemException('missing asset'),
        onError: (Object error, StackTrace _) => errors.add(error),
      );
      expect(errors.single, isA<FileSystemException>());
      expect(next.installed.single.id, fakePluginId);
    });

    test(
      'the real bundled asset installs and registers in the engine',
      () async {
        final TrackingPluginManager manager = makeManager();
        final Uint8List asset = File(
          'assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug',
        ).readAsBytesSync();
        expect(await manager.ensureBundled(asset), isTrue);
        final InstalledTrackingPlugin plugin = manager.installed.single;
        expect(plugin.id, bundledId);
        expect(plugin.registered, isTrue);
        expect(plugin.builtIn, isTrue);
        expect(plugin.info!.site!.siteId, 'bangumi');
        expect(plugin.info!.can(TrackingPluginCapability.list), isTrue);
      },
    );
  });
}

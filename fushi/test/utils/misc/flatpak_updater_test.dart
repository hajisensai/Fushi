import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/flatpak_updater.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

List<Map<String, dynamic>> _assets(List<String> names) => names
    .map(
      (String n) => <String, dynamic>{
        'name': n,
        'browser_download_url': 'https://example.com/$n',
      },
    )
    .toList();

class _FakeMonitor implements FlatpakUpdateMonitor {
  _FakeMonitor(this.onUpdate);

  /// Signals the portal sends after `Update` is called.
  final List<FlatpakUpdateProgress> Function() onUpdate;
  final StreamController<FlatpakUpdateProgress> _progress =
      StreamController<FlatpakUpdateProgress>.broadcast();
  int updateCalls = 0;
  bool closed = false;

  @override
  Stream<FlatpakUpdateProgress> get progress => _progress.stream;

  @override
  Future<void> update() async {
    updateCalls++;
    final List<FlatpakUpdateProgress> signals = onUpdate();
    scheduleMicrotask(() {
      for (final FlatpakUpdateProgress p in signals) {
        _progress.add(p);
      }
    });
  }

  @override
  Future<void> close() async => closed = true;
}

class _FakePortal implements FlatpakPortal {
  _FakePortal(this.monitor);

  final _FakeMonitor monitor;
  final List<List<String>> spawned = <List<String>>[];

  @override
  Future<FlatpakUpdateMonitor> createUpdateMonitor() async => monitor;

  @override
  Future<void> spawnLatest(List<String> argv) async => spawned.add(argv);
}

const FlatpakInstallation _stable = FlatpakInstallation(
  appId: 'app.fushi.reader',
  branch: 'stable',
);

void main() {
  group('parseFlatpakInfo', () {
    test('reads name and branch from the [Application] group', () {
      final FlatpakInstallation? info = parseFlatpakInfo('''
[Application]
name=app.fushi.reader
runtime=runtime/org.gnome.Platform/x86_64/49

[Instance]
branch=ignored
''');
      expect(info?.appId, 'app.fushi.reader');
      // No branch in [Application]: Flatpak's default branch.
      expect(info?.branch, 'master');
    });

    test('branch inside [Application] wins', () {
      final FlatpakInstallation? info = parseFlatpakInfo(
        '[Application]\nname=app.fushi.reader\nbranch=debug\n',
      );
      expect(info?.branch, 'debug');
      expect(info?.channel, UpdateChannel.debug);
    });

    test('no [Application] name = not a Flatpak installation', () {
      expect(parseFlatpakInfo('[Instance]\nbranch=stable\n'), isNull);
      expect(parseFlatpakInfo(''), isNull);
    });
  });

  test('branch maps to channel; unknown branches cannot self-update', () {
    expect(flatpakBranchChannel('stable'), UpdateChannel.stable);
    expect(flatpakBranchChannel('beta'), UpdateChannel.beta);
    expect(flatpakBranchChannel('debug'), UpdateChannel.debug);
    expect(flatpakBranchChannel('master'), isNull);
    final FlatpakUpdater local = FlatpakUpdater(
      installation: const FlatpakInstallation(
        appId: 'app.fushi.reader',
        branch: 'master',
      ),
    );
    expect(local.supportsInAppInstall, isFalse);
    expect(local.installedChannel, isNull);
  });

  group('selectAsset', () {
    final List<Map<String, dynamic>> assets = _assets(<String>[
      'fushi-3.4.0-windows-setup.exe',
      'fushi-3.4.0-linux-x86_64.flatpak',
      'fushi-3.4.0-debug.7001-linux-x86_64.flatpak',
      'hibiki-3.4.0-linux-x86_64.flatpak',
    ]);

    test('stable / beta pick the non-debug bundle of this product', () async {
      final FlatpakUpdater u = FlatpakUpdater(installation: _stable);
      expect(
        (await u.selectAsset(assets))?.name,
        'fushi-3.4.0-linux-x86_64.flatpak',
      );
      expect(
        (await u.selectAsset(assets, channel: UpdateChannel.beta))?.name,
        'fushi-3.4.0-linux-x86_64.flatpak',
      );
    });

    test('debug picks the -debug. bundle', () async {
      final FlatpakUpdater u = FlatpakUpdater(installation: _stable);
      expect(
        (await u.selectAsset(assets, channel: UpdateChannel.debug))?.name,
        'fushi-3.4.0-debug.7001-linux-x86_64.flatpak',
      );
    });

    test('a release without a Flatpak bundle has nothing to install', () async {
      final FlatpakUpdater u = FlatpakUpdater(installation: _stable);
      expect(
        await u.selectAsset(_assets(<String>['fushi-3.4.0-macos-arm64.zip'])),
        isNull,
      );
    });
  });

  test('progress is spread over all operations', () {
    final FlatpakUpdateProgress p = parseFlatpakUpdateProgress(
      <String, Object?>{'status': 0, 'n_ops': 4, 'op': 1, 'progress': 50},
    );
    expect(p.status, FlatpakUpdateStatus.running);
    expect(p.overall, closeTo(0.375, 1e-9));
    expect(
      parseFlatpakUpdateProgress(<String, Object?>{'status': 2}).overall,
      1,
    );
    expect(
      parseFlatpakUpdateProgress(<String, Object?>{'status': 9}).status,
      FlatpakUpdateStatus.error,
    );
  });

  group('stage', () {
    test('reports progress, finishes on done and closes the monitor', () async {
      final _FakeMonitor monitor = _FakeMonitor(
        () => const <FlatpakUpdateProgress>[
          FlatpakUpdateProgress(
            status: FlatpakUpdateStatus.running,
            nOps: 2,
            progress: 50,
          ),
          FlatpakUpdateProgress(status: FlatpakUpdateStatus.done),
        ],
      );
      final FlatpakUpdater u = FlatpakUpdater(
        installation: _stable,
        portal: () => _FakePortal(monitor),
      );
      final List<double> progress = <double>[];
      await u.stage('3.4.0', onProgress: progress.add);
      expect(progress, <double>[0.25, 1]);
      expect(monitor.updateCalls, 1);
      expect(monitor.closed, isTrue);
    });

    test('nothing to pull = repo not caught up with the release', () async {
      final _FakeMonitor monitor = _FakeMonitor(
        () => const <FlatpakUpdateProgress>[
          FlatpakUpdateProgress(status: FlatpakUpdateStatus.empty),
        ],
      );
      final FlatpakUpdater u = FlatpakUpdater(
        installation: _stable,
        portal: () => _FakePortal(monitor),
      );
      await expectLater(
        u.stage('3.4.0', onProgress: (_) {}),
        throwsA(isA<FlatpakUpdateNotPublishedException>()),
      );
      expect(monitor.closed, isTrue);
    });

    test('new permissions are refused by the portal and say so', () async {
      final _FakeMonitor monitor = _FakeMonitor(
        () => const <FlatpakUpdateProgress>[
          FlatpakUpdateProgress(
            status: FlatpakUpdateStatus.error,
            error: 'org.freedesktop.portal.Error.NotAllowed',
            errorMessage: 'new permissions',
          ),
        ],
      );
      final FlatpakUpdater u = FlatpakUpdater(
        installation: _stable,
        portal: () => _FakePortal(monitor),
      );
      await expectLater(
        u.stage('3.4.0', onProgress: (_) {}),
        throwsA(
          isA<FlatpakUpdateException>().having(
            (FlatpakUpdateException e) => e.needsNewPermissions,
            'needsNewPermissions',
            isTrue,
          ),
        ),
      );
    });

    test('cancelling stops waiting', () async {
      final _FakeMonitor monitor = _FakeMonitor(
        () => const <FlatpakUpdateProgress>[],
      );
      final FlatpakUpdater u = FlatpakUpdater(
        installation: _stable,
        portal: () => _FakePortal(monitor),
      );
      final UpdateDownloadCancellation cancellation =
          UpdateDownloadCancellation();
      final Future<void> staged = u.stage(
        '3.4.0',
        onProgress: (_) {},
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      await expectLater(
        staged,
        throwsA(isA<UpdateDownloadCancelledException>()),
      );
      expect(monitor.closed, isTrue);
    });
  });

  test('restart spawns the latest deploy with the restart marker, then '
      'exits', () async {
    final _FakePortal portal = _FakePortal(
      _FakeMonitor(() => const <FlatpakUpdateProgress>[]),
    );
    final List<String> order = <String>[];
    final FlatpakUpdater u = FlatpakUpdater(
      installation: _stable,
      portal: () => portal,
      exitForRestart: () async => order.add('exit'),
    );
    await u.restartIntoStagedUpdate('3.4.0');
    expect(portal.spawned, <List<String>>[
      <String>['fushi', '--fushi-restarted'],
    ]);
    expect(order, <String>['exit']);
  });

  test('a package-managed updater has no file to apply', () {
    final FlatpakUpdater u = FlatpakUpdater(installation: _stable);
    expect(u, isA<PackageManagedUpdater>());
  });
}

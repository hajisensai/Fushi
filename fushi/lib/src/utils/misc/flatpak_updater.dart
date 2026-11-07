/// Linux Flatpak self-update.
///
/// A Flatpak cannot replace its own files: `/app` is a read-only deploy that
/// Flatpak owns. So the update is not a downloaded file Fushi installs, but a new
/// commit Flatpak pulls from the app's remote (the OSTree repo the release CI
/// publishes, see `tool/linux/flatpak/`). Both steps go through the Flatpak portal
/// (`org.freedesktop.portal.Flatpak`), which every Flatpak app may call without
/// extra `finish-args`:
///
///   * stage = `UpdateMonitor.Update`: pull + deploy the new commit. The running
///     process keeps the old deploy until it exits.
///   * restart = `Spawn` with `FLATPAK_SPAWN_FLAGS_LATEST_VERSION`: start the new
///     deploy in a new sandbox, then exit. A plain `Process.start` would restart
///     inside this sandbox, i.e. the old version.
///
/// The version check stays on the GitHub releases like every other platform; the
/// release's `-linux-x86_64.flatpak` asset is what says "this release has a Linux
/// build". The update channel comes from the installed branch (`stable` / `beta`
/// / `debug`), not from the setting: the portal can only update the branch that
/// is installed, so following the setting would offer versions it cannot install.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'package:fushi/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi/i18n/strings.g.dart';

/// Flatpak's metadata file inside every sandbox.
const String kFlatpakInfoPath = '/.flatpak-info';

/// Asset suffix of the Linux Flatpak bundle on a release
/// (`fushi-<version>-linux-x86_64.flatpak`).
const String kFlatpakAssetSuffix = '-linux-x86_64.flatpak';

/// What `/.flatpak-info` says about this installation.
@immutable
class FlatpakInstallation {
  const FlatpakInstallation({required this.appId, required this.branch});

  final String appId;

  /// Installed branch (`stable`, `beta`, `debug`, or anything a local build used).
  final String branch;

  /// The update channel this branch follows; null = a branch no release CI
  /// publishes (local / test build), which cannot be updated through the portal.
  UpdateChannel? get channel => flatpakBranchChannel(branch);

  static FlatpakInstallation? _cached;
  static bool _resolved = false;

  /// This process's installation, or null when not running inside a Flatpak.
  static FlatpakInstallation? current() {
    if (_resolved) return _cached;
    _resolved = true;
    try {
      final File info = File(kFlatpakInfoPath);
      if (info.existsSync()) {
        _cached = parseFlatpakInfo(info.readAsStringSync());
      }
    } on FileSystemException {
      _cached = null;
    }
    return _cached;
  }
}

/// **Pure**: parse `/.flatpak-info` (GKeyFile). Returns null without an
/// `[Application]` group carrying `name`.
FlatpakInstallation? parseFlatpakInfo(String contents) {
  String? group;
  String? name;
  String? branch;
  for (final String raw in contents.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      group = line.substring(1, line.length - 1);
      continue;
    }
    if (group != 'Application') continue;
    final int eq = line.indexOf('=');
    if (eq <= 0) continue;
    final String key = line.substring(0, eq).trim();
    final String value = line.substring(eq + 1).trim();
    if (key == 'name') name = value;
    if (key == 'branch') branch = value;
  }
  if (name == null || name.isEmpty) return null;
  return FlatpakInstallation(appId: name, branch: branch ?? 'master');
}

/// **Pure**: which update channel a Flatpak branch follows.
UpdateChannel? flatpakBranchChannel(String branch) => switch (branch) {
  'stable' => UpdateChannel.stable,
  'beta' => UpdateChannel.beta,
  'debug' => UpdateChannel.debug,
  _ => null,
};

/// **Pure**: whether [name] is the Flatpak bundle for [channel]. Debug versions
/// carry `-debug.<seq>`, the same rule as the Windows / macOS assets.
bool flatpakAssetMatchesChannel(String name, UpdateChannel channel) {
  if (!name.endsWith(kFlatpakAssetSuffix)) return false;
  final bool debug = name.contains('-debug.');
  return switch (channel) {
    UpdateChannel.debug => debug,
    UpdateChannel.stable || UpdateChannel.beta => !debug,
  };
}

/// Status values of `UpdateMonitor.Progress` (`status` key).
enum FlatpakUpdateStatus { running, empty, done, error }

/// One `UpdateMonitor.Progress` signal.
@immutable
class FlatpakUpdateProgress {
  const FlatpakUpdateProgress({
    required this.status,
    this.op = 0,
    this.nOps = 0,
    this.progress = 0,
    this.error,
    this.errorMessage,
  });

  final FlatpakUpdateStatus status;

  /// 0-based index of the current operation, out of [nOps].
  final int op;
  final int nOps;

  /// 0..100 within the current operation.
  final int progress;
  final String? error;
  final String? errorMessage;

  /// Overall progress 0..1 across all operations.
  double get overall {
    if (status == FlatpakUpdateStatus.done) return 1;
    if (nOps <= 0) return progress.clamp(0, 100) / 100;
    final double done = op.clamp(0, nOps) + progress.clamp(0, 100) / 100;
    return (done / nOps).clamp(0, 1);
  }
}

/// **Pure**: decode the `a{sv}` of a Progress signal.
FlatpakUpdateProgress parseFlatpakUpdateProgress(Map<String, Object?> info) {
  int intOf(String key) => (info[key] as int?) ?? 0;
  final int status = intOf('status');
  return FlatpakUpdateProgress(
    status: status >= 0 && status < FlatpakUpdateStatus.values.length
        ? FlatpakUpdateStatus.values[status]
        : FlatpakUpdateStatus.error,
    op: intOf('op'),
    nOps: intOf('n_ops'),
    progress: intOf('progress'),
    error: info['error'] as String?,
    errorMessage: info['error_message'] as String?,
  );
}

/// The update could not be installed through the portal.
class FlatpakUpdateException implements Exception {
  const FlatpakUpdateException(this.message, {this.error});

  final String message;

  /// Flatpak's error name (e.g. `org.freedesktop.portal.Error.NotAllowed`).
  final String? error;

  /// The new version needs permissions the installed one lacks. The portal
  /// refuses those on purpose; the user has to accept them in a package manager.
  bool get needsNewPermissions =>
      error == 'org.freedesktop.portal.Error.NotAllowed';

  @override
  String toString() => 'FlatpakUpdateException: $message';
}

/// The repo has nothing newer than what is installed (release seen on GitHub,
/// Flatpak repo not caught up yet).
class FlatpakUpdateNotPublishedException extends FlatpakUpdateException {
  const FlatpakUpdateNotPublishedException()
    : super('the Flatpak repository has no newer build yet');
}

/// One open `UpdateMonitor`.
abstract interface class FlatpakUpdateMonitor {
  Stream<FlatpakUpdateProgress> get progress;

  /// Start pull + deploy; results arrive on [progress].
  Future<void> update();
  Future<void> close();
}

/// The parts of `org.freedesktop.portal.Flatpak` the updater uses (test seam).
abstract interface class FlatpakPortal {
  Future<FlatpakUpdateMonitor> createUpdateMonitor();

  /// Start [argv] in a new sandbox of the newest installed deploy of this app.
  Future<void> spawnLatest(List<String> argv);
}

/// Production portal over the session bus.
class DBusFlatpakPortal implements FlatpakPortal {
  DBusFlatpakPortal({DBusClient? client})
    : _client = client ?? DBusClient.session();

  static const String _busName = 'org.freedesktop.portal.Flatpak';
  static const String _interface = 'org.freedesktop.portal.Flatpak';
  static const String _monitorInterface =
      'org.freedesktop.portal.Flatpak.UpdateMonitor';
  static final DBusObjectPath _path = DBusObjectPath(
    '/org/freedesktop/portal/Flatpak',
  );

  /// `FLATPAK_SPAWN_FLAGS_LATEST_VERSION`.
  static const int _spawnLatestVersion = 2;

  final DBusClient _client;

  @override
  Future<FlatpakUpdateMonitor> createUpdateMonitor() async {
    final DBusMethodSuccessResponse reply = await _client.callMethod(
      destination: _busName,
      path: _path,
      interface: _interface,
      name: 'CreateUpdateMonitor',
      values: <DBusValue>[DBusDict.stringVariant(<String, DBusValue>{})],
      replySignature: DBusSignature('o'),
    );
    final DBusObjectPath handle = reply.returnValues.first.asObjectPath();
    return _DBusFlatpakUpdateMonitor(_client, handle);
  }

  @override
  Future<void> spawnLatest(List<String> argv) async {
    await _client.callMethod(
      destination: _busName,
      path: _path,
      interface: _interface,
      name: 'Spawn',
      values: <DBusValue>[
        DBusArray.byte(_nulTerminated('/')),
        DBusArray(
          DBusSignature('ay'),
          argv.map((String a) => DBusArray.byte(_nulTerminated(a))),
        ),
        DBusDict(DBusSignature('u'), DBusSignature('h')),
        DBusDict(DBusSignature('s'), DBusSignature('s')),
        const DBusUint32(_spawnLatestVersion),
        DBusDict.stringVariant(<String, DBusValue>{}),
      ],
      replySignature: DBusSignature('u'),
    );
  }

  /// `ay` paths and arguments are C strings: the portal reads up to the NUL.
  static List<int> _nulTerminated(String s) => <int>[...utf8.encode(s), 0];
}

class _DBusFlatpakUpdateMonitor implements FlatpakUpdateMonitor {
  _DBusFlatpakUpdateMonitor(this._client, this._handle)
    : progress = DBusSignalStream(
        _client,
        sender: DBusFlatpakPortal._busName,
        interface: DBusFlatpakPortal._monitorInterface,
        name: 'Progress',
        path: _handle,
        signature: DBusSignature('a{sv}'),
      ).map(_decode);

  final DBusClient _client;
  final DBusObjectPath _handle;

  @override
  final Stream<FlatpakUpdateProgress> progress;

  static FlatpakUpdateProgress _decode(DBusSignal signal) {
    final Map<String, Object?> info = <String, Object?>{
      for (final MapEntry<DBusValue, DBusValue> e
          in signal.values.first.asDict().entries)
        e.key.asString(): e.value.asVariant().toNative(),
    };
    return parseFlatpakUpdateProgress(info);
  }

  @override
  Future<void> update() => _client.callMethod(
    destination: DBusFlatpakPortal._busName,
    path: _handle,
    interface: DBusFlatpakPortal._monitorInterface,
    name: 'Update',
    values: <DBusValue>[
      const DBusString(''),
      DBusDict.stringVariant(<String, DBusValue>{}),
    ],
    replySignature: DBusSignature(''),
  );

  @override
  Future<void> close() async {
    try {
      await _client.callMethod(
        destination: DBusFlatpakPortal._busName,
        path: _handle,
        interface: DBusFlatpakPortal._monitorInterface,
        name: 'Close',
        replySignature: DBusSignature(''),
      );
    } on DBusMethodResponseException {
      // Already gone (portal restarted): nothing left to close.
    }
  }
}

/// Linux inside a Flatpak: check on GitHub, install through the Flatpak portal.
class FlatpakUpdater extends PackageManagedUpdater {
  FlatpakUpdater({
    required this.installation,
    FlatpakPortal Function()? portal,
    Future<void> Function()? exitForRestart,
  }) : _portal = portal ?? DBusFlatpakPortal.new,
       _exitForRestart =
           exitForRestart ?? const DesktopLifecycleService().exitApp;

  final FlatpakInstallation installation;
  final FlatpakPortal Function() _portal;
  final Future<void> Function() _exitForRestart;

  @override
  bool get supportsUpdateCheck => true;

  /// Only a branch the release CI publishes can be updated through the portal.
  @override
  bool get supportsInAppInstall => installation.channel != null;

  @override
  UpdateChannel? get installedChannel => installation.channel;

  @override
  Future<UpdateAsset?> selectAsset(
    List<Map<String, dynamic>> assets, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    if (!supportsInAppInstall) return null;
    for (final UpdateAsset asset in downloadableReleaseAssets(assets)) {
      if (flatpakAssetMatchesChannel(asset.name, channel)) return asset;
    }
    return null;
  }

  @override
  Future<void> stage(
    String version, {
    required void Function(double progress) onProgress,
    UpdateDownloadCancellation? cancellation,
  }) async {
    final FlatpakUpdateMonitor monitor = await _portal().createUpdateMonitor();
    final Completer<void> finished = Completer<void>();
    final StreamSubscription<FlatpakUpdateProgress> sub = monitor.progress
        .listen((FlatpakUpdateProgress p) {
          if (finished.isCompleted) return;
          switch (p.status) {
            case FlatpakUpdateStatus.running:
              onProgress(p.overall);
            case FlatpakUpdateStatus.done:
              onProgress(1);
              finished.complete();
            case FlatpakUpdateStatus.empty:
              finished.completeError(
                const FlatpakUpdateNotPublishedException(),
              );
            case FlatpakUpdateStatus.error:
              finished.completeError(
                FlatpakUpdateException(
                  p.errorMessage ?? p.error ?? 'update failed',
                  error: p.error,
                ),
              );
          }
        });
    // The portal transaction itself cannot be cancelled. Cancelling stops
    // waiting; if the pull still finishes, the new version simply starts on the
    // next launch.
    cancellation?.registerAbort(() {
      if (!finished.isCompleted) {
        finished.completeError(const UpdateDownloadCancelledException());
      }
    });
    try {
      // Wait on the result from the start: a cancel or an early Progress error
      // can arrive while the Update call is still in flight. The Update call
      // goes out after a timer tick so the Progress match rule (added when
      // [sub] started listening) reaches the bus first.
      await Future.wait(<Future<void>>[
        finished.future,
        Future<void>.delayed(Duration.zero, monitor.update),
      ], eagerError: true);
    } finally {
      cancellation?.clearAbort();
      await sub.cancel();
      await monitor.close();
    }
  }

  @override
  Future<void> restartIntoStagedUpdate(String version) async {
    // `command: fushi` in the manifest; the marker makes the new process wait
    // for this one to release the single-instance bus name (linux/runner).
    await _portal().spawnLatest(<String>[
      'fushi',
      DesktopLifecycleService.restartMarkerArg,
    ]);
    await _exitForRestart();
  }
}

/// User-facing text for a failed package-managed install.
String describeManagedInstallFailure(Object error) {
  if (error is FlatpakUpdateNotPublishedException) {
    return t.update_flatpak_not_published;
  }
  if (error is FlatpakUpdateException && error.needsNewPermissions) {
    return t.update_flatpak_needs_permissions;
  }
  return '${t.update_download_failed}: $error';
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';

/// Installed tracking plugins: install, enable / disable, remove, runtimes
/// and this device's sign-in state (spec
/// `docs/specs/2026-11-10-tracking-plugins.md` §5).
///
/// Layout under [rootDir] (nothing in Drift; deleting the folder removes
/// everything):
/// - `<id>/`: the installed package;
/// - `.storage/<id>.json`: the plugin's `fushi.storage`;
/// - `.credentials/`: the engine's credential vault (tracking domain);
/// - `.state.json`: `{"enabled": {id: bool}, "accounts": {id: {loggedIn,
///   name}}}`. A missing enabled entry means enabled. Accounts are per device
///   and never synced: each device signs in on its own.
class TrackingPluginManager {
  TrackingPluginManager({
    required this.rootDir,
    required TrackingPluginEngine engine,
    TrackingRateGate Function(int requestsPerMinute)? rateGateFactory,
  }) : _engine = engine,
       _rateGateFactory =
           rateGateFactory ??
           ((int perMinute) => TrackingRateGate(maxRequests: perMinute));

  final Directory rootDir;
  final TrackingPluginEngine _engine;
  final TrackingRateGate Function(int requestsPerMinute) _rateGateFactory;

  /// Same rule as the engine's manifest id check.
  static final RegExp _idPattern = RegExp(
    r'^(?!.*\.\.)[a-z0-9][a-z0-9._-]{0,62}[a-z0-9]$',
  );

  final _Changes _changes = _Changes();

  /// Fires after install, uninstall, enable / disable, a sign-in change and
  /// every completed [list].
  Listenable get changes => _changes;

  bool get isSupported => _engine.isSupported;

  File get _stateFile => File('${rootDir.path}/.state.json');

  File storageFileFor(String id) => File('${rootDir.path}/.storage/$id.json');

  Directory _dirOf(String id) => Directory('${rootDir.path}/$id');

  _State? _state;
  int _stateWrites = 0;
  bool _disposed = false;

  /// Plugins being removed or reinstalled under a new signer: no runtime is
  /// opened for them meanwhile.
  final Set<String> _blocked = <String>{};
  final Map<String, Future<TrackingPluginRuntime>> _runtimes =
      <String, Future<TrackingPluginRuntime>>{};

  /// One request budget per plugin, kept across runtime reopens so a crash
  /// or reinstall cannot reset the count.
  final Map<String, ({int perMinute, TrackingRateGate gate})> _gates =
      <String, ({int perMinute, TrackingRateGate gate})>{};

  List<InstalledTrackingPlugin> _installed = const <InstalledTrackingPlugin>[];

  /// Packages built into this app build, by the site id they serve: plugin id
  /// and package digest (SHA-256 of `files.json`, computed by the engine from
  /// the bundled asset in [ensureBundled]). A reserved site id is accepted
  /// only from the installed package with exactly this id and digest: a third
  /// party cannot produce the digest without shipping the very same files.
  final Map<String, ({String pluginId, String digest})> _bundled =
      <String, ({String pluginId, String digest})>{};

  /// [id] is a package bundled with this app (it cannot be removed).
  bool isBundled(String id) => _bundled.values.any(
    (({String pluginId, String digest}) b) => b.pluginId == id,
  );

  /// The installed copy of a bundled package is the pinned one.
  bool _isPinned(TrackingPluginInfo info) {
    final ({String pluginId, String digest})? pin = _bundled[info.site?.siteId];
    return pin != null &&
        pin.pluginId == info.id &&
        pin.digest.toLowerCase() == info.digest.toLowerCase();
  }

  /// A side-loaded package may not serve [siteId].
  bool _reserved(String siteId) =>
      kReservedTrackingSiteIds.contains(siteId) || _bundled.containsKey(siteId);

  /// The result of the last [list] (empty before the first one).
  List<InstalledTrackingPlugin> get installed => _installed;

  /// Plugins registered as tracking providers (from the last [list]).
  List<InstalledTrackingPlugin> get registered => <InstalledTrackingPlugin>[
    for (final InstalledTrackingPlugin plugin in _installed)
      if (plugin.registered) plugin,
  ];

  Future<_State> _loadState() async => _state ??= await _readState();

  Future<_State> _readState() async {
    try {
      final Object? json = jsonDecode(await _stateFile.readAsString());
      return _State.fromJson(json);
    } on FileSystemException {
      return _State.empty();
    } on FormatException {
      return _State.empty();
    }
  }

  Future<void> _writeState(_State state) async {
    await rootDir.create(recursive: true);
    final File tmp = File('${_stateFile.path}.$pid.${++_stateWrites}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await tmp.rename(_stateFile.path);
  }

  void _notify() {
    if (!_disposed) _changes.fire();
  }

  /// Lists installed plugins (each re-hashed), works out which ones are
  /// registered, stores the result in [installed] and fires [changes].
  ///
  /// Two enabled plugins with the same site id: the one whose id sorts first
  /// is kept, the other gets [InstalledTrackingPlugin.conflictsWith]. A
  /// plugin claiming a reserved id ([kReservedTrackingSiteIds]) is registered
  /// only when it is the package pinned by [ensureBundled]; that package is
  /// marked [InstalledTrackingPlugin.builtIn] and wins its site.
  Future<List<InstalledTrackingPlugin>> list() async {
    final _State state = await _loadState();
    final List<InstalledTrackingPlugin> found = <InstalledTrackingPlugin>[];
    if (rootDir.existsSync()) {
      final List<Directory> dirs = <Directory>[
        for (final FileSystemEntity entity in rootDir.listSync())
          if (entity is Directory && _idPattern.hasMatch(_nameOf(entity)))
            entity,
      ]..sort((Directory a, Directory b) => _nameOf(a).compareTo(_nameOf(b)));
      for (final Directory dir in dirs) {
        final String id = _nameOf(dir);
        found.add(await _describe(id, dir, state.enabled[id] ?? true));
      }
    }
    final Map<String, String> siteOwner = <String, String>{};
    final List<InstalledTrackingPlugin> resolved = <InstalledTrackingPlugin>[
      for (final InstalledTrackingPlugin plugin in found)
        if (plugin.valid && _isPinned(plugin.info!))
          InstalledTrackingPlugin(
            id: plugin.id,
            enabled: plugin.enabled,
            info: plugin.info,
            builtIn: true,
          )
        else if (!plugin.enabled || !plugin.valid)
          plugin
        else if (_reserved(plugin.info!.site!.siteId))
          InstalledTrackingPlugin(
            id: plugin.id,
            enabled: plugin.enabled,
            info: plugin.info,
            reservedSite: true,
          )
        else if (siteOwner[plugin.info!.site!.siteId] case final String owner)
          InstalledTrackingPlugin(
            id: plugin.id,
            enabled: plugin.enabled,
            info: plugin.info,
            conflictsWith: owner,
          )
        else
          _own(siteOwner, plugin),
    ];
    // A reserved site has no other owner, so the built-in package needs no
    // entry in [siteOwner]: nothing else can conflict with it.
    resolved.sort(
      (InstalledTrackingPlugin a, InstalledTrackingPlugin b) =>
          (a.info?.name ?? a.id).compareTo(b.info?.name ?? b.id),
    );
    _installed = List<InstalledTrackingPlugin>.unmodifiable(resolved);
    _notify();
    return _installed;
  }

  static InstalledTrackingPlugin _own(
    Map<String, String> owners,
    InstalledTrackingPlugin plugin,
  ) {
    owners[plugin.info!.site!.siteId] = plugin.id;
    return plugin;
  }

  static String _nameOf(Directory dir) =>
      dir.uri.pathSegments.where((String s) => s.isNotEmpty).last;

  Future<InstalledTrackingPlugin> _describe(
    String id,
    Directory dir,
    bool enabled,
  ) async {
    try {
      final TrackingPluginInfo info = await _engine.verify(dir.path);
      final String? problem = _problemOf(info, id);
      return InstalledTrackingPlugin(
        id: id,
        enabled: enabled,
        info: problem == null ? info : null,
        error: problem,
      );
    } on TrackingPluginException catch (error) {
      return InstalledTrackingPlugin(
        id: id,
        enabled: enabled,
        error: error.message,
      );
    }
  }

  /// Why an installed, verified package cannot be used; null when it can.
  static String? _problemOf(TrackingPluginInfo info, String dirName) {
    if (!info.isTracking) return 'not a tracking plugin (kind: ${info.kind})';
    if (info.id != dirName) return 'folder name does not match id ${info.id}';
    if (info.site == null) return 'the manifest has no usable tracking site';
    return null;
  }

  /// Checks a package for the install confirmation (nothing is written).
  /// Throws [TrackingPluginException]: broken package, or not a tracking
  /// plugin ([TrackingPluginErrorCode.notTrackingPlugin]).
  /// A package claiming a reserved site id that is not the bundled package
  /// throws [TrackingPluginErrorCode.reservedSite].
  Future<TrackingPluginInfo> inspect(Uint8List zip) async {
    final TrackingPluginInfo info = _requireTracking(
      await _engine.inspect(zip),
    );
    if (_reserved(info.site!.siteId) && !_isPinned(info)) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.reservedSite,
        'the site "${info.site!.siteId}" is reserved for Fushi; '
        'a plugin cannot take it',
        pluginId: info.id,
      );
    }
    return info;
  }

  /// Pins [zip], a package bundled with the app, as the only package allowed
  /// to serve its site, and installs it when the installed copy is missing or
  /// is any other package (an app upgrade or downgrade replaces it; a
  /// side-loaded package under the same id is replaced and, signed by someone
  /// else, its data wiped). The enabled switch is kept, so a user who turned
  /// the plugin off keeps it off. Returns true when it installed. Lists the
  /// plugins either way.
  Future<bool> ensureBundled(Uint8List zip) async {
    final TrackingPluginInfo info = _requireTracking(
      await _engine.inspect(zip),
    );
    _bundled[info.site!.siteId] = (pluginId: info.id, digest: info.digest);
    String? installed;
    final Directory dir = _dirOf(info.id);
    if (dir.existsSync()) {
      try {
        installed = (await _engine.verify(dir.path)).digest;
      } on TrackingPluginException {
        installed = null;
      }
    }
    if (installed != null &&
        installed.toLowerCase() == info.digest.toLowerCase()) {
      await list();
      return false;
    }
    await install(zip, info.digest);
    return true;
  }

  static TrackingPluginInfo _requireTracking(TrackingPluginInfo info) {
    if (!info.isTracking) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.notTrackingPlugin,
        'not a tracking plugin (kind: ${info.kind})',
        pluginId: info.id,
      );
    }
    if (info.site == null) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.invalidPackage,
        'the manifest has no usable tracking site',
        pluginId: info.id,
      );
    }
    return info;
  }

  /// [info]'s signer differs from the installed plugin with the same id
  /// (including signed <-> unsigned, or an installed copy that fails
  /// verification). False when no plugin with that id is installed. Such a
  /// package is treated as a new plugin: [install] wipes the old one's
  /// storage, credentials and account state.
  Future<bool> signerChanged(TrackingPluginInfo info) async {
    if (!_idPattern.hasMatch(info.id)) return false;
    final Directory dir = _dirOf(info.id);
    if (!dir.existsSync()) return false;
    try {
      return (await _engine.verify(dir.path)).signer != info.signer;
    } on TrackingPluginException {
      return true;
    }
  }

  /// Installs a package the user confirmed ([digest] from [inspect]). The
  /// same id is upgraded in place and its runtime closed; a changed signer
  /// wipes the old plugin's data first.
  Future<TrackingPluginInfo> install(Uint8List zip, String digest) async {
    final TrackingPluginInfo pending = await inspect(zip);
    final String id = pending.id;
    final bool reset = await signerChanged(pending);
    _blocked.add(id);
    try {
      await _dropRuntime(id);
      if (reset) await _clearData(id);
      final TrackingPluginInfo info = await _engine.install(
        zip,
        rootDir.path,
        digest,
      );
      await _dropRuntime(info.id);
      await list();
      return info;
    } finally {
      _blocked.remove(id);
    }
  }

  /// Removes the plugin's storage, credentials and account state.
  Future<void> _clearData(String id) async {
    final File storage = storageFileFor(id);
    if (storage.existsSync()) await storage.delete();
    await _engine.clearCredentials(rootDir.path, id);
    final _State state = await _loadState();
    if (state.accounts.remove(id) != null) await _writeState(state);
    _gates.remove(id);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final _State state = await _loadState();
    state.enabled[id] = enabled;
    await _writeState(state);
    if (!enabled) await _dropRuntime(id);
    await list();
  }

  /// Removes the package, its storage, its credentials and its account state.
  /// Links and queued updates in the database are kept (spec §4).
  /// A bundled package cannot be removed
  /// ([TrackingPluginErrorCode.builtIn]): turn it off instead.
  Future<void> uninstall(String id) async {
    if (!_idPattern.hasMatch(id)) return;
    if (isBundled(id)) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.builtIn,
        'a plugin built into Fushi can be turned off, not removed',
        pluginId: id,
      );
    }
    _blocked.add(id);
    try {
      await _dropRuntime(id);
      final Directory dir = _dirOf(id);
      if (dir.existsSync()) await dir.delete(recursive: true);
      await _clearData(id);
      final _State state = await _loadState();
      state.enabled.remove(id);
      await _writeState(state);
    } finally {
      _blocked.remove(id);
    }
    await list();
  }

  /// This device's sign-in state for [id] (signed out until [list] or
  /// [setAccount] loaded the state file).
  TrackingPluginAccount accountOf(String id) =>
      _state?.accounts[id] ?? TrackingPluginAccount.signedOut;

  /// Some plugin has a stored sign-in on this device (read from the state
  /// file; installed or not, enabled or not). Used once, to decide whether
  /// the Media tracking module starts on.
  Future<bool> hasAnySignIn() async {
    final _State state = await _loadState();
    return state.accounts.isNotEmpty;
  }

  /// Stores (or, signed out, forgets) this device's sign-in state for [id].
  Future<void> setAccount(String id, TrackingPluginAccount account) async {
    final _State state = await _loadState();
    final TrackingPluginAccount? before = state.accounts[id];
    if (account.loggedIn) {
      if (before == account) return;
      state.accounts[id] = account;
    } else {
      if (before == null) return;
      state.accounts.remove(id);
    }
    await _writeState(state);
    _notify();
  }

  /// The runtime of plugin [id], opened on first use and reopened after it
  /// stopped. Throws [TrackingPluginException] when the plugin is not
  /// installed, disabled, being removed or does not open.
  Future<TrackingPluginRuntime> runtime(String id) async {
    if (!_idPattern.hasMatch(id)) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.notInstalled,
        'invalid plugin id',
        pluginId: id,
      );
    }
    final _State state = await _loadState();
    while (true) {
      _requireUsable(id, state);
      final Future<TrackingPluginRuntime>? existing = _runtimes[id];
      if (existing == null) break;
      try {
        final TrackingPluginRuntime runtime = await existing;
        if (runtime.isAlive) {
          _requireUsable(id, state);
          return runtime;
        }
      } on TrackingPluginException {
        // The last open failed: open again (the user may have reinstalled).
      }
      // Remove only the one seen here: another caller may already have put
      // a fresh runtime in its place.
      if (identical(_runtimes[id], existing)) {
        _runtimes.remove(id);
        break;
      }
    }
    // No await between the check and the registration: atomic for callers.
    _requireUsable(id, state);
    final Future<TrackingPluginRuntime> opening = _open(id);
    _runtimes[id] = opening;
    return opening;
  }

  Future<TrackingPluginRuntime> _open(String id) async {
    final String dir = _dirOf(id).path;
    final TrackingPluginInfo verified = await _engine.verify(dir);
    final String? problem = _problemOf(verified, id);
    if (problem != null) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.unusable,
        problem,
        pluginId: id,
      );
    }
    final int perMinute = verified.site!.requestsPerMinute;
    final ({int perMinute, TrackingRateGate gate})? known = _gates[id];
    final TrackingRateGate gate = known != null && known.perMinute == perMinute
        ? known.gate
        : (_gates[id] = (
            perMinute: perMinute,
            gate: _rateGateFactory(perMinute),
          )).gate;
    return _engine.open(
      dir: dir,
      rootDir: rootDir.path,
      storageFile: storageFileFor(id),
      rateGate: gate,
    );
  }

  void _requireUsable(String id, _State state) {
    if (_disposed || _blocked.contains(id) || !_dirOf(id).existsSync()) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.notInstalled,
        'plugin is not installed',
        pluginId: id,
      );
    }
    if (state.enabled[id] == false) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.disabled,
        'plugin is disabled',
        pluginId: id,
      );
    }
  }

  Future<void> _dropRuntime(String id) async {
    final Future<TrackingPluginRuntime>? opening = _runtimes.remove(id);
    if (opening == null) return;
    final TrackingPluginRuntime runtime;
    try {
      runtime = await opening;
    } on TrackingPluginException {
      // It never opened: nothing to close.
      return;
    }
    await runtime.close();
  }

  /// Closes every runtime. The manager is unusable afterwards.
  Future<void> dispose() async {
    _disposed = true;
    for (final String id in _runtimes.keys.toList()) {
      await _dropRuntime(id);
    }
    _changes.dispose();
  }
}

/// [ChangeNotifier] with a public trigger for [TrackingPluginManager.changes].
final class _Changes extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// The contents of `.state.json`, kept in memory after the first read.
final class _State {
  _State(this.enabled, this.accounts);

  factory _State.empty() =>
      _State(<String, bool>{}, <String, TrackingPluginAccount>{});

  factory _State.fromJson(Object? json) {
    if (json is! Map) return _State.empty();
    final Object? enabled = json['enabled'];
    final Object? accounts = json['accounts'];
    return _State(
      <String, bool>{
        if (enabled is Map)
          for (final MapEntry<Object?, Object?> e in enabled.entries)
            if (e.value is bool) '${e.key}': e.value! as bool,
      },
      <String, TrackingPluginAccount>{
        if (accounts is Map)
          for (final MapEntry<Object?, Object?> e in accounts.entries)
            if (TrackingPluginAccount.fromJson(e.value)
                case final TrackingPluginAccount account when account.loggedIn)
              '${e.key}': account,
      },
    );
  }

  final Map<String, bool> enabled;
  final Map<String, TrackingPluginAccount> accounts;

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'accounts': <String, Object?>{
      for (final MapEntry<String, TrackingPluginAccount> e in accounts.entries)
        e.key: e.value.toJson(),
    },
  };
}

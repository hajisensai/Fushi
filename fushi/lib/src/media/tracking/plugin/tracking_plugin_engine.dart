/// The tracking plugin host's only contact with the shared sandbox engine
/// (`package:fushi_music` plugin FFI: QuickJS runtime, package verification,
/// network policy, credential vault). Everything else in the tracking code
/// talks to [TrackingPluginEngine] / [TrackingPluginRuntime], so the engine
/// can move to its own native crate without touching the rest (spec
/// `docs/specs/2026-11-10-tracking-plugins.md` §5).
///
/// Engine exceptions are mapped to [TrackingPluginException] here; no
/// music-named type leaves this file.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/music/plugin/music_plugin_vault_key.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_engine/media/tracking/tracking_rate_gate.dart';
import 'package:fushi_music/fushi_music.dart';

/// Secure-storage entry of the tracking vault's data key. Tracking has its
/// own key: wiping or rotating one plugin system's key never touches the
/// other's credentials.
const String kTrackingPluginVaultKeyName =
    'fushi.tracking_plugins.vault_key.v1';

/// Vault domain of tracking plugins (the engine keeps it apart from music).
const String _vaultDomain = 'tracking';

/// One plugin HTTP request after the engine checked it against the grant
/// (`{method, url, headers, body?, timeoutMs?}`), and its response
/// (`{status, url, headers, setCookies, body}`).
typedef TrackingPluginHttpSend =
    Future<Map<String, Object?>> Function(Map<String, Object?> request);

/// Installs, verifies and opens tracking plugins.
abstract interface class TrackingPluginEngine {
  /// The platform's native library has the plugin runtime.
  bool get isSupported;

  /// Checks a package without writing anything.
  Future<TrackingPluginInfo> inspect(Uint8List zip);

  /// Unpacks [zip] into `<rootDir>/<id>/` when its digest is [digest].
  Future<TrackingPluginInfo> install(
    Uint8List zip,
    String rootDir,
    String digest,
  );

  /// Re-hashes an installed plugin directory.
  Future<TrackingPluginInfo> verify(String dir);

  /// Opens the plugin in [dir]. Every HTTP request it makes first waits on
  /// [rateGate]. Credentials live in `<rootDir>/.credentials/`, storage in
  /// [storageFile].
  Future<TrackingPluginRuntime> open({
    required String dir,
    required String rootDir,
    required File storageFile,
    required TrackingRateGate rateGate,
  });

  /// Deletes every credential of plugin [pluginId] under [rootDir].
  Future<void> clearCredentials(String rootDir, String pluginId);
}

/// A running plugin.
abstract interface class TrackingPluginRuntime {
  TrackingPluginInfo get info;

  /// False once the runtime stopped or was closed; the manager reopens it.
  bool get isAlive;

  /// Calls capability [method]. Throws [TrackingPluginException].
  Future<Object?> invoke(String method, Map<String, Object?> args);

  /// [url] is inside the plugin's network grant.
  bool allowsUrl(String url);

  Future<void> close();
}

/// [TrackingPluginEngine] on the shared sandbox engine.
final class SharedTrackingPluginEngine implements TrackingPluginEngine {
  /// [httpSend] replaces only the network leg (tests: no real network); the
  /// rate gate, grant checks and engine plumbing stay as in production.
  SharedTrackingPluginEngine({
    required HttpClient Function() httpClientFactory,
    required void Function(String pluginId, String level, String message) log,
    Future<Uint8List?> Function()? vaultKey,
    TrackingPluginHttpSend? httpSend,
    int budgetMs = 2000,
  }) : _httpClientFactory = httpClientFactory,
       _log = log,
       _vaultKey = vaultKey,
       _httpSend = httpSend,
       _budgetMs = budgetMs;

  /// The app's engine for the plugin root [rootDir]: vault key in the system
  /// secure storage under [kTrackingPluginVaultKeyName] (Windows: the native
  /// library's DPAPI-protected key file, as for music).
  factory SharedTrackingPluginEngine.forApp({
    required String rootDir,
    required HttpClient Function() httpClientFactory,
    required void Function(String pluginId, String level, String message) log,
  }) => SharedTrackingPluginEngine(
    httpClientFactory: httpClientFactory,
    log: log,
    vaultKey: MusicPluginVaultKey(
      vaultRoot: rootDir,
      store: const FlutterMusicPluginSecretStore(),
      secretName: kTrackingPluginVaultKeyName,
    ).call,
  );

  final HttpClient Function() _httpClientFactory;
  final void Function(String pluginId, String level, String message) _log;
  final Future<Uint8List?> Function()? _vaultKey;
  final TrackingPluginHttpSend? _httpSend;
  final int _budgetMs;

  static bool get supported => MusicPluginNative.isSupported;

  @override
  bool get isSupported => supported;

  TrackingPluginInfo _info(Map<String, Object?> summary) =>
      TrackingPluginInfo.fromSummary(
        summary,
        trustedSigners: kMusicPluginTrustedSigners,
      );

  Map<String, Object?> _checked(
    Map<String, Object?> result,
    TrackingPluginErrorCode code,
  ) {
    if (result['error'] case final String error) {
      throw TrackingPluginException(code, error);
    }
    return result;
  }

  @override
  Future<TrackingPluginInfo> inspect(Uint8List zip) async => _info(
    _checked(
      await MusicPluginNativeAsync.inspect(zip),
      TrackingPluginErrorCode.invalidPackage,
    ),
  );

  @override
  Future<TrackingPluginInfo> install(
    Uint8List zip,
    String rootDir,
    String digest,
  ) async => _info(
    _checked(
      await MusicPluginNativeAsync.install(zip, rootDir, digest),
      TrackingPluginErrorCode.invalidPackage,
    ),
  );

  @override
  Future<TrackingPluginInfo> verify(String dir) async => _info(
    _checked(
      await MusicPluginNativeAsync.verify(dir),
      TrackingPluginErrorCode.unusable,
    ),
  );

  @override
  Future<void> clearCredentials(String rootDir, String pluginId) async {
    // The vault file of a plugin id holds every domain's entries; the plugin
    // is gone either way, so the whole file goes.
    _checked(
      await MusicPluginNativeAsync.vault(rootDir, <String, Object?>{
        'op': 'clear',
        'plugin': pluginId,
      }),
      TrackingPluginErrorCode.credentials,
    );
  }

  @override
  Future<TrackingPluginRuntime> open({
    required String dir,
    required String rootDir,
    required File storageFile,
    required TrackingRateGate rateGate,
  }) async {
    final _SharedRuntime runtime = _SharedRuntime(rateGate);
    final MusicPluginInstance instance;
    try {
      instance = await MusicPluginInstance.open(
        dir: dir,
        storageFile: storageFile,
        httpClientFactory: _httpClientFactory,
        log: _log,
        vaultRoot: rootDir,
        vaultKey: _vaultKey,
        vaultDomain: _vaultDomain,
        budgetMs: _budgetMs,
        httpPerformer: runtime._perform,
      );
    } on MusicPluginException catch (error) {
      runtime._closeNetwork();
      throw TrackingPluginException(
        TrackingPluginErrorCode.unusable,
        error.message,
      );
    }
    final MusicPluginPackageInfo package = instance.info;
    // The directory may have been swapped between verify and open: the
    // summary of the opened package decides.
    if (package.manifest.kind != TrackingPluginInfo.trackingKind) {
      await instance.close();
      runtime._closeNetwork();
      throw TrackingPluginException(
        TrackingPluginErrorCode.notTrackingPlugin,
        'not a tracking plugin (kind: ${package.manifest.kind})',
        pluginId: package.manifest.id,
      );
    }
    runtime._attach(
      instance,
      TrackingPluginInfo(
        id: package.manifest.id,
        kind: package.manifest.kind,
        name: package.manifest.name,
        version: package.manifest.version,
        author: package.manifest.author,
        description: package.manifest.description,
        homepage: package.manifest.homepage,
        capabilities: package.manifest.capabilities,
        permissions: package.manifest.permissions,
        networkDomains: package.manifest.networkDomains,
        digest: package.digest,
        signer: package.signer,
        trustedSigner: package.trustedSigner,
        site: TrackingPluginSite.tryParse(package.manifest.tracking),
      ),
      _httpSend ?? runtime._defaultSend(_httpClientFactory),
    );
    return runtime;
  }
}

/// A plugin instance with its rate gate in front of every HTTP request.
final class _SharedRuntime implements TrackingPluginRuntime {
  _SharedRuntime(this._rateGate);

  final TrackingRateGate _rateGate;
  late final MusicPluginInstance _instance;
  late final TrackingPluginInfo _info;
  late final TrackingPluginHttpSend _send;
  MusicPluginGuardedHttp? _net;

  void _attach(
    MusicPluginInstance instance,
    TrackingPluginInfo info,
    TrackingPluginHttpSend send,
  ) {
    _instance = instance;
    _info = info;
    _send = send;
  }

  /// The engine's own HTTP path, unchanged: DNS pinned to public addresses,
  /// every redirect hop checked against the grant, the same size budget.
  TrackingPluginHttpSend _defaultSend(HttpClient Function() clientFactory) {
    final MusicPluginResponseBudget budget = MusicPluginResponseBudget(
      kMusicPluginInflightResponseBytes,
    );
    return (Map<String, Object?> request) => performMusicPluginHttp(
      request,
      net: _net ??= MusicPluginGuardedHttp(
        clientFactory(),
        resolve: InternetAddress.lookup,
      ),
      budget: budget,
      checkRedirect: (String url) =>
          _instance.checkRequestUrls(<String>[url])[url],
    );
  }

  /// The instance's HTTP hook: the budget first, then the request. A request
  /// arriving before [_attach] (cannot happen: the plugin runs only on
  /// invoke) would fail on the late field, never bypass the gate.
  Future<Map<String, Object?>> _perform(Map<String, Object?> request) async {
    await _rateGate.reserve();
    return _send(request);
  }

  void _closeNetwork() {
    _net?.close(force: true);
    _net = null;
  }

  @override
  TrackingPluginInfo get info => _info;

  @override
  bool get isAlive => _instance.isAlive;

  @override
  Future<Object?> invoke(String method, Map<String, Object?> args) async {
    try {
      return await _instance.invoke(method, args);
    } on MusicPluginTimeoutException catch (error) {
      throw TrackingPluginException(
        TrackingPluginErrorCode.timeout,
        error.message,
        pluginId: _info.id,
      );
    } on MusicPluginException catch (error) {
      // A dead runtime fails every call with the reason it died; an error the
      // plugin threw leaves the runtime alive.
      if (!_instance.isAlive) {
        throw TrackingPluginException(
          TrackingPluginErrorCode.runtimeStopped,
          error.message,
          pluginId: _info.id,
        );
      }
      throw trackingPluginErrorFromMessage(error.message, pluginId: _info.id);
    }
  }

  @override
  bool allowsUrl(String url) =>
      _instance.checkRequestUrls(<String>[url]).containsKey(url);

  @override
  Future<void> close() async {
    await _instance.close();
    _closeNetwork();
  }
}

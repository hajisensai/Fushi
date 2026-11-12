/// Moves the sign-in of the built-in Bangumi provider into the bundled
/// Bangumi plugin (spec `docs/specs/2026-11-11-bangumi-bundled-plugin.md` §4).
///
/// Runs on every start where `isBangumiServedByPlugin` is true, after the
/// bundled plugin was installed ([startBundledTrackingPlugins], called by the
/// app's start). On that path the tracking service is built without the
/// built-in Dart Bangumi (`MediaTrackingService(builtInBangumi: false)`), so
/// the token is never moved while the Dart provider serves `bangumi`, and the
/// Dart provider never serves it after. It only acts while the token preference
/// holds a token, so it is idempotent: after a successful move the
/// preference row is gone. A token that arrives later in the preference (a
/// paired device importing the host's service config from a host that still
/// keeps it there) is moved on the next start.
///
/// What carries over by itself: links (provider id `bangumi`), the enabled
/// and per-kind switches (frozen `bangumi` keys from
/// `TrackingProviderPrefKeys.forProvider`) and the token-scoped watermarks
/// (same account, not reset).
library;

import 'dart:typed_data';

import 'package:fushi/src/media/tracking/plugin/bundled_tracking_plugins.dart';
import 'package:fushi/src/media/tracking/plugin/plugin_tracking_provider.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart'
    show kBangumiAccessTokenPref, kBangumiAccountNamePref;

/// What [migrateBangumiTokenToPlugin] did.
enum BangumiTokenMigration {
  /// No token in the preference: nothing to do.
  nothing,

  /// The token is in the plugin's vault and the preferences are removed.
  moved,

  /// The bundled plugin is not registered (missing, off, broken) or did not
  /// take the token: the preference stays and the next start tries again.
  kept,
}

/// Imports the token saved in [kBangumiAccessTokenPref] into the bundled
/// plugin through its login op `import` (no network), with the account name
/// from [kBangumiAccountNamePref], then removes both preference rows with
/// [removePref]. The token is never logged; on failure [onError] gets the
/// error (plugin errors never contain the token).
///
/// Removing the rows (instead of writing empty values) keeps the host from
/// exporting an empty token to paired devices, which would erase a device's
/// own token (a device on the built-in provider, such as iOS, still uses it).
Future<BangumiTokenMigration> migrateBangumiTokenToPlugin({
  required PrefStore preferences,
  required Future<void> Function(String key) removePref,
  required TrackingPluginManager manager,
  required PluginTrackingProviders providers,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final Object? stored = preferences.getPref(
    kBangumiAccessTokenPref,
    defaultValue: '',
  );
  final String token = stored is String ? stored.trim() : '';
  if (token.isEmpty) return BangumiTokenMigration.nothing;
  final bool bundled = manager.installed.any(
    (InstalledTrackingPlugin p) =>
        p.id == kBundledBangumiPluginId && p.builtIn && p.registered,
  );
  final PluginTrackingProvider? provider = bundled
      ? providers.byPluginId(kBundledBangumiPluginId)
      : null;
  if (provider == null) return BangumiTokenMigration.kept;
  final Object? storedName = preferences.getPref(
    kBangumiAccountNamePref,
    defaultValue: '',
  );
  final String name = storedName is String ? storedName.trim() : '';
  try {
    final TrackingPluginLoginChallenge step = await provider.importLogin(
      <String, String>{'token': token, 'name': ?(name.isEmpty ? null : name)},
    );
    if (step.state != TrackingPluginLoginState.done) {
      return BangumiTokenMigration.kept;
    }
  } on Object catch (error, stack) {
    onError?.call(error, stack);
    return BangumiTokenMigration.kept;
  }
  await removePref(kBangumiAccessTokenPref);
  await removePref(kBangumiAccountNamePref);
  return BangumiTokenMigration.moved;
}

/// The plugin path's start (spec `docs/specs/2026-11-11-bangumi-bundled-plugin.md`
/// §3 to §5): pins and installs the bundled plugins (then the manager has
/// listed the plugins and the app registers their providers), then moves the
/// built-in Bangumi token into the bundled Bangumi plugin. Idempotent: on
/// later starts the installed copy matches and there is no token left to move.
/// A bundled plugin turned off keeps the token preference (moved once the
/// plugin is on again at a later start) and Bangumi stays off meanwhile.
Future<BangumiTokenMigration> startBundledTrackingPlugins({
  required TrackingPluginManager manager,
  required PluginTrackingProviders providers,
  required PrefStore preferences,
  required Future<void> Function(String key) removePref,
  required void Function(Object error, StackTrace stack) onError,
  List<BundledTrackingPlugin> plugins = kBundledTrackingPlugins,
  Future<Uint8List> Function(BundledTrackingPlugin plugin) load =
      loadBundledTrackingPlugin,
}) async {
  await installBundledTrackingPlugins(
    manager,
    plugins: plugins,
    load: load,
    onError: onError,
  );
  return migrateBangumiTokenToPlugin(
    preferences: preferences,
    removePref: removePref,
    manager: manager,
    providers: providers,
    onError: onError,
  );
}

/// Signs the bundled Bangumi plugin in with an access [token] through its
/// `token` form (the plugin checks it with Bangumi): the control channel's
/// `connect` where the plugin serves `bangumi`. Returns the account name.
/// Throws [StateError] when the bundled plugin is not registered (missing or
/// turned off) and [ArgumentError] with the plugin's message when the token
/// is refused. The token is never logged.
Future<String> signInBundledBangumiWithToken(
  PluginTrackingProviders? providers,
  String token,
) async {
  final PluginTrackingProvider? provider = providers?.byPluginId(
    kBundledBangumiPluginId,
  );
  if (provider == null) {
    throw StateError(
      'The bundled Bangumi plugin is off or not loaded: turn it on in '
      'Settings > Media tracking > Tracking plugins',
    );
  }
  const String method = 'token';
  final TrackingPluginLoginChallenge form = await provider.beginLogin(method);
  final TrackingPluginLoginChallenge step = await provider.submitLogin(
    method,
    session: form.session,
    action: 'save',
    inputs: <String, String>{'token': token},
  );
  if (step.state != TrackingPluginLoginState.done) {
    throw ArgumentError(step.message ?? 'Bangumi did not accept the token');
  }
  return provider.accountName;
}

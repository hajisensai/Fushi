/// User-facing wording for tracking plugins: errors, permissions, kinds and
/// signer state. Plugin-provided text is shown as data, never as markup.
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_models.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';

/// Longest piece of plugin-provided error text shown in the UI.
const int _maxPluginErrorText = 200;

/// The first line of [text], cut to [_maxPluginErrorText] characters.
String _firstLine(String text) {
  final String line = text.trim().split('\n').first.trim();
  return line.length > _maxPluginErrorText
      ? '${line.substring(0, _maxPluginErrorText)}…'
      : line;
}

/// A translated message for [error]. Only [TrackingPluginErrorCode.pluginError]
/// carries the plugin's own text (first line); everything else is ours.
String trackingPluginErrorText(Object error) {
  if (error is! TrackingPluginException) {
    return t.media_tracking_plugins_error_generic;
  }
  return switch (error.code) {
    TrackingPluginErrorCode.unauthorized =>
      t.media_tracking_plugins_error_unauthorized,
    TrackingPluginErrorCode.rateLimited =>
      t.media_tracking_plugins_error_rate_limited,
    TrackingPluginErrorCode.notFound =>
      t.media_tracking_plugins_error_not_found,
    TrackingPluginErrorCode.kindMismatch =>
      t.media_tracking_plugins_error_kind_mismatch,
    TrackingPluginErrorCode.pluginError =>
      error.message.trim().isEmpty
          ? t.media_tracking_plugins_error_generic
          : t.media_tracking_plugins_error_plugin_error(
              message: _firstLine(error.message),
            ),
    TrackingPluginErrorCode.runtimeStopped =>
      t.media_tracking_plugins_error_runtime_stopped,
    TrackingPluginErrorCode.timeout => t.media_tracking_plugins_error_timeout,
    TrackingPluginErrorCode.invalidPackage =>
      t.media_tracking_plugins_error_invalid_package,
    TrackingPluginErrorCode.notTrackingPlugin =>
      t.media_tracking_plugins_error_not_tracking_plugin,
    TrackingPluginErrorCode.reservedSite =>
      t.media_tracking_plugins_error_reserved_site,
    _ => t.media_tracking_plugins_error_generic,
  };
}

/// A manifest permission in plain words.
String trackingPluginPermissionLabel(String permission) => switch (permission) {
  'network' => t.media_tracking_plugins_perm_network,
  'credentials' => t.media_tracking_plugins_perm_credentials,
  'storage' => t.media_tracking_plugins_perm_storage,
  'insecureHttp' => t.media_tracking_plugins_perm_insecure_http,
  _ => t.media_tracking_plugins_perm_other(name: permission),
};

/// What a plugin tracks, in the same words as the "Tracking sites" switches.
String trackingPluginKindLabel(TrackingKind kind) => switch (kind) {
  TrackingKind.anime => t.media_tracking_anime,
  TrackingKind.manga => t.media_tracking_manga,
  TrackingKind.novel => t.media_tracking_novel,
  TrackingKind.game => t.media_tracking_game,
};

/// The kinds of [site] in a fixed order (anime, manga, novels, games).
String trackingPluginKindsText(TrackingPluginSite site) => <String>[
  for (final TrackingKind kind in const <TrackingKind>[
    TrackingKind.anime,
    TrackingKind.manga,
    TrackingKind.novel,
    TrackingKind.game,
  ])
    if (site.kinds.contains(kind)) trackingPluginKindLabel(kind),
].join(' · ');

/// A signing key shortened for display.
String trackingPluginShortKey(String key) =>
    key.length <= 16 ? key : '${key.substring(0, 16)}…';

/// Unsigned / signed by a key / verified publisher.
String trackingPluginSignerText(TrackingPluginInfo info) =>
    switch (info.signer) {
      null => t.media_tracking_plugins_signer_unsigned,
      final String key when info.trustedSigner =>
        t.media_tracking_plugins_signer_trusted(
          key: trackingPluginShortKey(key),
        ),
      final String key => t.media_tracking_plugins_signer_signed(
        key: trackingPluginShortKey(key),
      ),
    };

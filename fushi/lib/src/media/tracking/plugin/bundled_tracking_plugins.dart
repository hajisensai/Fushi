/// Tracking plugins that ship inside the app (spec
/// `docs/specs/2026-11-11-bangumi-bundled-plugin.md` §3 and §9).
///
/// Each one's source lives in `plugins/tracking/<name>/`; the packed package
/// is checked in as `assets/tracking_plugins/<id>.fushiplug` (no Node at build
/// or run time) and the guard
/// `test/build/bundled_tracking_plugin_asset_guard_test.dart` fails when a
/// source and its asset drift. Repack with
/// `node tools/tracking-plugin-sdk/fushi-tracking-plugin.mjs pack plugins/tracking/<name> --out fushi/assets/tracking_plugins/<id>.fushiplug`.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';

/// How the app keeps a bundled plugin.
enum BundledTrackingPluginPolicy {
  /// Owns a reserved site (pinned by digest), always installed, can be turned
  /// off but not removed: Bangumi.
  builtIn,

  /// Installed on first start (or the first start after an upgrade that
  /// added it) and updated with the app, can be turned off and removed. A
  /// removal is remembered on the device and never undone automatically; its
  /// site id is not reserved. A copy the user installed themselves is never
  /// replaced ([TrackingPluginManager.ensureBundled]).
  included,
}

/// One plugin bundled with the app.
final class BundledTrackingPlugin {
  const BundledTrackingPlugin({required this.id, required this.policy});

  /// The package id (`manifest.json` `id`).
  final String id;

  final BundledTrackingPluginPolicy policy;

  /// The asset holding the packed package.
  String get asset => 'assets/tracking_plugins/$id.fushiplug';

  /// Can be removed (and is then not reinstalled automatically).
  bool get removable => policy == BundledTrackingPluginPolicy.included;
}

/// The bundled Bangumi plugin's package id.
const String kBundledBangumiPluginId = 'moe.fushi.tracking.bangumi';

/// Bangumi: built in, serves the reserved `bangumi` site.
const BundledTrackingPlugin kBundledBangumiPlugin = BundledTrackingPlugin(
  id: kBundledBangumiPluginId,
  policy: BundledTrackingPluginPolicy.builtIn,
);

/// AniList: included, removable.
const BundledTrackingPlugin kBundledAniListPlugin = BundledTrackingPlugin(
  id: 'moe.fushi.tracking.anilist',
  policy: BundledTrackingPluginPolicy.included,
);

/// MangaBaka: included, removable.
const BundledTrackingPlugin kBundledMangaBakaPlugin = BundledTrackingPlugin(
  id: 'moe.fushi.tracking.mangabaka',
  policy: BundledTrackingPluginPolicy.included,
);

/// Every bundled plugin, built-in ones first (their sites are pinned before
/// any other package is looked at).
const List<BundledTrackingPlugin> kBundledTrackingPlugins =
    <BundledTrackingPlugin>[
      kBundledBangumiPlugin,
      kBundledAniListPlugin,
      kBundledMangaBakaPlugin,
    ];

/// Reads a packed bundled plugin from the app bundle.
Future<Uint8List> loadBundledTrackingPlugin(
  BundledTrackingPlugin plugin,
) async {
  final ByteData data = await rootBundle.load(plugin.asset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Pins / installs every bundled plugin in [plugins]
/// ([TrackingPluginManager.ensureBundled]), then the manager has listed the
/// plugins. A bundled package that fails to load or install is reported to
/// [onError] and the others go on; the plugins are listed anyway (a built-in
/// site stays reserved: no side-loaded package can take it meanwhile).
Future<void> installBundledTrackingPlugins(
  TrackingPluginManager manager, {
  List<BundledTrackingPlugin> plugins = kBundledTrackingPlugins,
  Future<Uint8List> Function(BundledTrackingPlugin plugin) load =
      loadBundledTrackingPlugin,
  required void Function(Object error, StackTrace stack) onError,
}) async {
  bool failed = false;
  for (final BundledTrackingPlugin plugin in plugins) {
    try {
      await manager.ensureBundled(
        await load(plugin),
        removable: plugin.removable,
      );
    } on Object catch (error, stack) {
      failed = true;
      onError(error, stack);
    }
  }
  if (failed || plugins.isEmpty) await manager.list();
}

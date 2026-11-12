/// Tracking plugins that ship inside the app (spec
/// `docs/specs/2026-11-11-bangumi-bundled-plugin.md` §3).
///
/// Bangumi's source lives in `plugins/tracking/bangumi/`; the packed package
/// is checked in as an asset (no Node at build or run time) and the guard
/// `test/build/bundled_tracking_plugin_asset_guard_test.dart` fails when the
/// two drift. Repack with
/// `node tools/tracking-plugin-sdk/fushi-tracking-plugin.mjs pack plugins/tracking/bangumi --out fushi/assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug`.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:fushi/src/media/tracking/plugin/tracking_plugin_manager.dart';

/// The bundled Bangumi plugin's package id.
const String kBundledBangumiPluginId = 'moe.fushi.tracking.bangumi';

/// The asset holding the packed Bangumi plugin.
const String kBundledBangumiPluginAsset =
    'assets/tracking_plugins/moe.fushi.tracking.bangumi.fushiplug';

/// Reads the packed Bangumi plugin from the app bundle.
Future<Uint8List> loadBundledBangumiPlugin() async {
  final ByteData data = await rootBundle.load(kBundledBangumiPluginAsset);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Pins and installs every bundled plugin ([TrackingPluginManager.ensureBundled]),
/// then the manager has listed the plugins. A bundled package that fails to
/// load or install is reported to [onError] and the plugins are listed anyway
/// (its site stays reserved: no side-loaded package can take it meanwhile).
Future<void> installBundledTrackingPlugins(
  TrackingPluginManager manager, {
  Future<Uint8List> Function() load = loadBundledBangumiPlugin,
  required void Function(Object error, StackTrace stack) onError,
}) async {
  try {
    await manager.ensureBundled(await load());
  } on Object catch (error, stack) {
    onError(error, stack);
    await manager.list();
  }
}

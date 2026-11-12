import 'package:fushi/src/media/tracking/plugin/tracking_plugin_engine.dart';
import 'package:fushi/src/models/store_compliance.dart';

/// Tracking plugins (Settings › Media tracking › Tracking plugins, plugin
/// tracking providers) exist: the store compliance gate (not on iOS: they
/// download and run third-party code) and a native library with the plugin
/// runtime.
///
/// The only place this is decided; consumers ask here. Guard:
/// `test/build/ios_store_compliance_guard_test.dart`.
bool get isTrackingPluginsAvailable =>
    StoreRestrictedCapability.trackingPlugins.isAvailable &&
    SharedTrackingPluginEngine.supported;

/// Which implementation serves the `bangumi` tracking site: the Bangumi
/// plugin bundled with the app where tracking plugins run, the built-in Dart
/// provider elsewhere (iOS, which has no plugin engine; user decision
/// 2026-11-11, spec `docs/specs/2026-11-11-bangumi-bundled-plugin.md` §5).
///
/// The only place this is decided; consumers ask here, never the platform.
bool get isBangumiServedByPlugin => isTrackingPluginsAvailable;

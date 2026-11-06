import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// One snapshot of the host window's OLE drop registration, as reported by the
/// vendored desktop_drop fork's `status` method (Windows only).
class DesktopDropStatus {
  const DesktopDropStatus({
    required this.registered,
    required this.ours,
    required this.lastRegisterResult,
    required this.registerCount,
    required this.elevated,
  });

  /// Parses the platform reply; null when the reply is not the expected map.
  static DesktopDropStatus? fromPlatform(Object? reply) {
    if (reply is! Map) return null;
    final Object? registered = reply['registered'];
    final Object? ours = reply['ours'];
    final Object? result = reply['lastRegisterResult'];
    final Object? count = reply['registerCount'];
    final Object? elevated = reply['elevated'];
    if (registered is! bool ||
        ours is! bool ||
        result is! int ||
        count is! int ||
        elevated is! bool) {
      return null;
    }
    return DesktopDropStatus(
      registered: registered,
      ours: ours,
      lastRegisterResult: result,
      registerCount: count,
      elevated: elevated,
    );
  }

  /// A drop target is registered on the Flutter view window.
  final bool registered;

  /// ...and it is still the one desktop_drop registered (not revoked/replaced).
  final bool ours;

  /// HRESULT of desktop_drop's last `RegisterDragDrop`.
  final int lastRegisterResult;

  /// How many times desktop_drop has (re)registered in this process.
  final int registerCount;

  /// The process runs elevated: Explorer (medium integrity) drags are then
  /// rejected by UIPI with the same forbidden cursor, whatever is registered.
  final bool elevated;

  /// desktop_drop's registration is intact.
  bool get healthy => registered && ours;

  @override
  String toString() =>
      'registered=$registered ours=$ours '
      'lastRegisterResult=0x${lastRegisterResult.toUnsigned(32).toRadixString(16)} '
      'registerCount=$registerCount elevated=$elevated';
}

/// Keeps desktop_drop's Windows OLE drag-and-drop registration verifiable and
/// repairable (TODO-1275 / BUG-361 / BUOxDR9WIJ).
///
/// History: BUG-361 assumed WebView2 usurps and then revokes the host window's
/// `IDropTarget`, and re-registered unconditionally after media closed. A
/// real-app probe (`integration_test/desktop_drop_registration_probe_itest.dart`,
/// 2026-10-27) showed the registration on the Flutter view HWND is **untouched**
/// across local video, composition-hosted WebView2 and window-hosted WebView2
/// open/close. So instead of blindly re-registering, [verifyAndRepair] asks the
/// native side for the registration state, re-registers only when it is really
/// missing or replaced, and writes anything abnormal (including an elevated
/// process, which makes Explorer drags fail through UIPI) to the diagnostic log
/// that ships with feedback reports.
///
/// The vendored fork (`third_party/desktop_drop/windows/desktop_drop_plugin.cpp`)
/// provides both `status` and `reinitialize` (`RevokeDragDrop` +
/// `RegisterDragDrop`).
class DesktopDropReinitializer {
  const DesktopDropReinitializer._();

  /// The channel name is fixed by the `desktop_drop` plugin.
  static const MethodChannel _channel = MethodChannel('desktop_drop');

  static const String _logSource = 'DesktopDrop';

  static bool _loggedElevation = false;

  /// Checks the host window's drop registration at a point where a native
  /// surface just went away ([reason] names it) and repairs it if it is gone.
  /// Windows-only; a no-op on every other platform.
  static Future<void> verifyAndRepair(String reason) async {
    if (kIsWeb || !Platform.isWindows) {
      return;
    }
    await verifyAndRepairOnChannel(reason);
  }

  /// [verifyAndRepair] without the platform gate. Exposed for tests, which
  /// cannot vary the host [Platform].
  @visibleForTesting
  static Future<void> verifyAndRepairOnChannel(String reason) async {
    final DesktopDropStatus? before = await _status();
    if (before == null) return;
    if (before.elevated && !_loggedElevation) {
      _loggedElevation = true;
      ErrorLogService.instance.logDiagnostic(
        _logSource,
        'process is elevated: Explorer drags are blocked by UIPI '
        '(forbidden cursor) [$reason] $before',
      );
    }
    if (before.healthy) return;
    await invokeReinitialize();
    final DesktopDropStatus? after = await _status();
    ErrorLogService.instance.logDiagnostic(
      _logSource,
      'drop registration lost at $reason; re-registered. '
      'before: $before; after: ${after ?? 'unknown'}',
    );
  }

  static Future<DesktopDropStatus?> _status() async {
    try {
      return DesktopDropStatus.fromPlatform(
        await _channel.invokeMethod<Object?>('status'),
      );
    } on MissingPluginException {
      // desktop_drop without the status patch: nothing to check.
      return null;
    } on PlatformException catch (e) {
      ErrorLogService.instance.logDiagnostic(_logSource, 'status failed: $e');
      return null;
    }
  }

  /// The raw status reply (probe / tests).
  @visibleForTesting
  static Future<DesktopDropStatus?> debugStatus() => _status();

  /// Re-registers the host window's drop target unconditionally.
  @visibleForTesting
  static Future<void> invokeReinitialize() async {
    try {
      await _channel.invokeMethod<void>('reinitialize');
    } on MissingPluginException {
      // desktop_drop without the TODO-1275 patch: nothing to restore.
    } catch (e) {
      debugPrint('[fushi-drop] reinitialize failed: $e');
    }
  }
}

/// Checks the drop registration whenever a page route leaves the root
/// navigator (BUOxDR9WIJ). Every page that hosts a native surface on Windows —
/// local video (mpv), web video (window-hosted WebView2), reader / browser /
/// lookup (composition WebView2), games — is a pushed route, so this is the one
/// place that sees all of them leave, instead of each page remembering to call
/// in (the old wiring only ran from `AppModel.closeMedia`, which video pages
/// never go through).
class DesktopDropRouteObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _verify('pop', route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _verify('remove', route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _verify('replace', oldRoute);
  }

  void _verify(String how, Route<dynamic> route) {
    if (route is! PageRoute<dynamic>) return;
    final String name = route.settings.name ?? route.runtimeType.toString();
    unawaited(DesktopDropReinitializer.verifyAndRepair('route $how: $name'));
  }
}

/// The single instance wired into `MaterialApp.navigatorObservers` (main.dart).
final DesktopDropRouteObserver desktopDropRouteObserver =
    DesktopDropRouteObserver();

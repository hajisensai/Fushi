import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/desktop_drop_reinitializer.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:material_ui/material_ui.dart';

/// TODO-1275 / BUG-361 guards.
///
/// After opening a reader/video/lookup WebView2 on Windows, the runtime usurps
/// the host window's OLE `IDropTarget`, and neither its teardown nor the fork's
/// `put_AllowExternalDrop(FALSE)` restores desktop_drop's registration — so
/// drag-import shows the "forbidden" cursor app-wide until restart. The fix
/// re-registers desktop_drop after media closes via a `reinitialize` method
/// added by the vendored fork (third_party/desktop_drop). These tests pin the
/// Dart wiring (channel + method name, error tolerance) and the C++ invariant (it
/// must actually re-register, not stay a NotImplemented no-op).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('desktop_drop');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('invokeReinitialize invokes desktop_drop.reinitialize once', () async {
    final List<String> calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      return null;
    });

    await DesktopDropReinitializer.invokeReinitialize();

    expect(calls, <String>['reinitialize'],
        reason: 'closeMedia must re-register desktop_drop via the '
            'desktop_drop channel reinitialize method');
  });

  test('invokeReinitialize swallows MissingPluginException (unpatched plugin)',
      () async {
    // No mock handler -> the platform side is absent, mirroring a desktop_drop
    // build without the TODO-1275 patch. Must complete, not throw.
    messenger.setMockMethodCallHandler(channel, null);

    await DesktopDropReinitializer.invokeReinitialize();
  });

  test(
      'desktop_drop vendored fork re-registers the OS drop target on reinitialize',
      () {
    // Vendored under third_party/ (TODO-1306 moved it off the pub-cache ci-patch);
    // the reinitialize invariant now lives in the tracked fork source.
    final List<String> candidates = <String>[
      '../third_party/desktop_drop/windows/desktop_drop_plugin.cpp',
      'third_party/desktop_drop/windows/desktop_drop_plugin.cpp',
    ];
    final File? patch = candidates.map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null);
    expect(patch, isNotNull,
        reason: 'desktop_drop vendored fork (reinitialize handler) not found');

    final String src = patch!.readAsStringSync();

    expect(src.contains('TODO-1275'), isTrue,
        reason: 'patch must carry the TODO-1275/BUG-361 root-cause marker');

    // The channel handler must service "reinitialize" (not stay the stock
    // NotImplemented-only handler), otherwise Dart re-registration is a no-op.
    expect(
        RegExp(r'method_name\(\)\s*==\s*"reinitialize"').hasMatch(src), isTrue,
        reason: 'patched plugin must handle the reinitialize method');

    // reinitialize must actually revoke the usurped target and re-register
    // desktop_drop's own; both OLE calls are the invariant that fixes the bug.
    expect(src.contains('RevokeDragDrop(window_handle_)'), isTrue,
        reason: 'reinitialize must RevokeDragDrop the stale (WebView2) target');
    expect(src.contains('RegisterDragDrop(window_handle_, this)'), isTrue,
        reason: 'reinitialize must RegisterDragDrop desktop_drop target again');
  });

  group('BUOxDR9WIJ verifyAndRepair: re-register only when really lost', () {
    Map<String, Object> status({
      bool registered = true,
      bool ours = true,
      bool elevated = false,
    }) => <String, Object>{
      'registered': registered,
      'ours': ours,
      'lastRegisterResult': 0,
      'registerCount': 1,
      'elevated': elevated,
    };

    List<String> dropDiagnostics() => <String>[
      for (final ErrorLogEntry e in ErrorLogService.instance.diagnosticEntries)
        if (e.source == 'DesktopDrop') e.error,
    ];

    test('healthy registration: no reinitialize, nothing logged', () async {
      final int logsBefore = dropDiagnostics().length;
      final List<String> calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call.method);
        return call.method == 'status' ? status() : null;
      });

      await DesktopDropReinitializer.verifyAndRepairOnChannel('test');

      expect(calls, <String>[
        'status',
      ], reason: 'an intact registration must not be torn down and redone');
      expect(dropDiagnostics().length, logsBefore);
    });

    test(
      'lost / replaced registration: reinitialize and log before/after',
      () async {
        final List<String> calls = <String>[];
        bool repaired = false;
        messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          if (call.method == 'reinitialize') repaired = true;
          return call.method == 'status' ? status(ours: repaired) : null;
        });

        await DesktopDropReinitializer.verifyAndRepairOnChannel('route pop: X');

        expect(calls, <String>['status', 'reinitialize', 'status']);
        expect(
          dropDiagnostics().last,
          allOf(
            contains('route pop: X'),
            contains('ours=false'),
            contains('after: registered=true ours=true'),
          ),
        );
      },
    );

    test('elevated process is reported (UIPI blocks Explorer drags)', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        return call.method == 'status' ? status(elevated: true) : null;
      });

      await DesktopDropReinitializer.verifyAndRepairOnChannel('startup');

      expect(dropDiagnostics().last, contains('process is elevated'));
    });

    test('unpatched plugin (no status): silent no-op', () async {
      messenger.setMockMethodCallHandler(channel, null);
      await DesktopDropReinitializer.verifyAndRepairOnChannel('test');
    });

    test('native fork services the status method', () {
      final File src = <String>[
        '../third_party/desktop_drop/windows/desktop_drop_plugin.cpp',
        'third_party/desktop_drop/windows/desktop_drop_plugin.cpp',
      ].map(File.new).firstWhere((File f) => f.existsSync());
      expect(
        RegExp(
          r'method_name\(\)\s*==\s*"status"',
        ).hasMatch(src.readAsStringSync()),
        isTrue,
      );
    });
  });

  test('DesktopDropRouteObserver is wired into the root navigator', () {
    final String main = File('lib/main.dart').readAsStringSync();
    expect(
      main,
      contains('desktopDropRouteObserver'),
      reason:
          'video / web video pages never pass AppModel.closeMedia; the '
          'route observer is what sees every native-surface page leave',
    );
    expect(desktopDropRouteObserver, isA<NavigatorObserver>());
  });
}

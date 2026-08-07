import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/desktop_drop_reinitializer.dart';

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
}

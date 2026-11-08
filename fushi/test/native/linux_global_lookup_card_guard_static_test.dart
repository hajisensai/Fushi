// Source guard for the Linux (X11) app-external global lookup card: the
// fushi_lookup_card helper (linux/lookup_card/) and the runner that forwards
// the channel to it (linux/runner/global_lookup_channel.cc). Linux native code
// is not built on the Windows CI runner, so like the macOS guard this scans the
// sources: the channel contract shared with lib/src/lookup/
// overlay_window_channel.dart, the JS entry points the host expects, the bridge
// lock, the never-focus window and the build wiring stay in place.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/linux_lookup_card.dart';
import 'package:path/path.dart' as p;

void main() {
  String read(String relativeToFushi) {
    final File file = File(relativeToFushi);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  late String card;
  late String helperMain;
  late String runner;
  late String dartChannel;
  setUpAll(() {
    card = read('linux/lookup_card/card_overlay.cc');
    helperMain = read('linux/lookup_card/main.cc');
    runner = read('linux/runner/global_lookup_channel.cc');
    dartChannel = read('lib/src/lookup/overlay_window_channel.dart');
  });

  group('Linux lookup card helper (card_overlay.cc)', () {
    test('handles every forward method the Dart channel invokes', () {
      // An unhandled method replies notImplemented and silently breaks that
      // step of the lookup pipeline on Linux.
      final RegExp invoke = RegExp(r"_invoke<[^>]+>\(\s*'([a-zA-Z]+)'");
      final Set<String> methods = invoke
          .allMatches(dartChannel)
          .map((RegExpMatch m) => m.group(1)!)
          .toSet();
      expect(methods, containsAll(<String>['showAt', 'revealStack']));
      for (final String method in methods) {
        expect(
          card,
          contains('method == "$method"'),
          reason: 'Linux card must handle "$method"',
        );
      }
    });

    test('emits every reverse call the Dart channel handles', () {
      for (final String reverse in <String>[
        'jsMessage',
        'overlayHidden',
        'nativeError',
        'globalMouseTrigger',
      ]) {
        expect(dartChannel, contains("case '$reverse'"));
        expect(card, contains('emit_("$reverse"'));
      }
      // getMedia needs an answer, so main.cc pairs it with a reply id.
      expect(dartChannel, contains("case 'getMedia'"));
      expect(helperMain, contains('"getMedia"'));
      expect(runner, contains('"mediaReply"'));
      // jsMessage / overlayHidden carry the routed envelope.
      expect(card, contains('"routeEpoch", route.route_epoch'));
      expect(card, contains('"payload"'));
    });

    test('calls the same host / adapter JS entry points as Windows', () {
      for (final String entry in <String>[
        'window.__globalLookupHost.commitLayerShift(',
        'resetLayerOffsetForLegacyReveal',
        'window.__globalLookupHost.handleGlobalClick(',
        'window.__globalLookupHost.gamepadAction(',
        'window.__globalLookupHost.endLiveResize();',
        'window.__fushiBridgeResolve(',
      ]) {
        expect(card, contains(entry), reason: 'missing JS entry $entry');
      }
      // Spliced into JS, so the gamepad action whitelist is pinned.
      expect(card, contains('allowed = {"next", "prev", "mine",'));
      expect(card, contains('"audio", "scroll"};'));
    });

    test('bridges chrome.webview.postMessage and injects adapter + host', () {
      expect(card, contains('window.chrome.webview = {'));
      expect(card, contains('window.webkit.messageHandlers.fushiOverlay'));
      expect(card, contains('WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES'));
      expect(card, contains('WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START'));
      expect(
        card,
        contains('{"popup_bridge_adapter.js", "global_lookup_host.js"}'),
      );
      expect(card, contains('"global_lookup_host.html"'));
    });

    test('answers the host bridge lock and enforces it before forwarding', () {
      expect(card, contains('kBridgeLockHandler[] = "_fushiLockBridge"'));
      expect(card, contains('kBridgeTokenField[] = "__fushiBridgeToken"'));
      final int body = card.indexOf(
        'void CardOverlay::HandleScriptMessage(std::string body) {',
      );
      expect(body, greaterThan(0));
      final String handler = card.substring(body);
      final int lock = handler.indexOf('handler == kBridgeLockHandler');
      final int auth = handler.indexOf('AuthorizeLockedBridgeMessage(');
      final int forward = handler.indexOf('emit_("jsMessage"');
      expect(lock, greaterThan(0));
      expect(auth, greaterThan(lock));
      expect(forward, greaterThan(auth));
      // Token from the kernel CSPRNG, compared in constant time, handed back
      // only to the host closure, cleared on every top-level commit.
      expect(card, contains('getrandom('));
      expect(card, contains('BridgeTokensEqual('));
      expect(card, contains('window.__fushiBridgeLockResult('));
      expect(
        card,
        contains(
          'if (event == WEBKIT_LOAD_COMMITTED) {\n'
          '    // A new top-level document starts unlocked',
        ),
      );
    });

    test('deferred bridge handlers match the Windows router', () {
      final String cpp = read('windows/runner/global_lookup_window.cpp');
      final RegExp quoted = RegExp(r'"([a-zA-Z]+)"');
      final int start = card.indexOf('DeferredHandlers() {');
      final int end = card.indexOf('};', start);
      final Set<String> linux = quoted
          .allMatches(card.substring(start, end))
          .map((RegExpMatch m) => m.group(1)!)
          .toSet();
      expect(linux, hasLength(greaterThan(10)));
      for (final String handler in linux) {
        expect(
          cpp,
          contains('"\\"$handler\\""'),
          reason: 'Linux defers $handler but Windows does not',
        );
      }
    });

    test('serves the assets folder and Dart media through custom schemes', () {
      expect(card, contains('kPopupAssetScheme[] = "fushi-popup"'));
      expect(card, contains('context, "image", OnMediaRequest'));
      expect(card, contains('context, "dictmedia", OnMediaRequest'));
      // Page-controlled URL: never serve outside the assets folder.
      expect(card, contains('realpath((assets_root_ + "/" + relative)'));
      expect(card, contains('g_ascii_strcasecmp(scheme.c_str(), "dictmedia")'));
    });

    test(
      'never takes focus; dismisses on outside clicks and window switch',
      () {
        expect(card, contains('gtk_window_new(GTK_WINDOW_POPUP)'));
        expect(card, contains('gtk_window_set_accept_focus(window, FALSE)'));
        // Observe-only raw presses, selected only while needed.
        expect(card, contains('XISetMask(mask.data(), XI_RawButtonPress)'));
        expect(
          card,
          contains('dismiss_armed_ || mouse_trigger_x_button_ != 0'),
        );
        expect(card, contains('"_NET_ACTIVE_WINDOW"'));
        expect(card, contains('void CardOverlay::ArmDismissMonitors()'));
        expect(card, contains('DisarmDismissMonitors();'));
      },
    );

    test('showAt reply carries the physical-px work area + monitor dpr', () {
      for (final String key in <String>[
        '"ok"',
        '"workW"',
        '"workH"',
        '"cursorWorkX"',
        '"cursorWorkY"',
        '"monitorDpr"',
      ]) {
        expect(card, contains(key));
      }
      expect(card, contains('gdk_monitor_get_workarea'));
      expect(card, contains('gdk_monitor_get_scale_factor'));
    });
  });

  group('Linux runner (global_lookup_channel.cc)', () {
    test('forwards the shared channel to the helper Dart looks for', () {
      expect(runner, contains('"app.fushi.reader/global_lookup"'));
      expect(runner, contains('kHelperName[] = "$kLinuxLookupCardHelper"'));
      expect(
        read('linux/lookup_card/CMakeLists.txt'),
        contains('add_executable($kLinuxLookupCardHelper'),
      );
      final String cmake = read('linux/CMakeLists.txt');
      expect(cmake, contains('add_subdirectory("lookup_card")'));
      expect(
        cmake,
        contains(
          'install(TARGETS $kLinuxLookupCardHelper RUNTIME DESTINATION '
          '"\${CMAKE_INSTALL_PREFIX}"',
        ),
      );
      expect(
        read('linux/runner/my_application.cc'),
        contains('fushi_global_lookup_new(messenger)'),
      );
    });

    test('replays the state a restarted helper needs, prepare first', () {
      expect(
        runner,
        contains('kStickyMethods[] = {"prepare", "setBlockCapture",'),
      );
      expect(runner, contains('"setGlobalMouseTrigger"};'));
    });

    test('selection lookup reads PRIMARY and never touches the clipboard', () {
      expect(runner, contains('"app.fushi.reader/foreground_selection"'));
      expect(runner, contains('"captureSelection"'));
      expect(runner, contains('gtk_clipboard_get(GDK_SELECTION_PRIMARY)'));
      expect(runner, isNot(contains('GDK_SELECTION_CLIPBOARD')));
    });

    // Fushi draws on XWayland, and KWin copies a Wayland app's selection into
    // X11 only while an X11 window has focus; the floating ball never takes
    // focus. So the compositor's primary selection (data control) comes first.
    test('Wayland primary selection first, X11 PRIMARY as the fallback', () {
      final String reader = read('linux/runner/wayland_selection.cc');
      expect(reader, contains('ext_data_control_manager_v1_get_data_device('));
      expect(reader, contains('session->primary = offer;'));
      expect(reader, isNot(contains('OnSelection(void* data')));
      final int wayland = runner.indexOf('ReadWaylandPrimarySelection(');
      final int fallback = runner.indexOf('CaptureGtkPrimary(call);', wayland);
      expect(wayland, greaterThan(0));
      expect(fallback, greaterThan(wayland));
      expect(
        read('linux/runner/CMakeLists.txt'),
        contains('staging/ext-data-control/ext-data-control-v1.xml'),
      );
      final String manifest = read(
        '../tool/linux/flatpak/app.fushi.reader.yml',
      );
      expect(manifest, contains('- --socket=wayland'));
      expect(manifest, contains('- --env=GDK_BACKEND=x11'));
    });

    // GNOME has no data control, and on a native Wayland display the
    // compositor offers the primary selection only to the focused client: the
    // GTK read waits for a Fushi window to become active, syncs once so the
    // offer has arrived, and is bounded. The no-overlay hotkey path raises
    // the main window before it captures, or the wait could never end early.
    test('native Wayland: read the primary selection once Fushi has focus', () {
      final int body = runner.indexOf('void CaptureGtkPrimary(');
      expect(body, greaterThan(0));
      expect(
        runner.indexOf('GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default())'),
        greaterThan(body),
      );
      expect(runner, contains('"notify::is-active"'));
      expect(runner, contains('g_timeout_add(kFocusWaitMs'));
      final int sync = runner.indexOf('gdk_display_sync(');
      expect(sync, greaterThan(0));
      expect(runner.indexOf('ReadGtkPrimary(wait->call);'), greaterThan(sync));

      final String controller = read(
        'lib/src/lookup/global_lookup_controller.dart',
      );
      final int start = controller.indexOf(
        'Future<void> _lookupSelectionInMainWindow(',
      );
      final int raise = controller.indexOf('bringMainWindowToFront()', start);
      final int capture = controller.indexOf(
        'captureForegroundSelection()',
        start,
      );
      expect(start, greaterThan(0));
      expect(raise, greaterThan(start));
      expect(capture, greaterThan(raise));
    });
  });

  group('linuxLookupCardAvailable', () {
    bool available(Map<String, String> env, {bool helper = true}) =>
        linuxLookupCardAvailable(
          environment: env,
          resolvedExecutable: '/app/fushi/fushi',
          context: p.posix,
          fileExists: (String path) =>
              helper && path == '/app/fushi/$kLinuxLookupCardHelper',
        );

    test('X11 session with the helper next to the executable', () {
      expect(available(<String, String>{'DISPLAY': ':0'}), isTrue);
      expect(
        available(<String, String>{
          'DISPLAY': ':0',
          'WAYLAND_DISPLAY': 'wayland-0',
          'GDK_BACKEND': 'x11',
        }),
        isTrue,
      );
    });

    test('no card on Wayland or when the helper was not built', () {
      expect(
        available(<String, String>{
          'DISPLAY': ':0',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        isFalse,
      );
      expect(
        available(<String, String>{'DISPLAY': ':0'}, helper: false),
        isFalse,
      );
    });
  });
}

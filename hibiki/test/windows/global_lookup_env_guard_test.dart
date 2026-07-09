import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for TODO-1153 / BUG-549
/// (Windows 应用外查词没弹窗：覆盖窗 WebView2 env 静默创建失败).
///
/// Root cause: the app-external global-lookup overlay creates its own WebView2
/// environment that registers the image:// + dictmedia:// custom schemes, but
/// used the DEFAULT process user data folder (userDataFolder == nullptr). That
/// is the SAME folder the in-app fork WebView2 environments use, and WebView2
/// forbids two environments sharing one user data folder with DIFFERENT
/// CreateOptions -> the overlay env create failed with 0x8007139F. Both create
/// callbacks silently swallowed the failure (env callback ignored the HRESULT;
/// controller callback returned S_OK on a null controller) and the synchronous
/// HRESULT was discarded, so the overlay never navigated, webview_ready_ stayed
/// false, and the reveal showed a blank transparent window.
///
/// The fix is native (cannot run on the Dart host), so these guards pin the
/// load-bearing wiring: a dedicated user data folder + non-swallowing error
/// handling on every create step. A refactor that drops any of it would
/// re-introduce the silent "no popup".
void main() {
  late String cpp;
  late String dartChannel;

  setUpAll(() {
    cpp = File('windows/runner/global_lookup_window.cpp').readAsStringSync();
    dartChannel =
        File('lib/src/lookup/global_lookup_channel.dart').readAsStringSync();
  });

  group('TODO-1153 direction 1: overlay env uses a dedicated user data folder',
      () {
    test('a dedicated overlay user data folder helper exists', () {
      expect(cpp.contains('OverlayUserDataFolder('), isTrue,
          reason: 'overlay must resolve its own WebView2 user data folder.');
    });

    test('the env create no longer passes nullptr for the user data folder',
        () {
      // The exact silent-conflict form: (nullptr, nullptr, options...). The
      // second nullptr is the user data folder that collided with the in-app
      // environments. Any whitespace/newline between the two nullptrs still
      // counts as the bug.
      final RegExp bare = RegExp(
          r'CreateCoreWebView2EnvironmentWithOptions\(\s*nullptr\s*,\s*nullptr\s*,');
      expect(bare.hasMatch(cpp), isFalse,
          reason: 'the overlay env must NOT share the default user data '
              'folder (options conflict 0x8007139F).');
    });

    test('the env create consumes the dedicated folder', () {
      final int create =
          cpp.indexOf('CreateCoreWebView2EnvironmentWithOptions(');
      expect(create, isNonNegative);
      // The overlay folder string must be computed before and fed into the call.
      expect(cpp.contains('overlay_folder = OverlayUserDataFolder()'), isTrue);
      final int usage = cpp.indexOf('overlay_folder.empty() ? nullptr', create);
      expect(usage, greaterThan(create),
          reason: 'CreateCoreWebView2EnvironmentWithOptions must consume the '
              'dedicated overlay_folder.');
    });
  });

  group('TODO-1153 direction 2: create failures are never swallowed', () {
    test('a single non-swallowing failure sink exists', () {
      expect(
          cpp.contains('void GlobalLookupWindow::ReportOverlayError('), isTrue,
          reason: 'a failure reporter must exist.');
      // It writes the native diagnostic log AND routes to the Dart error cb.
      expect(cpp.contains('NativeGlog(full)'), isTrue);
      expect(cpp.contains('error_cb_(full)'), isTrue);
    });

    test('the synchronous env-create HRESULT is captured and checked', () {
      expect(cpp.contains('HRESULT create_hr ='), isTrue,
          reason: 'the synchronous HRESULT (0x8007139F on conflict) must be '
              'captured, not discarded.');
      expect(cpp.contains('if (FAILED(create_hr))'), isTrue);
    });

    test('the env completion callback checks its HRESULT / null env', () {
      expect(cpp.contains('FAILED(env_hr) || env == nullptr'), isTrue,
          reason: 'a failed environment create must be reported, not '
              'dereferenced/ignored.');
    });

    test('the controller callback no longer returns S_OK silently on null', () {
      expect(cpp.contains('FAILED(ctrl_hr) || ctrl == nullptr'), isTrue,
          reason: 'a null controller must be reported before returning.');
      // The old bare early-return without logging must be gone.
      final RegExp bareReturn =
          RegExp(r'if \(ctrl == nullptr\) \{\s*return S_OK;\s*\}');
      expect(bareReturn.hasMatch(cpp), isFalse,
          reason: 'the silent ctrl==nullptr early return must be replaced by a '
              'reported one.');
    });

    test('Dart surfaces native overlay errors via ErrorLogService', () {
      expect(dartChannel.contains("case 'nativeError':"), isTrue,
          reason: 'the channel must handle the native error report.');
      expect(dartChannel.contains('ErrorLogService.instance.log('), isTrue,
          reason: 'native overlay bring-up errors must reach ErrorLogService '
              '(user-visible), mirroring the TODO-1086 hotkey visibility fix.');
    });
  });
}

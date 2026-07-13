import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-518 / TODO-1086 — source-scan guards for the app-OUTSIDE global lookup
/// hotkey (Ctrl+Alt+D) reliability on Windows.
///
/// Two independent structural defects made "global lookup does not fire outside
/// the app" possible; these guards lock each fix so a later refactor cannot
/// silently reintroduce them:
///
///   1. [DesktopLookupService.stop] used to call the PROCESS-GLOBAL
///      `hotKeyManager.unregisterAll()`, which nukes EVERY registered system
///      hotkey — including [GlobalLookupController]'s Ctrl+Alt+D — whenever the
///      old clipboard/Ctrl+Shift+D service was stopped/restarted. It must only
///      unregister its OWN hotkey (per-hotkey `unregister`).
///
///   2. [GlobalLookupController] used to swallow a failed hotkey `register()`
///      into the temp-file-only `glog`, so a registration failure (key already
///      taken by another app / init-order race) was invisible to the user and
///      the uploadable error log. It must also route the failure through
///      [ErrorLogService] (the user-visible + uploadable diagnostic channel).
///
///   3. The hotkey_manager plugin init contract requires ONE `unregisterAll()`
///      on startup before `register()` is reliable. That init call in main.dart
///      must live on the UNCONDITIONAL desktop path — NOT inside the
///      `restartMarkerArg` branch (which only runs on the migration-restart
///      process), or a normal cold start would never satisfy the contract and
///      the overlay hotkey register could silently fail.
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('desktop_lookup_service.stop() is per-hotkey, not global', () {
    late String source;
    late String stopBody;
    setUpAll(() {
      source = read('lib/src/sync/desktop_lookup_service.dart');
      final int at = source.indexOf('Future<void> stop() async {');
      expect(at, greaterThan(-1), reason: 'stop() must exist');
      // Body from stop() up to the next method (configureWindowMode).
      final int end = source.indexOf('Future<void> configureWindowMode(', at);
      expect(end, greaterThan(at));
      // Strip // line comments: the fix's Chinese doc comment legitimately
      // MENTIONS unregisterAll() to explain why it was removed; the CODE must
      // not call it.
      stopBody = _stripLineComments(source.substring(at, end));
    });

    test('stop() does NOT call global hotKeyManager.unregisterAll()', () {
      expect(stopBody.contains('hotKeyManager.unregisterAll('), isFalse,
          reason: 'global unregisterAll() in stop() nukes OTHER services\' '
              'system hotkeys (incl. GlobalLookupController Ctrl+Alt+D). It must '
              'only unregister its own hotkey.');
    });

    test('stop() unregisters only its own hotkey (per-hotkey)', () {
      expect(stopBody.contains('hotKeyManager.unregister('), isTrue,
          reason: 'stop() must call per-hotkey unregister on the hotkey it '
              'holds (_hotKey), not the process-global unregisterAll');
    });
  });

  group('global lookup hotkey register failure is visible', () {
    late String controller;
    setUpAll(() =>
        controller = read('lib/src/lookup/global_lookup_controller.dart'));

    test('a failed register() is logged to ErrorLogService (not glog-only)',
        () {
      // Locate the registration helper and confirm its catch reaches the
      // user-visible / uploadable ErrorLogService channel.
      final int at =
          controller.indexOf('Future<void> _registerHotKeyFromRegistry(');
      expect(at, greaterThan(-1),
          reason: '_registerHotKeyFromRegistry must exist');
      final String fn = controller.substring(at);
      expect(fn.contains('ErrorLogService.instance.log('), isTrue,
          reason: 'a failed hotkey register must surface through the visible '
              'ErrorLogService, not be swallowed into the temp-file glog only');
    });

    test('controller imports ErrorLogService', () {
      expect(
          controller.contains(
              "import 'package:hibiki/src/utils/misc/error_log_service.dart';"),
          isTrue,
          reason: 'the visibility fix depends on the ErrorLogService import');
    });
  });

  group('hotkey_manager init unregisterAll is on the unconditional path', () {
    late String main;
    setUpAll(() => main = read('lib/main.dart'));

    test('main.dart calls hotKeyManager.unregisterAll() on startup', () {
      expect(main.contains('hotKeyManager.unregisterAll('), isTrue,
          reason:
              'the plugin init contract needs one unregisterAll() on start');
    });

    test(
        'the init unregisterAll() is NOT nested in the restartMarkerArg branch',
        () {
      // Extract the restartMarkerArg `if` block and assert the init call lives
      // AFTER it (unconditional desktop path), not inside it. If it were inside,
      // a normal cold start would skip the plugin init and register() could fail
      // silently.
      final int ifAt = main.indexOf(
          'if (args.contains(DesktopLifecycleService.restartMarkerArg))');
      expect(ifAt, greaterThan(-1),
          reason: 'the restart-marker branch must exist');
      // Walk braces from the first `{` after the if to find the branch end.
      final int openBrace = main.indexOf('{', ifAt);
      expect(openBrace, greaterThan(-1));
      int depth = 0;
      int closeBrace = -1;
      for (int i = openBrace; i < main.length; i++) {
        final String ch = main[i];
        if (ch == '{') depth++;
        if (ch == '}') {
          depth--;
          if (depth == 0) {
            closeBrace = i;
            break;
          }
        }
      }
      expect(closeBrace, greaterThan(openBrace),
          reason: 'restart-marker branch must be brace-balanced');
      final String branchBody = main.substring(openBrace, closeBrace + 1);
      expect(branchBody.contains('hotKeyManager.unregisterAll('), isFalse,
          reason: 'the hotkey_manager init unregisterAll() must NOT be nested '
              'inside the restartMarkerArg branch — a normal cold start would '
              'then skip plugin init and the overlay hotkey register could fail');

      // And it must appear somewhere AFTER the branch closes (unconditional
      // desktop path), still on desktop.
      final int initAt =
          main.indexOf('hotKeyManager.unregisterAll(', closeBrace);
      expect(initAt, greaterThan(closeBrace),
          reason: 'the init unregisterAll() must run on the unconditional '
              'desktop path after the restart-marker branch');
    });
  });

  // 用户 2026-07-12 — 整句横幅（框）只给「剪切板自动唤出的瞬态窗」显示；手动
  // 快捷键查词不显示（整句仍进制卡 sentence，与横幅解耦）。
  group('整句横幅只给剪切板自动唤出的瞬态窗', () {
    late String controllerSrc;
    late String dispatcherSrc;
    setUpAll(() {
      controllerSrc = read('lib/src/lookup/global_lookup_controller.dart');
      dispatcherSrc = read('lib/src/lookup/desktop_lookup_dispatcher.dart');
    });

    test('手动快捷键窗不贴横幅：hotkey 的 _lookupExternal 传 showSentenceBanner:false', () {
      final int at = controllerSrc.indexOf('hotkey: empty selection');
      expect(at, greaterThan(-1), reason: 'hotkey 分支必须存在');
      final String tail = controllerSrc.substring(at);
      final int callAt = tail.indexOf('_lookupExternal(text,');
      expect(callAt, greaterThan(-1), reason: 'hotkey 必须走 _lookupExternal');
      final String call = tail.substring(callAt, tail.indexOf(';', callAt));
      expect(call.contains('showSentenceBanner: false'), isTrue,
          reason: '手动快捷键查词不显示整句横幅（框）');
    });

    test('横幅注入门控在 _showSentenceBanner（与 mining 解耦）', () {
      expect(
        controllerSrc.contains('(isRoot && _showSentenceBanner)'),
        isTrue,
        reason: 'root 卡横幅必须同时满足 isRoot 且 _showSentenceBanner',
      );
    });

    test('制卡 sentenceContext 仍用完整 _currentSentence（横幅关掉也不空）', () {
      expect(
          controllerSrc.contains('sentenceContext: _currentSentence'), isTrue,
          reason: 'BUG-730：热键窗整句仍进制卡 {sentence}，与横幅解耦不受影响');
    });

    test('剪切板自动唤出（dispatcher transient）保留横幅：不关 banner', () {
      final int at = dispatcherSrc.indexOf('DesktopLookupConsumer.transient');
      expect(at, greaterThan(-1));
      final String tail = dispatcherSrc.substring(at);
      final int callAt = tail.indexOf('.lookupText(');
      expect(callAt, greaterThan(-1));
      final String call =
          tail.substring(callAt, tail.indexOf(');', callAt) + 1);
      expect(call.contains('showSentenceBanner: false'), isFalse,
          reason: '剪切板自动唤出的瞬态窗必须显示整句框（默认 true 不关）');
    });
  });
}

/// Removes `//` line comments so a source-scan assertion inspects CODE only
/// (doc comments may legitimately mention a forbidden call to explain its
/// removal).
String _stripLineComments(String source) {
  final StringBuffer out = StringBuffer();
  for (final String line in const LineSplitter().convert(source)) {
    final int c = line.indexOf('//');
    out.writeln(c >= 0 ? line.substring(0, c) : line);
  }
  return out.toString();
}

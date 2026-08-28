import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-518 / TODO-1086 — source-scan guards for the app-OUTSIDE global lookup
/// hotkey (Ctrl+Alt+D) reliability on Windows.
///
/// Independent structural defects made "global lookup does not fire outside
/// the app" possible; these guards lock each fix so a later refactor cannot
/// silently reintroduce them:
///
///   1. (Retired) [DesktopLookupService.stop] used to call the PROCESS-GLOBAL
///      `hotKeyManager.unregisterAll()`, nuking Ctrl+Alt+D whenever the old
///      clipboard/Ctrl+Shift+D service restarted. That service — and its hotkey
///      — was deleted with desktop clipboard lookup, so the guard is gone too.
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
              "import 'package:fushi/src/utils/misc/error_log_service.dart';"),
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

  // 整句横幅（弹窗顶部的灰底句子框）已随桌面剪贴板查词一并移除：popup.js 不再
  // 渲染 .global-lookup-sentence，渲染链也不再有 showSentenceBanner 开关。整句
  // 只进制卡 {sentence} 上下文（sentenceContext），这条链必须保留。
  group('整句横幅已移除，整句只进制卡上下文', () {
    late String controllerSrc;
    late String renderSrc;
    late String popupJs;
    late String galOverlaySrc;
    setUpAll(() {
      controllerSrc = read('lib/src/lookup/global_lookup_controller.dart');
      renderSrc = read('lib/src/lookup/global_lookup_render.dart');
      popupJs = read('assets/popup/popup.js');
      galOverlaySrc =
          read('lib/src/lookup/gal_hook_text_overlay_controller.dart');
    });

    test('showSentenceBanner 开关不再存在（controller / 渲染链 / popup.js）', () {
      expect(controllerSrc.contains('showSentenceBanner'), isFalse,
          reason: '横幅已删，controller 不得再保留 showSentenceBanner 参数');
      expect(controllerSrc.contains('_showSentenceBanner'), isFalse);
      expect(renderSrc.contains('__globalLookupSentence'), isFalse,
          reason: '渲染脚本不得再向 popup.js 注入句子横幅文本');
      expect(popupJs.contains('buildGlobalLookupSentenceBanner'), isFalse);
      expect(popupJs.contains('prependSentenceBanner'), isFalse);
      expect(popupJs.contains('__globalLookupSentence'), isFalse);
    });

    test('制卡 sentenceContext 仍用完整 _currentSentence（横幅删掉也不空）', () {
      expect(
          controllerSrc.contains('sentenceContext: _currentSentence'), isTrue,
          reason: 'BUG-730：热键窗整句仍进制卡 {sentence}，与横幅无关');
    });

    test('游戏台词浮窗点词保留完整句子供制卡', () {
      final int handlerAt =
          galOverlaySrc.indexOf('Future<void> _onLookupText(');
      expect(handlerAt, greaterThan(-1), reason: '游戏台词浮窗查词入口必须存在');
      final int callAt = galOverlaySrc.indexOf(
        'GlobalLookupController.instance.lookupText(',
        handlerAt,
      );
      expect(callAt, greaterThan(handlerAt));
      final int callEnd = galOverlaySrc.indexOf(');', callAt);
      expect(callEnd, greaterThan(callAt));
      final String call = galOverlaySrc.substring(callAt, callEnd + 2);
      expect(call.contains('showSentenceBanner'), isFalse,
          reason: '横幅开关已删，调用点不得再传 showSentenceBanner');
      expect(call.contains('sentence: entry.text'), isTrue,
          reason: '制卡需要的完整句子上下文必须继续传入');
    });
  });
}

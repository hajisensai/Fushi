import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../helpers/scan_scale.dart';

/// 剥除 Dart 源码里的注释，只保留真实代码，避免静态守卫把文档注释（`///`）/行注释
/// （`//`）/块注释（`/* */`）里出现的示例文字（如反引号包裹的 `windowManager.show()`）
/// 误判为真实调用（TODO-972：CI 静态守卫误报）。
///
/// 实现委托给共享词法掩码 [maskComments]（TODO-2477）：原先这里手写了一份字符级
/// 状态机，行为与共享版一致但各自维护——本仓已因「每个守卫各写一份剥离逻辑」
/// 反复出过假绿。共享版额外保证**等长掩码**（注释换成等量空白而非删除），
/// 下标可直接回原串切片。
String stripDartComments(String src) => maskComments(src);

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('stripDartComments removes comments but keeps real code', () {
    // 文档注释里的示例文字不应被守卫抓到。
    expect(
      stripDartComments('/// 见 `windowManager.show()`\n'),
      isNot(contains('windowManager.show()')),
    );
    // 行内注释剥除，但前面的真实代码保留。
    expect(
      stripDartComments('windowManager.show(); // 抢前台'),
      contains('windowManager.show('),
    );
    // 块注释剥除。
    expect(
      stripDartComments('/* windowManager.focus() */ var x = 1;'),
      isNot(contains('windowManager.focus()')),
    );
    // 字符串字面量里的 // 不算注释，整串保留。
    expect(
      stripDartComments("final url = 'http://a/b'; // c"),
      contains("'http://a/b'"),
    );
    // 反例守卫：真实调用（非注释、非字符串）必须仍被保留，防止误删导致守卫失效。
    final String stripped = stripDartComments(
      'class Foo {\n'
      '  void bar() {\n'
      '    windowManager.show();\n'
      '  }\n'
      '}\n',
    );
    final RegExp foregroundCall = RegExp(r'windowManager\.(show|focus)\s*\(');
    expect(foregroundCall.hasMatch(stripped), isTrue,
        reason: 'stripDartComments must not swallow real windowManager calls.');
  });

  test('only DesktopLookupService may call windowManager show/focus directly',
      () {
    final RegExp foregroundCall = RegExp(r'windowManager\.(show|focus)\s*\(');
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final File entity
        in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      scanned++;
      final String normalized = entity.path.replaceAll('\\', '/');
      // 先剥除注释，只对真实代码跑守卫正则——文档/行/块注释里的示例文字不算违规。
      final String source = stripDartComments(entity.readAsStringSync());
      if (!foregroundCall.hasMatch(source)) continue;
      if (!normalized.endsWith('sync/desktop_lookup_service.dart')) {
        offenders.add(normalized);
      }
    }

    expectScanScale(scanned,
        what: 'lib/src 下的 .dart', atLeast: 750, measured: 930);

    expect(
      offenders,
      isEmpty,
      reason:
          'Windows foreground/taskbar attention must stay behind DesktopLookupService.',
    );
  });

  test('DesktopLookupService uses Windows foreground guard before show/focus',
      () {
    final String service = read('lib/src/sync/desktop_lookup_service.dart');
    final int bringStart = service.indexOf(
      'Future<void> bringPendingLookupToFront()',
    );
    final int focusHelperStart =
        service.indexOf('Future<bool> _isFushiForeground()');
    expect(bringStart, isNonNegative);
    expect(focusHelperStart, isNonNegative);
    final String bringBody = service.substring(bringStart, focusHelperStart);

    expect(bringBody.contains('DesktopForegroundGuard.isHiddenWindowsRunner'),
        isTrue);
    expect(bringBody.contains('await _isFushiForeground()'), isTrue);
    expect(
      bringBody.indexOf('await _isFushiForeground()') <
          bringBody.indexOf('windowManager.show()'),
      isTrue,
      reason: 'Foreground guard must run before show/focus.',
    );
    expect(service.contains('isForegroundOwnedByCurrentProcess()'), isTrue);
    expect(service.contains('isForegroundOwnedByFushiAppFamily()'), isTrue,
        reason: 'Foreground guard must also treat Hibiki popup/app-family '
            'windows as internal copies.');
  });

  test('hidden Windows runner is toolwindow/noactivate and off-screen', () {
    final String runner = read('windows/runner/win32_window.cpp');
    expect(runner.contains('FUSHI_TEST_HIDDEN'), isTrue);
    expect(runner.contains('WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE'), isTrue);
    expect(runner.contains('kOffscreenOrigin'), isTrue);
    expect(
      runner.contains('WS_OVERLAPPEDWINDOW | WS_VISIBLE'),
      isTrue,
      reason: 'Hidden runner must keep rendering while parked off-screen.',
    );
  });

  test('main window does not reclaim focus when a lookup popup activates', () {
    final String runner = read('windows/runner/win32_window.cpp');
    final String handler = methodBody(
      runner,
      'Win32Window::MessageHandler(',
    );
    final String activateCase = maskCommentsAndStrings(
      switchCaseBody(
        handler,
        'case WM_ACTIVATE:',
        nextLabels: const <String>['case WM_DISPLAYCHANGE:'],
      ),
    );

    expect(
      activateCase.contains('ShouldRestoreChildFocus('),
      isTrue,
      reason: 'The lookup panel drag/resize activates an auxiliary Hibiki '
          'window. The main window must ignore its WA_INACTIVE notification '
          'instead of reclaiming focus and jumping to the foreground.',
    );
    expect(
      'SetFocus(child_content_);'.allMatches(activateCase).length,
      1,
      reason: 'Keep main-window focus restoration behind the activation guard.',
    );
    expect(activateCase.contains('IsWindow(child_content_)'), isTrue,
        reason: 'A destroyed Flutter child HWND must not receive focus.');
    expect(
      activateCase.contains('GetParent(child_content_) == hwnd'),
      isTrue,
      reason: 'HWND values are recycled; the live child must still belong to '
          'this exact main window.',
    );

    final String destroyBody = maskCommentsAndStrings(
      methodBody(runner, 'void Win32Window::Destroy()'),
    );
    expect(
      destroyBody.contains('child_content_ = nullptr;'),
      isTrue,
      reason: 'Destroy must clear the borrowed Flutter child handle before '
          'subclass/controller teardown can dispatch reentrant messages.',
    );
  });

  test(
      'floating lyric window stays noactivate/shownoactivate; only the '
      'clipboard text window opts into the taskbar', () {
    final String cpp = read('windows/runner/floating_lyric_window.cpp');
    final int createWindow = cpp.indexOf('CreateWindowExW(');
    final int showWindow = cpp.indexOf('ShowWindow(hwnd_,', createWindow);
    expect(createWindow, isNonNegative);
    expect(showWindow, isNonNegative);
    final String createBlock = cpp.substring(createWindow, showWindow);

    // Foreground-safety invariant (the real point of this guard): the window
    // must never steal activation, whether or not it shows in the taskbar.
    expect(createBlock.contains('WS_EX_NOACTIVATE'), isTrue);
    expect(cpp.contains('ShowWindow(hwnd_, SW_SHOWNOACTIVATE)'), isTrue);

    // Taskbar contract: only the transparent clipboard text window
    // (`text_only_ && !hook_text_mode_`) enters the taskbar / Alt-Tab via
    // WS_EX_APPWINDOW so the user can find/raise the otherwise-invisible overlay;
    // the audiobook lyric strip and the galgame hook window keep
    // WS_EX_TOOLWINDOW (off the taskbar). The branch lives in `taskbar_ex`, and
    // CreateWindowExW must consume it rather than hard-coding an ex-style.
    expect(
      cpp.contains('(text_only_ && !hook_text_mode_) '
          '? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW'),
      isTrue,
      reason: 'lyric strip / hook window keep TOOLWINDOW; only the clipboard '
          'text window uses APPWINDOW.',
    );
    expect(createBlock.contains('taskbar_ex'), isTrue,
        reason: 'CreateWindowExW must use the taskbar_ex branch, not a '
            'hard-coded ex-style.');
  });

  // TODO-615 方案A：原生 runner 必须提供主动熄灭任务栏高亮的能力
  // （FlashWindowEx + FLASHW_STOP），不再靠堆 if 守卫掩盖前台判据抖动漏判。
  test(
      'native window provides clearTaskbarFlash via FlashWindowEx(FLASHW_STOP)',
      () {
    final String cpp = read('windows/runner/flutter_window.cpp');
    expect(cpp.contains('clearTaskbarFlash'), isTrue,
        reason: 'native caption channel must handle clearTaskbarFlash.');
    expect(cpp.contains('FlashWindowEx'), isTrue,
        reason: 'clearTaskbarFlash must call FlashWindowEx.');
    expect(cpp.contains('FLASHW_STOP'), isTrue,
        reason: 'clearing the flash must use FLASHW_STOP.');
    // The clear must operate on the main window handle (GetHandle()).
    final int branch = cpp.indexOf('clearTaskbarFlash');
    final int flash = cpp.indexOf('FlashWindowEx', branch);
    expect(branch, isNonNegative);
    expect(flash, isNonNegative);
    expect(cpp.substring(branch, flash).contains('GetHandle()'), isTrue,
        reason: 'taskbar flash clear must target the main window handle.');
  });

  // TODO-615：Dart 侧熄灭任务栏高亮只允许经 WindowCaptionChannel.clearTaskbarFlash
  // 单一封装下发，禁止其它文件各自起一份 channel 调用或方法名（消除重复路径）。
  test('Dart taskbar-flash clear stays behind WindowCaptionChannel', () {
    final RegExp invokeFlash =
        RegExp(r"invokeMethod<[^>]*>\(\s*'clearTaskbarFlash'");
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final File entity
        in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      scanned++;
      final String normalized = entity.path.replaceAll('\\', '/');
      final String source = entity.readAsStringSync();
      if (!invokeFlash.hasMatch(source)) continue;
      if (!normalized.endsWith('utils/window_caption_channel.dart')) {
        offenders.add(normalized);
      }
    }
    expectScanScale(scanned,
        what: 'lib/src 下的 .dart', atLeast: 750, measured: 930);
    expect(offenders, isEmpty,
        reason: 'Only WindowCaptionChannel may invoke clearTaskbarFlash on the '
            'app.fushi/window channel.');
  });

  // TODO-615：bringPendingLookupToFront 唤前台路径必须主动 clearTaskbarFlash——
  // 已前台 early-return 前清一次（覆盖前台判据抖动漏判残留），唤前台路径尾部再清
  // 一次（覆盖 always-on-top）。两处都经 WindowCaptionChannel 单一封装。
  test('bringPendingLookupToFront clears taskbar flash on the foreground path',
      () {
    final String service = read('lib/src/sync/desktop_lookup_service.dart');
    final int bringStart = service.indexOf(
      'Future<void> bringPendingLookupToFront()',
    );
    final int focusHelperStart =
        service.indexOf('Future<bool> _isFushiForeground()');
    expect(bringStart, isNonNegative);
    expect(focusHelperStart, isNonNegative);
    final String bringBody = service.substring(bringStart, focusHelperStart);

    // clearTaskbarFlash must be invoked through WindowCaptionChannel.
    expect(
      'WindowCaptionChannel.clearTaskbarFlash()'.allMatches(bringBody).length,
      2,
      reason: 'foreground path must clear the flash both before the '
          'already-foreground early-return and at the tail (always-on-top).',
    );
    // The already-foreground clear must sit before show/focus (it runs on the
    // early-return path that never reaches show); the tail clear after.
    final int show = bringBody.indexOf('windowManager.show()');
    final int firstClear =
        bringBody.indexOf('WindowCaptionChannel.clearTaskbarFlash()');
    final int lastClear =
        bringBody.lastIndexOf('WindowCaptionChannel.clearTaskbarFlash()');
    expect(show, isNonNegative);
    expect(firstClear, isNonNegative);
    expect(firstClear < show, isTrue,
        reason: 'already-foreground path clears flash before show/focus '
            '(on its early-return path).');
    expect(lastClear > show, isTrue,
        reason: 'foreground path clears flash again after show/focus.');
  });
}

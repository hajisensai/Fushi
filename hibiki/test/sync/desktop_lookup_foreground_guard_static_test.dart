import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync();

  test('only DesktopLookupService may call windowManager show/focus directly',
      () {
    final RegExp foregroundCall = RegExp(r'windowManager\.(show|focus)\s*\(');
    final List<String> offenders = <String>[];
    for (final File entity
        in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll('\\', '/');
      final String source = entity.readAsStringSync();
      if (!foregroundCall.hasMatch(source)) continue;
      if (!normalized.endsWith('sync/desktop_lookup_service.dart')) {
        offenders.add(normalized);
      }
    }

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
        service.indexOf('Future<bool> _isHibikiForeground()');
    expect(bringStart, isNonNegative);
    expect(focusHelperStart, isNonNegative);
    final String bringBody = service.substring(bringStart, focusHelperStart);

    expect(bringBody.contains('DesktopForegroundGuard.isHiddenWindowsRunner'),
        isTrue);
    expect(bringBody.contains('await _isHibikiForeground()'), isTrue);
    expect(
      bringBody.indexOf('await _isHibikiForeground()') <
          bringBody.indexOf('windowManager.show()'),
      isTrue,
      reason: 'Foreground guard must run before show/focus.',
    );
    expect(service.contains('isForegroundOwnedByCurrentProcess()'), isTrue);
    expect(service.contains('isForegroundOwnedByHibikiAppFamily()'), isTrue,
        reason: 'Foreground guard must also treat Hibiki popup/app-family '
            'windows as internal copies.');
  });

  test('hidden Windows runner is toolwindow/noactivate and off-screen', () {
    final String runner = read('windows/runner/win32_window.cpp');
    expect(runner.contains('HIBIKI_TEST_HIDDEN'), isTrue);
    expect(runner.contains('WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE'), isTrue);
    expect(runner.contains('kOffscreenOrigin'), isTrue);
    expect(
      runner.contains('WS_OVERLAPPEDWINDOW | WS_VISIBLE'),
      isTrue,
      reason: 'Hidden runner must keep rendering while parked off-screen.',
    );
  });

  test('floating lyric window remains toolwindow/noactivate/shownoactivate',
      () {
    final String cpp = read('windows/runner/floating_lyric_window.cpp');
    final int createWindow = cpp.indexOf('CreateWindowExW(');
    final int showWindow = cpp.indexOf('ShowWindow(hwnd_,', createWindow);
    expect(createWindow, isNonNegative);
    expect(showWindow, isNonNegative);
    final String createBlock = cpp.substring(createWindow, showWindow);

    expect(createBlock.contains('WS_EX_TOOLWINDOW'), isTrue);
    expect(createBlock.contains('WS_EX_NOACTIVATE'), isTrue);
    expect(cpp.contains('ShowWindow(hwnd_, SW_SHOWNOACTIVATE)'), isTrue);
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
    for (final File entity
        in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll('\\', '/');
      final String source = entity.readAsStringSync();
      if (!invokeFlash.hasMatch(source)) continue;
      if (!normalized.endsWith('utils/window_caption_channel.dart')) {
        offenders.add(normalized);
      }
    }
    expect(offenders, isEmpty,
        reason: 'Only WindowCaptionChannel may invoke clearTaskbarFlash on the '
            'app.hibiki/window channel.');
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
        service.indexOf('Future<bool> _isHibikiForeground()');
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

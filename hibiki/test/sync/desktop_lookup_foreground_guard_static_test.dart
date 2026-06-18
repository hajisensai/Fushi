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
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥除 Dart 源码里的注释，只保留真实代码，避免静态守卫把文档注释（`///`）/行注释
/// （`//`）/块注释（`/* */`）里出现的示例文字（如反引号包裹的 `windowManager.show()`）
/// 误判为真实调用（TODO-972：CI 静态守卫误报）。
///
/// 实现是一个字符级状态机，能识别字符串字面量（`'...'` / `"..."`，含 `r''` 原始串与
/// `\` 转义），不会把字符串里出现的 `//` 误删，从而保留对真实调用的检测能力。
/// 注释字符用空格替换（保留长度/换行的相对结构对本守卫无关紧要，但避免把相邻 token
/// 粘连）。
String stripDartComments(String src) {
  final StringBuffer out = StringBuffer();
  final int n = src.length;
  int i = 0;
  while (i < n) {
    final String c = src[i];
    final String next = i + 1 < n ? src[i + 1] : '';

    // 行注释 // 或 /// —— 跳到行尾（保留换行）。
    if (c == '/' && next == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }

    // 块注释 /* ... */（含 /** 文档块）—— 跳到 */，保留其中换行以维持行结构。
    if (c == '/' && next == '*') {
      i += 2;
      while (i < n && !(src[i] == '*' && i + 1 < n && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2; // 跳过结尾 */
      continue;
    }

    // 字符串字面量 '...' 或 "..." —— 整段原样保留，串内 // 不算注释。
    if (c == '\'' || c == '"') {
      final String quote = c;
      out.write(c);
      i++;
      while (i < n) {
        final String s = src[i];
        out.write(s);
        if (s == '\\' && i + 1 < n) {
          // 转义序列：连同被转义字符一起原样写出，防止 \' / \" 提前终止。
          out.write(src[i + 1]);
          i += 2;
          continue;
        }
        i++;
        if (s == quote) break;
      }
      continue;
    }

    out.write(c);
    i++;
  }
  return out.toString();
}

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
    for (final File entity
        in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll('\\', '/');
      // 先剥除注释，只对真实代码跑守卫正则——文档/行/块注释里的示例文字不算违规。
      final String source = stripDartComments(entity.readAsStringSync());
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

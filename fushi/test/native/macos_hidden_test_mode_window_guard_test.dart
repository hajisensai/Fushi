import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3751：macOS 主窗口 `visibleAtLaunch="NO"`，启动时只有
/// `MainFlutterWindow.hideForStartupPresentation()` 会把它 orderFront。隐藏测试模式
/// （`FUSHI_TEST_HIDDEN`）下这一步曾被 `guard !hiddenTestMode else { return }` 整个跳过，
/// `showStartupWindow` 在隐藏模式下也不动窗口——窗口从未入屏，Flutter 引擎不启动，
/// 进程只剩 AppKit 事件循环（实测 7 个线程、零数据文件），macOS 隐藏模式 itest 全部起不来。
void main() {
  String read(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: 'missing $path');
    return file.readAsStringSync();
  }

  /// 取 `func <name>()` 的函数体（到同缩进的下一个 `\n  }\n` 为止）。
  String functionBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '找不到 $signature');
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start), reason: '$signature 没有闭合');
    return src.substring(start, end);
  }

  test('主窗口启动时不可见，入屏只靠 hideForStartupPresentation', () {
    final String xib = read('macos/Runner/Base.lproj/MainMenu.xib');
    final RegExpMatch? window = RegExp(
      r'<window [^>]*customClass="MainFlutterWindow"[^>]*>',
    ).firstMatch(xib);
    expect(window, isNotNull, reason: 'MainMenu.xib 里找不到 MainFlutterWindow');
    // 前提：若有人把它改回 visibleAtLaunch="YES"，本守卫的推理不再成立，需要重审。
    expect(window!.group(0), contains('visibleAtLaunch="NO"'));

    final String appDelegate = maskComments(
      read('macos/Runner/AppDelegate.swift'),
    );
    expect(
      functionBody(appDelegate, 'func applicationDidFinishLaunching('),
      contains('hideForStartupPresentation()'),
      reason: '启动时必须调用 hideForStartupPresentation 把主窗口放进屏幕',
    );
  });

  test('隐藏测试模式下 hideForStartupPresentation 仍然 orderFront 窗口', () {
    final String body = functionBody(
      maskComments(read('macos/Runner/MainFlutterWindow.swift')),
      'func hideForStartupPresentation()',
    );

    expect(
      body,
      isNot(
        matches(RegExp(r'guard\s+!\s*hiddenTestMode\s+else\s*\{\s*return')),
      ),
      reason: '隐藏模式整段跳过 = 窗口永不入屏、引擎不启动（BUG-3751）',
    );

    final int hiddenBranch = body.indexOf('if hiddenTestMode {');
    expect(hiddenBranch, isNonNegative, reason: '隐藏模式需要自己的分支');
    final int branchEnd = body.indexOf('}', hiddenBranch);
    final String branch = body.substring(hiddenBranch, branchEnd);
    final int order = branch.indexOf('orderFront(nil)');
    final int ret = branch.indexOf('return');
    expect(
      order,
      isNonNegative,
      reason: '隐藏模式分支必须 orderFront（窗口已停在屏外、不可成为 key）',
    );
    expect(
      ret,
      anyOf(-1, greaterThan(order)),
      reason: 'orderFront 必须在 return 之前',
    );
    expect(
      branch,
      isNot(contains('alphaValue')),
      reason: '隐藏模式不走透明启动展示，showStartupWindow 不会再来恢复它',
    );
  });

  test('隐藏测试模式下窗口位置由原生层钉在屏外', () {
    // orderFront 的屏幕约束、窗口状态恢复、window_manager.setBounds（Dart 启动定位）
    // 全都经 setFrame 把停在屏外的窗口拉回屏内——实测 1206x727 停在 (132, 105) 可见。
    final String src = maskComments(
      read('macos/Runner/MainFlutterWindow.swift'),
    );
    for (final String signature in <String>[
      'override func setFrame(_ frameRect: NSRect, display flag: Bool)',
      'override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, '
          'animate animateFlag: Bool)',
      'override func setFrameOrigin(_ point: NSPoint)',
    ]) {
      expect(
        functionBody(src, signature),
        contains('MainFlutterWindow.hiddenTestOrigin'),
        reason: '$signature 在隐藏模式下必须把 origin 钉回屏外',
      );
    }
    // AppKit 还会在 setFrame 之外把窗口约束到「标题栏至少一截在屏内」——实测只剩
    // 左下角 261x110 一条露在屏上。隐藏模式必须跳过这层约束。
    final String constrain = functionBody(
      src,
      'override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?)',
    );
    expect(constrain, contains('guard hiddenTestMode else'));
    expect(
      constrain,
      matches(RegExp(r'return frameRect\s*$')),
      reason: '隐藏模式下原样返回，不做屏幕约束',
    );
    expect(
      src,
      contains('NSPoint(x: -32000, y: -32000)'),
      reason: '与 Windows runner 的 kOffscreenOrigin 同一停靠位',
    );
    final String awake = functionBody(src, 'override func awakeFromNib()');
    final int hidden = awake.indexOf('if hiddenTestMode {');
    expect(hidden, isNonNegative);
    expect(
      awake.substring(hidden, awake.indexOf('}', hidden)),
      contains('isRestorable = false'),
      reason: '测试进程不得恢复 / 持久化上一次的窗口状态（恢复同样会挪窗）',
    );
  });
}

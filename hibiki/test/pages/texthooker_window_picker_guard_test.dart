import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../sync/desktop_lookup_foreground_guard_static_test.dart'
    show stripDartComments;

/// BUG-1049 的静态守卫：捕获目标的窗口选择器必须把 **Hibiki 自己启动的游戏**当成
/// 已选中的那一项。
///
/// 用户实测：从 Hibiki 启动游戏后点「捕获目标」条，弹出的窗口列表把游戏和一屏无关
/// 窗口平铺在一起、没有任何预选，等于让用户替 app 认它刚拉起来的进程。
///
/// 这条路径没法用 widget 测试可移植地覆盖：`_pickExternalWindow` 首行就是
/// `Platform.isWindows` 门（非 Windows CI 直接短路），窗口列表来自静态
/// `WindowCaptureChannel`，会话又是单例。故在源码层锁住修复结构。
void main() {
  /// 截取方法体（含花括号）：先越过参数列表，再从其后第一个 `{` 起做花括号计数。
  String methodBody(String source, String signatureNeedle) {
    final int sigIdx = source.indexOf(signatureNeedle);
    if (sigIdx < 0) throw StateError('找不到方法签名：$signatureNeedle');
    final int parenOpen = source.indexOf('(', sigIdx);
    int parenDepth = 0;
    int parenClose = -1;
    for (int i = parenOpen; i < source.length; i++) {
      if (source[i] == '(') parenDepth++;
      if (source[i] == ')') {
        parenDepth--;
        if (parenDepth == 0) {
          parenClose = i;
          break;
        }
      }
    }
    if (parenClose <= 0) throw StateError('参数列表没有闭合：$signatureNeedle');
    final int bodyOpen = source.indexOf('{', parenClose);
    if (bodyOpen <= 0) throw StateError('找不到方法体：$signatureNeedle');
    int depth = 0;
    for (int i = bodyOpen; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(bodyOpen, i + 1);
      }
    }
    throw StateError('方法体没有闭合：$signatureNeedle');
  }

  // 惰性读取：test 外不能调 expect，故文件解析放在这里、由各用例按需取。
  String pickerBody() => methodBody(
        stripDartComments(
          File('lib/src/pages/implementations/texthooker_page.dart')
              .readAsStringSync(),
        ),
        'Future<void> _pickExternalWindow()',
      );

  test('窗口列表按会话 gamePid 把当前游戏排到最前', () {
    final String body = pickerBody();
    expect(body.contains('_session.state.gamePid'), isTrue,
        reason: '会话已经知道自己启动的游戏 pid，选择器必须用上它');
    expect(body.contains('w.pid == gamePid'), isTrue,
        reason: 'Hibiki 启动的游戏窗口应排在列表最前');
  });

  test('当前游戏那一项预置焦点（打开即选中、回车即绑）', () {
    expect(pickerBody().contains('autofocus:'), isTrue);
  });

  test('选回已绑定的窗口是 no-op，不重启会话', () {
    // bindWindow 在捕获模式下会 startAttachedCapture 重启整条会话（launch 会话
    // 会退化成 attach，正在跑的 engine hook 与已收台词一起丢）。
    expect(pickerBody().contains('picked.hwnd == boundHwnd'), isTrue);
  });
}

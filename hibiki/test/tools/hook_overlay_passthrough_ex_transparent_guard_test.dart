// BUG-951 源码守卫：Hook 浮窗开鼠标穿透后，点击必须真的落到游戏窗口。
//
// 根因：WM_NCHITTEST 返回 HTTRANSPARENT 在 Win32 契约里**只在同线程窗口间下传**。
// 游戏是另一个进程，所以浮窗说“这不是我的”之后系统找不到下一个接手的同线程
// 窗口，点击**整个消失**（既不给游戏，也不给浮窗）。旧实现之所以在部分场景
// “看上去能用”，只是因为背景不透明度为 0 时体表像素 alpha=0，是**层窗口的逐像素
// 命中测试**让点击落下去的，跟 HTTRANSPARENT 无关；一旦用户把背景不透明度调成
// 非 0，整个正文区吞点击，即便为 0，点在不透明的文字笔画上照样被吞。
//
// 修复：穿透态改用 WS_EX_TRANSPARENT（真跨进程，与像素 alpha 无关）。但该位是整窗
// 属性，永久开着会把顶部“恢复带”（那里有退出穿透的按钮）一起穿掉，全屏 galgame
// 下等于把用户锁死；所以按光标位置动态开关。native C++ 无法在 Dart 测试里执行，
// 此守卫锁定源码接线不被退化。
//
// 完整复现矩阵（跨进程真实 SendInput 点击）见 BUG-951 文件。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String src =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
  final String header =
      File('windows/runner/floating_lyric_window.h').readAsStringSync();

  test('① 穿透态必须真的设 WS_EX_TRANSPARENT（不能只靠 HTTRANSPARENT）', () {
    expect(
      src.contains('WS_EX_TRANSPARENT'),
      isTrue,
      reason: 'HTTRANSPARENT 只在同线程窗口间下传，对另一进程的游戏窗口无效；'
          '穿透必须落到 WS_EX_TRANSPARENT 上',
    );
    expect(
      RegExp(r'ex\s*\|\s*static_cast<LONG_PTR>\(WS_EX_TRANSPARENT\)')
          .hasMatch(src),
      isTrue,
      reason: '穿透时必须把 WS_EX_TRANSPARENT 加进 ex-style',
    );
    expect(
      RegExp(r'ex\s*&\s*~static_cast<LONG_PTR>\(WS_EX_TRANSPARENT\)')
          .hasMatch(src),
      isTrue,
      reason: '退出穿透时必须把 WS_EX_TRANSPARENT 去掉，'
          '否则浮窗自己的交互永远回不来',
    );
    expect(src.contains('SetWindowLongPtr(hwnd_, GWL_EXSTYLE, ex);'), isTrue,
        reason: 'ex-style 写回路径不得被移除');
  });

  test('② ex-style 改完必须用 SWP_FRAMECHANGED 提交', () {
    // 实测：光 SetWindowLongPtr 时位读回已变，命中测试却还用旧值。
    final int applyStart = src.indexOf('void FloatingLyricWindow::ApplyPassThroughHitTest');
    expect(applyStart, greaterThan(-1),
        reason: 'ApplyPassThroughHitTest 是穿透命中测试的唯一写入点，不得被移除');
    final int applyEnd = src.indexOf('\nvoid FloatingLyricWindow::', applyStart + 1);
    final String body =
        src.substring(applyStart, applyEnd > 0 ? applyEnd : src.length);
    expect(body.contains('SWP_FRAMECHANGED'), isTrue,
        reason: '不走 SWP_FRAMECHANGED 提交，WS_EX_TRANSPARENT 的改动不会真正生效');
  });

  test('③ 靠光标轮询驱动（透明窗收不到任何鼠标消息）', () {
    expect(
      RegExp(r'constexpr\s+UINT_PTR\s+kPassThroughPollTimerId').hasMatch(src),
      isTrue,
      reason: '穿透态下窗口收不到 WM_MOUSEMOVE，'
          '“光标进入恢复带”只能靠轮询发现',
    );
    expect(src.contains('case WM_TIMER:'), isTrue,
        reason: '轮询定时器必须有对应的 WM_TIMER 处理分支');
    expect(src.contains('UpdatePassThroughFromCursor'), isTrue,
        reason: 'WM_TIMER 必须真的重算命中态');
    expect(
      RegExp(r'SetTimer\(hwnd_,\s*kPassThroughPollTimerId').hasMatch(src) &&
          RegExp(r'KillTimer\(hwnd_,\s*kPassThroughPollTimerId').hasMatch(src),
      isTrue,
      reason: '定时器必须成对启停，不能只开不关',
    );
  });

  test('④ 退出穿透必须无条件把点击还给浮窗（最大回归风险）', () {
    final int start = src.indexOf('void FloatingLyricWindow::SetPassThrough');
    expect(start, greaterThan(-1));
    final int end = src.indexOf('\nvoid FloatingLyricWindow::', start + 1);
    final String body = src.substring(start, end > 0 ? end : src.length);
    expect(
      body.contains('ApplyPassThroughHitTest(true)'),
      isTrue,
      reason: '关掉穿透时必须显式清掉 WS_EX_TRANSPARENT，'
          '否则浮窗的拖拽/查词/工具条全部失效',
    );
    expect(body.contains('StopPassThroughCursorPoll()'), isTrue,
        reason: '退出穿透后不应再留着轮询定时器');
    // Hide 同样不能把窗口留在透明态，否则重新 show 会继承陈旧命中态。
    final int hideStart = src.indexOf('void FloatingLyricWindow::Hide()');
    final int hideEnd = src.indexOf('\nbool FloatingLyricWindow::', hideStart + 1);
    final String hideBody =
        src.substring(hideStart, hideEnd > 0 ? hideEnd : src.length);
    expect(hideBody.contains('ApplyPassThroughHitTest(true)'), isTrue,
        reason: 'Hide 必须清掉透明位，避免重新 show 继承陈旧命中态');
  });

  test('⑤ 恢复带几何只有一份（WM_NCHITTEST 与轮询不得各算各的）', () {
    expect(
      RegExp(r'bool\s+FloatingLyricWindow::PassThroughRecoveryContainsClientY')
          .hasMatch(src),
      isTrue,
      reason: '恢复带必须是单一谓词，否则“画出来的工具条”和'
          '“能点的工具条”会漂开',
    );
    // WM_NCHITTEST 与轮询两处调用，加上定义本身 = 3 次。
    expect(
      'PassThroughRecoveryContainsClientY'.allMatches(src).length,
      greaterThanOrEqualTo(3),
      reason: 'WM_NCHITTEST 和光标轮询必须调同一个谓词',
    );
    expect(
      header.contains('bool PassThroughRecoveryContainsClientY(float client_y) const;'),
      isTrue,
      reason: '谓词声明不得被移除',
    );
  });
}

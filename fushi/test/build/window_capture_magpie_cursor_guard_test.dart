// BUG-1096 源码守卫：画面捕获里的「两个鼠标指针」。
//
// 两条成因各锁一半，C++ 无法在 Dart 测试里执行，故在源码层锁死结构：
//   ① 捕获目标：Magpie 缩放窗必须按窗口属性 Magpie.SrcHWND 重定向到真实源窗口，
//      且枚举阶段与绑定阶段**两处都做**（Dart 侧可能拿的是缓存句柄）；
//   ② 盲区：put_IsCursorCaptureEnabled 的 HRESULT 与 IGraphicsCaptureSession2 的 QI
//      结果不得再被静默丢弃，必须写进可回传的 diagnostics；
//   ③ diagnostics 要真的经 channel 回到 Dart（否则等于没记）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String capture =
      File('windows/runner/window_capture.cpp').readAsStringSync();
  final String header =
      File('windows/runner/window_capture.h').readAsStringSync();
  final String flutterWindow =
      File('windows/runner/flutter_window.cpp').readAsStringSync();

  test('① Magpie 缩放窗按 Magpie.SrcHWND 属性重定向到源窗口', () {
    expect(
      capture.contains('GetPropW(hwnd, L"Magpie.SrcHWND")'),
      isTrue,
      reason: '判定契约是窗口属性名（跨版本稳定），不是类名里的 GUID',
    );
    expect(
      header.contains('HWND ResolveScalingSourceWindow(HWND hwnd);'),
      isTrue,
      reason: '重定向必须是一个具名、可复用的入口，不得内联进某一条路径',
    );
    // 拿不到属性 / 句柄失效必须原样返回，不改变没装 Magpie 的用户路径。
    expect(
      capture.contains('if (source == hwnd || !IsWindow(source)) {'),
      isTrue,
      reason: '属性指向自身或已失效的句柄必须回落到原窗口，不得崩也不得抓错窗',
    );
  });

  test('① 枚举阶段与捕获绑定阶段都过一次重定向', () {
    final int enumUse =
        'ResolveScalingSourceWindow('.allMatches(capture).length;
    expect(
      enumUse,
      greaterThanOrEqualTo(3),
      reason: '至少三处：函数定义 + EnumProc（换 hwnd/title/pid）+ CaptureWindowPng（绑定前）',
    );
    expect(
      capture.contains('GetWindowThreadProcessId(target, &w.pid)'),
      isTrue,
      reason: 'PID 必须取重定向后的窗口——否则 voice hook 会注入 Magpie.exe 而不是游戏',
    );
  });

  test('② 光标抑制的 QI 与 HRESULT 不再被静默丢弃', () {
    expect(
      capture.contains('const HRESULT cursor_qi = session.As(&session2);'),
      isTrue,
      reason: 'IGraphicsCaptureSession2 的 QI 结果必须被接住（Win10 19041- 上会失败）',
    );
    expect(
      capture.contains(
          'const HRESULT cursor_hr = session2->put_IsCursorCaptureEnabled(false);'),
      isTrue,
      reason: 'put_IsCursorCaptureEnabled 的 HRESULT 必须被接住，不得裸调丢弃',
    );
    expect(
      capture.contains('AppendDiagnostic(out, "put_IsCursorCaptureEnabled'),
      isTrue,
      reason: 'put_ 失败必须留痕，否则「用户机器上到底关掉没有」又变成盲区',
    );
    expect(
      capture.contains('IGraphicsCaptureSession2 unavailable'),
      isTrue,
      reason: '接口本身缺失（旧系统）同样要留痕，不能与「已关掉」混为一谈',
    );
  });

  test('③ diagnostics 经 channel 回到 Dart', () {
    expect(
      header.contains('std::string diagnostics;'),
      isTrue,
      reason: 'diagnostics 必须与 error 正交（成功路径也要能说话）',
    );
    expect(
      flutterWindow.contains('flutter::EncodableValue("diagnostics")'),
      isTrue,
      reason: 'native 记了但不回传等于没记',
    );
    final String dartChannel =
        File('lib/src/mining/window_capture_channel.dart').readAsStringSync();
    expect(
      dartChannel.contains("diagnostics: m['diagnostics'] as String?"),
      isTrue,
      reason: 'Dart 侧必须解析该字段',
    );
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-618 fix3 守卫：native 退出态总闸（g_process_exiting）。
///
/// 断言：
///   1. texture_bridge.h 声明跨 TU 的 SetProcessExiting/IsProcessExiting。
///   2. texture_bridge.cc 定义 std::atomic<bool> g_process_exiting，且 PumpFrameLocked 的
///      帧上报回调 frame_available_() 之前存在退出态短路早返回。
///   3. in_app_webview_manager.cpp 的 prepareForProcessExit 入口在 webViews.clear() 之前调
///      SetProcessExiting()（早返回闸门必须在任何 teardown 之前置位）。
///
/// 本机无 MSVC 不能编译该 native fork，由 CI 编译验证；此源码扫描守卫保证逻辑不回退。
String _read(List<String> candidates, String name) {
  final File? file = candidates.map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null,
      );
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

String _body(String src, String signature, String nextMarker) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  final int end = src.indexOf(nextMarker, start + signature.length);
  expect(end, greaterThan(start),
      reason: '$signature must be bounded by $nextMarker');
  return src.substring(start, end);
}

void main() {
  test(
      'TODO-618 fix3: native process-exit master gate short-circuits frame reports',
      () {
    final String header = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
    ], 'texture_bridge.h');
    final String bridge = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ], 'texture_bridge.cc');
    final String manager = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
      '../packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp',
    ], 'in_app_webview_manager.cpp');

    // 1) 头文件跨 TU 声明（external linkage）。
    expect(header.contains('void SetProcessExiting() noexcept'), isTrue,
        reason: 'process-exit master gate setter must be declared in header');
    expect(header.contains('bool IsProcessExiting() noexcept'), isTrue,
        reason: 'process-exit master gate getter must be declared in header');

    // 2) cc 定义进程级 atomic 总闸。
    expect(bridge.contains('std::atomic<bool> g_process_exiting'), isTrue,
        reason: 'process-exit master gate must be a std::atomic<bool>');
    expect(bridge.contains('void SetProcessExiting() noexcept'), isTrue,
        reason: 'SetProcessExiting must be defined in texture_bridge.cc');
    expect(bridge.contains('bool IsProcessExiting() noexcept'), isTrue,
        reason: 'IsProcessExiting must be defined in texture_bridge.cc');

    // 3) 帧上报短路：PumpFrameLocked 内 IsProcessExiting() 早返回必须在 frame_available_()
    //    之前（退出态一律不再向引擎推帧），且既有 frame_available_() 调用未被删除（不回退）。
    final String pumpBody = _body(
      bridge,
      'void TextureBridge::PumpFrameLocked(',
      'bool TextureBridge::ShouldDropFrame()',
    );
    final int exitGate = pumpBody.indexOf('if (IsProcessExiting())');
    final int frameReport = pumpBody.indexOf('frame_available_()');
    expect(exitGate, greaterThanOrEqualTo(0),
        reason: 'PumpFrameLocked must short-circuit when process is exiting');
    expect(frameReport, greaterThan(exitGate),
        reason:
            'IsProcessExiting() early-return must guard the frame_available_() call');
    // 短路使用早返回，不得退化成只记日志后继续推帧。
    final String afterGate = pumpBody.substring(exitGate, frameReport);
    expect(afterGate.contains('return;'), isTrue,
        reason:
            'exit gate must return early, not fall through to frame report');

    // 4) prepareForProcessExit 入口在 webViews.clear() 之前置位总闸。
    final String prepareBody = _body(
      manager,
      'void InAppWebViewManager::prepareForProcessExit()',
      'bool InAppWebViewManager::isGraphicsCaptureSessionSupported()',
    );
    final int setExit = prepareBody.indexOf('SetProcessExiting()');
    final int clearWebViews = prepareBody.indexOf('webViews.clear()');
    expect(setExit, greaterThanOrEqualTo(0),
        reason: 'prepareForProcessExit must arm the master gate');
    expect(clearWebViews, greaterThan(setExit),
        reason:
            'SetProcessExiting() must run before webViews.clear() / any teardown');

    // manager.cpp 必须 include texture_bridge.h 才能看到 SetProcessExiting 声明。
    expect(
        manager.contains('#include "../custom_platform_view/texture_bridge.h"'),
        isTrue,
        reason: 'manager must include texture_bridge.h for SetProcessExiting');
  });
}

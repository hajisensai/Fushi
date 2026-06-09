import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-113 源码守卫：Windows WebView2 离屏捕获桥（vendored fork
/// `flutter_inappwebview_windows`）的 `TextureBridge::StopInternal()` 必须在拆除
/// 时 `Close()` 并置空 `frame_pool_`。否则未 Close 的 Direct3D11CaptureFramePool
/// 会在弹窗 WebView2 销毁后仍向 UI 线程派发迟到的一帧，打进已释放对象 →
/// GraphicsCapture.dll 内空指针解引用 c0000005（用户「查词点制卡」高频闪退，
/// 已由崩溃转储 + 调用栈确认）。
///
/// 真实的图形崩溃只能在 Windows 真机重编后复测；此守卫防止 Close() 被回退。
void main() {
  test('BUG-113: TextureBridge teardown makes late FrameArrived callbacks safe',
      () {
    final List<String> candidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ];
    final File? file = candidates.map(File.new).cast<File?>().firstWhere(
        (File? f) => f != null && f.existsSync(),
        orElse: () => null);
    expect(file, isNotNull, reason: 'texture_bridge.cc 未找到（路径变更？）');

    final String src = file!.readAsStringSync();
    expect(src.contains('BUG-113'), isTrue, reason: '修复说明注释应保留，标识此处的崩溃根因');
    expect(src.contains('FrameArrivedCallbackState'), isTrue,
        reason: 'FrameArrived 回调必须捕获独立状态，不能只捕获裸 this');
    expect(src.contains('InvalidateFrameArrivedCallback'), isTrue,
        reason: 'Stop/dtor 必须先失效回调状态，再拆 frame pool');
    expect(src.contains('[callback_state]'), isTrue,
        reason: 'FrameArrived lambda 应捕获 callback_state，迟到事件只读安全状态');
    expect(
        src.contains(
            '[this](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*'),
        isFalse,
        reason: 'FrameArrived lambda 不能捕获裸 this；teardown 后迟到事件会 UAF');
    expect(src.contains('remove_FrameArrived'), isFalse,
        reason: '已排队的 FirePresentEvent 会在 remove 后命中空 delegate；关闭并释放 pool 即可');
    expect(src.contains('pool_closable'), isTrue,
        reason: 'StopInternal 应取 frame_pool_ 的 IClosable 并 Close()');
    expect(src.contains('frame_pool_ = nullptr'), isTrue,
        reason: 'StopInternal 必须置空 frame_pool_，切断后续帧派发');
  });
}

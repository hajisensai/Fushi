import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-113 源码守卫：Windows WebView2 离屏捕获桥（vendored fork
/// `flutter_inappwebview_windows`）的 `TextureBridge::StopInternal()` 必须在拆除
/// 时 `Close()` 并置空 `frame_pool_`。否则未 Close 的 Direct3D11CaptureFramePool
/// 会在弹窗 WebView2 销毁后仍向 UI 线程派发迟到的一帧，打进已释放对象 →
/// GraphicsCapture.dll 内空指针解引用 c0000005（用户「查词点制卡」高频闪退，
/// 已由崩溃转储 + 调用栈确认）。
///
/// 真实的图形崩溃只能在 Windows 真机重编后复测；此守卫防止 Close() 和
/// FrameArrived delegate 生命周期防线被回退。
void main() {
  test('BUG-113: TextureBridge teardown makes late FrameArrived callbacks safe',
      () {
    final List<String> sourceCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ];
    final List<String> headerCandidates = <String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
    ];
    final File? sourceFile = sourceCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    final File? headerFile = headerCandidates
        .map(File.new)
        .cast<File?>()
        .firstWhere((File? f) => f != null && f.existsSync(),
            orElse: () => null);
    expect(sourceFile, isNotNull, reason: 'texture_bridge.cc 未找到（路径变更？）');
    expect(headerFile, isNotNull, reason: 'texture_bridge.h 未找到（路径变更？）');

    final String src = sourceFile!.readAsStringSync();
    final String header = headerFile!.readAsStringSync();
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
    expect(header.contains('frame_arrived_handler_'), isTrue,
        reason:
            'TODO-021 复发 dump 死在 GraphicsCapture 的空 TypedEventHandler，TextureBridge 必须持有 FrameArrived delegate COM 对象本体');
    expect(src.contains('frame_arrived_handler_ = Microsoft::WRL::Callback'),
        isTrue,
        reason: 'FrameArrived delegate 不能只用 add_FrameArrived 参数里的临时 Callback');
    expect(src.contains('frame_arrived_handler_.Get()'), isTrue,
        reason: 'add_FrameArrived 必须注册由 TextureBridge 成员持有的 delegate');
    expect(
      RegExp(r'add_FrameArrived\s*\(\s*Microsoft::WRL::Callback', dotAll: true)
          .hasMatch(src),
      isFalse,
      reason: '禁止恢复成 add_FrameArrived(Callback(...).Get()) 临时 delegate',
    );
    final int handlerIndex = header.indexOf('frame_arrived_handler_');
    final int framePoolIndex = header.indexOf('frame_pool_');
    expect(handlerIndex, greaterThanOrEqualTo(0));
    expect(framePoolIndex, greaterThanOrEqualTo(0));
    expect(handlerIndex, lessThan(framePoolIndex),
        reason: '成员析构逆序执行；delegate 成员必须声明在 frame_pool_ 前，让 frame_pool_ 先释放');
    expect(src.contains('remove_FrameArrived'), isFalse,
        reason: '已排队的 FirePresentEvent 会在 remove 后命中空 delegate；关闭并释放 pool 即可');
    expect(src.contains('pool_closable'), isTrue,
        reason: 'StopInternal 应取 frame_pool_ 的 IClosable 并 Close()');
    expect(src.contains('frame_pool_ = nullptr'), isTrue,
        reason: 'StopInternal 必须置空 frame_pool_，切断后续帧派发');
  });
}

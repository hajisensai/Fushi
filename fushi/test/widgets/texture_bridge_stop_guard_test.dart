import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(List<String> candidates, String name) {
  final File? file = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((File? f) => f != null && f.existsSync(), orElse: () => null);
  expect(file, isNotNull, reason: '$name not found');
  return file!.readAsStringSync();
}

String _body(String src, String signature, String nextMarker) {
  final int start = src.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '$signature not found');
  final int end = src.indexOf(nextMarker, start + signature.length);
  expect(
    end,
    greaterThan(start),
    reason: '$signature must be bounded by $nextMarker',
  );
  return src.substring(start, end);
}

void main() {
  test('BUG-4102: WGC pulls frames on a joined worker, not FrameArrived', () {
    final String src = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.cc',
    ], 'texture_bridge.cc');
    final String header = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/texture_bridge.h',
    ], 'texture_bridge.h');
    final String platformViewSrc = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.cc',
    ], 'custom_platform_view.cc');
    final String platformViewHeader = _read(<String>[
      'packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.h',
      '../packages/flutter_inappwebview_windows/windows/custom_platform_view/custom_platform_view.h',
    ], 'custom_platform_view.h');

    expect(
      src.contains('add_FrameArrived'),
      isFalse,
      reason:
          'default WGC path must not subscribe to FrameArrived; dump crashes before our handler body',
    );
    expect(
      src.contains('remove_FrameArrived'),
      isFalse,
      reason:
          'FrameArrived is not registered, so teardown must not rely on event revoke',
    );
    expect(
      src.contains('OnFrameArrived'),
      isFalse,
      reason: 'old event-driven pump must not remain in default code',
    );
    expect(
      src.contains('FrameArrivedCallbackState'),
      isFalse,
      reason: 'old event callback state must not remain in default code',
    );
    expect(
      src.contains('frame_arrived_handler'),
      isFalse,
      reason: 'old FrameArrived delegate lifetime must not remain',
    );

    // BUG-4102：旧的 UI 线程 DispatcherQueueTimer 泵（BUG-3352 64 Hz 取整、Dart 一忙
    // 就晚）整体移除；取帧在每个帧池自己的线程上按合成器时钟拉。
    for (final String banned in <String>[
      'DispatcherQueueTimer',
      'CreateTimer',
      'add_Tick',
      'StartPumpLocked',
      'StopPumpLocked',
      'PumpFrameLocked',
      'kPumpInterval100ns',
      'last_frame_content_size_',
      'winrt::com_ptr<ID3D11Texture2D> last_frame_',
    ]) {
      expect(
        src.contains(banned) || header.contains(banned),
        isFalse,
        reason: '$banned belongs to the removed UI-thread timer pump',
      );
    }
    expect(src.contains('StartFrameWorkerLocked'), isTrue);
    expect(src.contains('StopFrameWorkerLocked'), isTrue);
    expect(src.contains('DeliverFrameLocked'), isTrue);
    expect(src.contains('void RunFrameWorker('), isTrue);
    expect(
      src.contains('std::thread worker;'),
      isTrue,
      reason:
          'the worker thread is owned by the pool lifetime so retire can join it',
    );
    expect(
      src.contains('DCompositionWaitForCompositorClock'),
      isTrue,
      reason: 'the worker is paced by the compositor clock',
    );
    expect(
      src.contains('Microsoft::WRL::ComPtr<WgcDeliverHandler> deliver_handler'),
      isTrue,
      reason:
          'the platform-thread delivery delegate is retained by worker state',
    );
    expect(
      header.contains('capture_item_closed_handler_'),
      isTrue,
      reason: 'capture_item Closed callback must be member-retained',
    );
    expect(
      src.contains('capture_item_->remove_Closed(on_closed_token_)'),
      isTrue,
      reason: 'capture_item Closed callback must be removed in destructor',
    );

    // BUG-163 第四修的 free-threaded 帧池 + FrameArrived 曾让 Release 下 WebView 不出字。
    // BUG-4102 的 free-threaded 帧池不订阅任何事件：帧在取帧线程拷进私有纹理、上报
    // 回平台线程，Release 整包实测出字（见 BUG-4102 记录）。
    expect(
      src.contains('graphics_context_->CreateFreeThreadedCaptureFramePool('),
      isTrue,
      reason: 'frames are pulled off the UI thread from a free-threaded pool',
    );
    expect(
      src.contains('graphics_context_->CreateCaptureFramePool('),
      isFalse,
      reason:
          'the UI-DispatcherQueue frame pool tied capture pacing to Dart-thread load',
    );
    expect(
      src.contains('frame_pool_->Recreate('),
      isFalse,
      reason:
          'resize must retire the old pool and create a fresh pool, not mutate the old one',
    );

    final String startBody = _body(
      src,
      'bool TextureBridge::Start()',
      'bool TextureBridge::CreateAndStartFramePoolLocked()',
    );
    expect(
      startBody.contains('RetireFramePoolLocked("start")'),
      isTrue,
      reason:
          'Start reentry must retire any partially-created old pool before replacement',
    );

    final String createBody = _body(
      src,
      'bool TextureBridge::CreateAndStartFramePoolLocked()',
      'bool TextureBridge::RecreateFramePoolLocked()',
    );
    final int createPool = createBody.indexOf(
      'graphics_context_->CreateFreeThreadedCaptureFramePool(',
    );
    final int activeRetain = createBody.indexOf(
      'FramePoolLifetimeRegistry::Instance().Retain(lifetime)',
      createPool,
    );
    final int startCapture = createBody.indexOf(
      'lifetime->capture_session->StartCapture()',
    );
    final int startPump = createBody.indexOf(
      'StartFrameWorkerLocked(lifetime)',
      startCapture,
    );
    expect(createPool, greaterThanOrEqualTo(0));
    expect(
      activeRetain,
      greaterThan(createPool),
      reason: 'active pool must be retained immediately after creation',
    );
    expect(
      startPump,
      greaterThan(startCapture),
      reason: 'the frame worker starts only after StartCapture succeeds',
    );
    expect(createBody.contains('add_FrameArrived'), isFalse);

    final String stopWorkerBody = _body(
      src,
      'void TextureBridge::StopFrameWorkerLocked(',
      'void TextureBridge::PostDeliveryLocked(',
    );
    final int invalidate = stopWorkerBody.indexOf('InvalidatePumpCallback');
    final int signalStop = stopWorkerBody.indexOf('SetEvent(');
    final int join = stopWorkerBody.indexOf('worker.join()');
    final int clearShared = stopWorkerBody.indexOf('worker_shared = nullptr');
    final int clearState = stopWorkerBody.indexOf('pump_state = nullptr');
    expect(invalidate, greaterThanOrEqualTo(0));
    expect(
      signalStop,
      greaterThan(invalidate),
      reason: 'delivery must be invalidated before the worker is told to stop',
    );
    expect(
      join,
      greaterThan(signalStop),
      reason: 'the worker thread must be joined, not detached',
    );
    expect(clearShared, greaterThan(join));
    expect(clearState, greaterThan(clearShared));
    expect(
      src.contains('.detach()'),
      isFalse,
      reason: 'a detached worker could outlive the frame pool it polls',
    );

    final String retireBody = _body(
      src,
      'void TextureBridge::RetireFramePoolLocked(',
      'namespace',
    );
    final int retireStopPump = retireBody.indexOf('StopFrameWorkerLocked');
    final int clearCurrent = retireBody.indexOf(
      'frame_pool_lifetime_ = nullptr',
    );
    final int finalize = retireBody.indexOf(
      'FinalizeFramePoolLifetime(lifetime)',
    );
    expect(
      retireStopPump,
      greaterThanOrEqualTo(0),
      reason: 'retire must join the frame worker before closing resources',
    );
    expect(clearCurrent, greaterThan(retireStopPump));
    expect(
      finalize,
      greaterThan(clearCurrent),
      reason: 'session/pool close happens after current lifetime is cleared',
    );
    expect(
      retireBody.contains('TryEnqueue'),
      isFalse,
      reason: 'no handler-stack defer is needed when FrameArrived is gone',
    );

    final String finalizeBody = _body(
      src,
      'void FinalizeFramePoolLifetime(',
      'void TextureBridge::DeliverFrameLocked(',
    );
    final int sessionClose = finalizeBody.indexOf(
      'WgcLog::Write("session-close-start"',
    );
    final int poolClose = finalizeBody.indexOf(
      'WgcLog::Write("pool-close-start"',
    );
    final int markRetired = finalizeBody.indexOf(
      'FramePoolLifetimeRegistry::Instance().MarkRetired(lifetime)',
    );
    expect(finalizeBody.contains('remove_FrameArrived'), isFalse);
    expect(finalizeBody.contains('handler-release'), isFalse);
    expect(sessionClose, greaterThanOrEqualTo(0));
    expect(poolClose, greaterThan(sessionClose));
    expect(markRetired, greaterThan(poolClose));

    final String deliverBody = _body(
      src,
      'void TextureBridge::DeliverFrameLocked(',
      'bool TextureBridge::ShouldDropFrame()',
    );
    final int needsUpdate = deliverBody.indexOf('if (needs_update_)');
    final int recreate = deliverBody.indexOf(
      'RecreateFramePoolLocked()',
      needsUpdate,
    );
    final int seqCheck = deliverBody.indexOf('seq == delivered_seq_');
    expect(
      needsUpdate,
      greaterThanOrEqualTo(0),
      reason: 'resize must be processed on every delivery',
    );
    expect(recreate, greaterThan(needsUpdate));
    expect(
      seqCheck,
      greaterThan(recreate),
      reason: 'resize handling must not depend on a new frame having arrived',
    );
    expect(deliverBody.contains('frame_available_()'), isTrue);
    expect(
      deliverBody.contains('TryGetNextFrame'),
      isFalse,
      reason: 'the platform thread never touches WGC frames',
    );

    final String workerBody = _body(
      src,
      'void RunFrameWorker(',
      '}  // namespace',
    );
    expect(
      workerBody.contains('i < kMaxFramesPerDrain'),
      isTrue,
      reason: 'each wake drains a bounded number of queued frames',
    );
    expect(
      workerBody.contains('frame_available_'),
      isFalse,
      reason:
          'the worker never calls into Flutter; delivery hops to the platform thread',
    );
    expect(
      workerBody.contains('TryEnqueue'),
      isTrue,
      reason: 'the worker posts delivery to the platform DispatcherQueue',
    );

    for (final String banned in <String>[
      'TryEnqueueWithPriority',
      'DispatcherQueuePriority_Low',
      'kCaptureTeardownQuietHops',
      'kCaptureTeardownDrainHops',
      'PendingCaptureTeardown',
      'std::remove_if',
      'kRetiredGenerationGap',
    ]) {
      expect(
        src.contains(banned),
        isFalse,
        reason: '$banned is an old timing-based teardown strategy',
      );
    }
    expect(src.contains('FramePoolLifetimeRegistry'), isTrue);
    expect(
      src.contains('push_back'),
      isTrue,
      reason: 'registry keeps lifetimes alive for crash forensics',
    );
    expect(src.contains('MarkRetired('), isTrue);

    final int destructorStart = platformViewSrc.indexOf(
      'CustomPlatformView::~CustomPlatformView()',
    );
    final int nextMethodStart = platformViewSrc.indexOf(
      'void CustomPlatformView::RegisterEventHandlers()',
    );
    expect(destructorStart, greaterThanOrEqualTo(0));
    expect(nextMethodStart, greaterThan(destructorStart));
    final String destructorBody = platformViewSrc.substring(
      destructorStart,
      nextMethodStart,
    );
    final int severIndex = destructorBody.indexOf(
      'SetOnFrameAvailable(nullptr)',
    );
    final int stopIndex = destructorBody.indexOf('texture_bridge_->Stop()');
    final int unregisterIndex = destructorBody.indexOf(
      'texture_registrar_->UnregisterTexture',
    );
    expect(
      severIndex,
      greaterThanOrEqualTo(0),
      reason: 'consumer callback must be severed before WGC Stop',
    );
    expect(stopIndex, greaterThan(severIndex));
    expect(
      unregisterIndex,
      greaterThan(stopIndex),
      reason: 'WGC Stop must happen before unregistering Flutter texture',
    );
    expect(destructorBody.contains('WgcLog::Write("stop-start"'), isTrue);
    expect(destructorBody.contains('WgcLog::Write("stop-done"'), isTrue);
    expect(destructorBody.contains('WgcLog::Write("unregister-start"'), isTrue);
    expect(destructorBody.contains('WgcLog::Write("unregister-done"'), isTrue);

    final int textureBridgeMemberIndex = platformViewHeader.indexOf(
      'texture_bridge_',
    );
    final int flutterTextureMemberIndex = platformViewHeader.indexOf(
      'flutter_texture_',
    );
    expect(textureBridgeMemberIndex, greaterThanOrEqualTo(0));
    expect(flutterTextureMemberIndex, greaterThanOrEqualTo(0));
    expect(
      textureBridgeMemberIndex,
      lessThan(flutterTextureMemberIndex),
      reason:
          'member destruction order should destroy flutter_texture_ before texture_bridge_',
    );
  });
}

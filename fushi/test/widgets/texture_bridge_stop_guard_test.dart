import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  test('TODO-508: WGC default path uses removable timer pump, not FrameArrived',
      () {
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

    expect(src.contains('add_FrameArrived'), isFalse,
        reason:
            'default WGC path must not subscribe to FrameArrived; dump crashes before our handler body');
    expect(src.contains('remove_FrameArrived'), isFalse,
        reason:
            'FrameArrived is not registered, so teardown must not rely on event revoke');
    expect(src.contains('OnFrameArrived'), isFalse,
        reason: 'old event-driven pump must not remain in default code');
    expect(src.contains('FrameArrivedCallbackState'), isFalse,
        reason: 'old event callback state must not remain in default code');
    expect(src.contains('frame_arrived_handler'), isFalse,
        reason: 'old FrameArrived delegate lifetime must not remain');

    expect(header.contains('DispatcherQueueTimer'), isTrue);
    expect(src.contains('CreateTimer'), isTrue);
    expect(src.contains('add_Tick'), isTrue);
    expect(src.contains('remove_Tick'), isTrue);
    expect(src.contains('StartPumpLocked'), isTrue);
    expect(src.contains('StopPumpLocked'), isTrue);
    expect(src.contains('PumpFrameLocked'), isTrue);
    expect(src.contains('Microsoft::WRL::ComPtr<WgcPumpTickHandler>'), isTrue,
        reason: 'timer tick delegate must be retained by the pool lifetime');
    expect(src.contains('EventRegistrationToken on_tick_token'), isTrue,
        reason:
            'timer tick token must be saved so StopPumpLocked can remove it');
    expect(header.contains('capture_item_closed_handler_'), isTrue,
        reason: 'capture_item Closed callback must be member-retained');
    expect(
        src.contains('capture_item_->remove_Closed(on_closed_token_)'), isTrue,
        reason: 'capture_item Closed callback must be removed in destructor');

    expect(src.contains('CreateFreeThreadedCaptureFramePool'), isFalse,
        reason: 'free-threaded capture previously blanked WebView rendering');
    expect(src.contains('graphics_context_->CreateCaptureFramePool('), isTrue,
        reason: 'capture remains on the UI DispatcherQueue frame pool');
    expect(src.contains('frame_pool_->Recreate('), isFalse,
        reason:
            'resize must retire the old pool and create a fresh pool, not mutate the old one');

    final String startBody = _body(
      src,
      'bool TextureBridge::Start()',
      'bool TextureBridge::CreateAndStartFramePoolLocked()',
    );
    expect(startBody.contains('RetireFramePoolLocked("start")'), isTrue,
        reason:
            'Start reentry must retire any partially-created old pool before replacement');

    final String createBody = _body(
      src,
      'bool TextureBridge::CreateAndStartFramePoolLocked()',
      'void TextureBridge::RecreateFramePoolLocked()',
    );
    final int createPool =
        createBody.indexOf('graphics_context_->CreateCaptureFramePool(');
    final int activeRetain = createBody.indexOf(
        'FramePoolLifetimeRegistry::Instance().Retain(lifetime)', createPool);
    final int startCapture =
        createBody.indexOf('lifetime->capture_session->StartCapture()');
    final int startPump =
        createBody.indexOf('StartPumpLocked(lifetime)', startCapture);
    expect(createPool, greaterThanOrEqualTo(0));
    expect(activeRetain, greaterThan(createPool),
        reason: 'active pool must be retained immediately after creation');
    expect(startPump, greaterThan(startCapture),
        reason: 'timer pump starts only after StartCapture succeeds');
    expect(createBody.contains('add_FrameArrived'), isFalse);

    final String stopPumpBody = _body(
      src,
      'void TextureBridge::StopPumpLocked(',
      'void TextureBridge::Stop()',
    );
    final int invalidate = stopPumpBody.indexOf('InvalidatePumpCallback');
    final int stopTimer = stopPumpBody.indexOf('pump_timer->Stop()');
    final int removeTick = stopPumpBody.indexOf('remove_Tick');
    final int releaseHandler =
        stopPumpBody.indexOf('pump_tick_handler = nullptr');
    final int clearState = stopPumpBody.indexOf('pump_state = nullptr');
    final int clearTimer = stopPumpBody.indexOf('pump_timer = nullptr');
    expect(invalidate, greaterThanOrEqualTo(0));
    expect(stopTimer, greaterThan(invalidate),
        reason: 'StopPumpLocked must invalidate callback state before Stop');
    expect(removeTick, greaterThan(stopTimer),
        reason:
            'timer Tick must be removed after Stop and before releasing it');
    expect(releaseHandler, greaterThan(removeTick));
    expect(clearState, greaterThan(releaseHandler));
    expect(clearTimer, greaterThan(clearState));

    final String retireBody = _body(
      src,
      'void TextureBridge::RetireFramePoolLocked(',
      'namespace',
    );
    final int retireStopPump = retireBody.indexOf('StopPumpLocked');
    final int clearCurrent =
        retireBody.indexOf('frame_pool_lifetime_ = nullptr');
    final int finalize =
        retireBody.indexOf('FinalizeFramePoolLifetime(lifetime)');
    expect(retireStopPump, greaterThanOrEqualTo(0),
        reason: 'retire must stop/remove the pump before closing resources');
    expect(clearCurrent, greaterThan(retireStopPump));
    expect(finalize, greaterThan(clearCurrent),
        reason: 'session/pool close happens after current lifetime is cleared');
    expect(retireBody.contains('TryEnqueue'), isFalse,
        reason: 'no handler-stack defer is needed when FrameArrived is gone');

    final String finalizeBody = _body(
      src,
      'void FinalizeFramePoolLifetime(',
      'void TextureBridge::PumpFrameLocked(',
    );
    final int sessionClose =
        finalizeBody.indexOf('WgcLog::Write("session-close-start"');
    final int poolClose =
        finalizeBody.indexOf('WgcLog::Write("pool-close-start"');
    final int markRetired = finalizeBody
        .indexOf('FramePoolLifetimeRegistry::Instance().MarkRetired(lifetime)');
    expect(finalizeBody.contains('remove_FrameArrived'), isFalse);
    expect(finalizeBody.contains('handler-release'), isFalse);
    expect(sessionClose, greaterThanOrEqualTo(0));
    expect(poolClose, greaterThan(sessionClose));
    expect(markRetired, greaterThan(poolClose));

    final String pumpBody = _body(
      src,
      'void TextureBridge::PumpFrameLocked(',
      'bool TextureBridge::ShouldDropFrame()',
    );
    final int needsUpdate = pumpBody.indexOf('if (needs_update_)');
    final int recreate =
        pumpBody.indexOf('RecreateFramePoolLocked()', needsUpdate);
    final int tryGet = pumpBody.indexOf('TryGetNextFrame');
    expect(needsUpdate, greaterThanOrEqualTo(0),
        reason: 'resize must be processed on every tick');
    expect(recreate, greaterThan(needsUpdate));
    expect(tryGet, greaterThan(recreate),
        reason:
            'resize handling must not depend on successfully taking a frame');
    expect(pumpBody.contains('i < kMaxFramesPerPump'), isTrue,
        reason: 'each tick drains a bounded number of queued frames');
    expect(pumpBody.contains('frame_available_()'), isTrue);

    for (final String banned in <String>[
      'TryEnqueueWithPriority',
      'DispatcherQueuePriority_Low',
      'kCaptureTeardownQuietHops',
      'kCaptureTeardownDrainHops',
      'PendingCaptureTeardown',
      'std::remove_if',
      'kRetiredGenerationGap',
    ]) {
      expect(src.contains(banned), isFalse,
          reason: '$banned is an old timing-based teardown strategy');
    }
    expect(src.contains('FramePoolLifetimeRegistry'), isTrue);
    expect(src.contains('push_back'), isTrue,
        reason: 'registry keeps lifetimes alive for crash forensics');
    expect(src.contains('MarkRetired('), isTrue);

    final int destructorStart =
        platformViewSrc.indexOf('CustomPlatformView::~CustomPlatformView()');
    final int nextMethodStart = platformViewSrc
        .indexOf('void CustomPlatformView::RegisterEventHandlers()');
    expect(destructorStart, greaterThanOrEqualTo(0));
    expect(nextMethodStart, greaterThan(destructorStart));
    final String destructorBody =
        platformViewSrc.substring(destructorStart, nextMethodStart);
    final int severIndex =
        destructorBody.indexOf('SetOnFrameAvailable(nullptr)');
    final int stopIndex = destructorBody.indexOf('texture_bridge_->Stop()');
    final int unregisterIndex =
        destructorBody.indexOf('texture_registrar_->UnregisterTexture');
    expect(severIndex, greaterThanOrEqualTo(0),
        reason: 'consumer callback must be severed before WGC Stop');
    expect(stopIndex, greaterThan(severIndex));
    expect(unregisterIndex, greaterThan(stopIndex),
        reason: 'WGC Stop must happen before unregistering Flutter texture');
    expect(destructorBody.contains('WgcLog::Write("stop-start"'), isTrue);
    expect(destructorBody.contains('WgcLog::Write("stop-done"'), isTrue);
    expect(destructorBody.contains('WgcLog::Write("unregister-start"'), isTrue);
    expect(destructorBody.contains('WgcLog::Write("unregister-done"'), isTrue);

    final int textureBridgeMemberIndex =
        platformViewHeader.indexOf('texture_bridge_');
    final int flutterTextureMemberIndex =
        platformViewHeader.indexOf('flutter_texture_');
    expect(textureBridgeMemberIndex, greaterThanOrEqualTo(0));
    expect(flutterTextureMemberIndex, greaterThanOrEqualTo(0));
    expect(textureBridgeMemberIndex, lessThan(flutterTextureMemberIndex),
        reason:
            'member destruction order should destroy flutter_texture_ before texture_bridge_');
  });
}

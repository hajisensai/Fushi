import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('attached mining fences both the glyph surface and lookup card', () {
    final String controller = File(
      'lib/src/lookup/gal_hook_text_overlay_controller.dart',
    ).readAsStringSync();
    final String attachedController = File(
      'lib/src/lookup/gal_attached_text_controller.dart',
    ).readAsStringSync();
    final String nativeCard = File(
      'windows/runner/global_lookup_window.cpp',
    ).readAsStringSync();

    final int attachedLookup = controller.indexOf(
      'Future<void> _onAttachedLookupText(',
    );
    final int suppliesLease = controller.indexOf(
      'captureLeaseFactory: _acquireAttachedMiningCaptureLease',
      attachedLookup,
    );
    final int acquireSurface = controller.indexOf(
      '.acquireMiningCaptureLease();',
      suppliesLease,
    );
    final int suspendCard = controller.indexOf(
      'GlobalLookupChannel.suspendForCapture(',
      acquireSurface,
    );
    final int grantLease = controller.indexOf(
      'return _AttachedCompositeCaptureLease(',
      suspendCard,
    );
    expect(
      attachedLookup < suppliesLease &&
          suppliesLease < acquireSurface &&
          acquireSurface < suspendCard &&
          suspendCard < grantLease,
      isTrue,
      reason: '截图 lease 只能在 attached surface 与查词卡都完成隐藏确认后发放',
    );

    expect(
      controller,
      contains('await _restoreAttachedCaptureSurfaces(route, attachedLease)'),
      reason: '失败和正常 release 都必须补偿恢复两个独立 composition surface',
    );
    expect(controller, contains('bool _released = false;'));
    expect(controller, contains('Future<void>? _releaseFuture;'));
    expect(controller, contains('if (pending != null) return pending;'));
    expect(
      controller.indexOf('await releaseCallback();'),
      lessThan(controller.indexOf('_released = true;')),
      reason: '失败 release 必须可重试；并发 caller 必须共享正在执行的 Future',
    );
    expect(
      controller,
      contains("StateError('lookup_card_capture_restore_rejected')"),
      reason: 'a false native restore acknowledgement must not be swallowed',
    );
    expect(
      attachedController,
      contains("reason: 'capture_restore_reply_lost'"),
      reason: 'native 消耗 token 后丢回执必须进入 fail-closed reconciliation',
    );
    expect(
      attachedController,
      contains('await _surfacePort.detach(target);'),
      reason: '未知 restore 结果只能 detach 清 suppression/geometry，不能重放旧文本',
    );

    final String attachedNative = File(
      'windows/runner/attached_text_surface_window.cpp',
    ).readAsStringSync();
    final String captureToken = File(
      'windows/runner/attached_capture_token.h',
    ).readAsStringSync();
    final int restore = attachedNative.indexOf(
      'AttachedTextSurfaceWindow::RestoreAfterCapture(',
    );
    final int releaseToken = attachedNative.indexOf(
      'fushi::attached_capture_token::Release(',
      restore,
    );
    final int syncCurrent = attachedNative.indexOf(
      'SyncToTarget();',
      releaseToken,
    );
    final int barrier = attachedNative.indexOf(
      'const HRESULT barrier = DwmFlush();',
      syncCurrent,
    );
    final int rejectBarrier = attachedNative.indexOf(
      'if (FAILED(barrier))',
      barrier,
    );
    expect(
      restore < releaseToken &&
          releaseToken < syncCurrent &&
          syncCurrent < barrier &&
          barrier < rejectBarrier,
      isTrue,
      reason: 'exact token 必须先消费，再同步 native 当前 generation 并等待 barrier',
    );
    final int restoreEnd = attachedNative.indexOf(
      'bool AttachedTextSurfaceWindow::DesktopOverlayAvailableForTarget(',
      restore,
    );
    final String restoreBody = attachedNative.substring(restore, restoreEnd);
    expect(
      restoreBody,
      isNot(contains('text_generation != text_generation_')),
      reason: '换句后仍必须解除同一 token，不能用 acquisition generation 提前 return',
    );
    expect(
      captureToken,
      contains('state->surface_epoch != surface_epoch'),
      reason: '旧 epoch 仍必须 fail closed',
    );
    expect(
      captureToken,
      contains('state->token != token'),
      reason: '旧 token 仍必须 fail closed',
    );

    expect(nativeCard, contains('bool GlobalLookupWindow::SuspendForCapture('));
    expect(
      nativeCard,
      contains('bool GlobalLookupWindow::RestoreAfterCapture('),
    );
    expect(nativeCard, contains('const HRESULT barrier = DwmFlush();'));
    expect(nativeCard, contains('CaptureRouteIsCurrent()'));
    expect(
      nativeCard,
      contains('capture_generation_ != capture_generation'),
      reason: '旧 capture generation 不能恢复新卡',
    );
  });

  test(
    'v1 attached path withdraws ruby lines instead of guessing geometry',
    () {
      final String controller = File(
        'lib/src/lookup/gal_hook_text_overlay_controller.dart',
      ).readAsStringSync();
      expect(
        controller,
        contains('latestAttachedLine.rubySpans.isNotEmpty'),
        reason: 'ruby baseline and game glyph geometry are not interchangeable',
      );
      expect(
        controller,
        contains(
          'if (latest.rubySpans.isNotEmpty || latest.text != hit.sourceText)',
        ),
        reason:
            'a delayed attached hit must be rejected if ruby metadata appears',
      );
    },
  );
}

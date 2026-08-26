// SGRE 单击查词跨越注入 DLL 的 DirectInput detour 与 worker 线程，Flutter
// widget 测试无法伪造这条原始设备链。这里锁住可离线证明的事务边界：按下瞬间
// 重新命中字形并只吞左键，抬起才排队；detour 不做编码/IPC；旧绘制不能续命。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String header = File(
    '../native/galgame_hook/hook/adapters/sgre_lookup.h',
  ).readAsStringSync();
  final String source = File(
    '../native/galgame_hook/hook/adapters/sgre_lookup.inc',
  ).readAsStringSync();
  final String overlaySource = File(
    '../native/galgame_hook/hook/lookup_overlay_window.inc',
  ).readAsStringSync();
  final String ipcHeader = File(
    '../native/galgame_hook/include/voice_hook_ipc.h',
  ).readAsStringSync();
  final String controllerSource = File(
    'lib/src/lookup/gal_ingame_lookup_controller.dart',
  ).readAsStringSync();
  final String channelSource = File(
    'lib/src/platform/gal_hook_text_overlay_channel.dart',
  ).readAsStringSync();

  test('fresh down 重新验证窗口/坐标并只锁存左键，matching up 才提交', () {
    final String detour = compactCode(
      methodBody(source, 'HRESULT STDMETHODCALLTYPE SgreGetDeviceStateDetour('),
    );
    final String pressGate = compactCode(
      methodBody(source, 'bool BuildSgreLookupClickPayloadAtPress('),
    );

    expect(pressGate.contains('GetForegroundWindow()!=game'), isTrue);
    expect(pressGate.contains('WindowFromPoint(screen_point)'), isTrue);
    expect(
      pressGate.contains('point_window!=game&&!IsChild(game,point_window)'),
      isTrue,
      reason: '被其他窗口盖住时不能命中下层游戏文字',
    );
    expect(pressGate.contains('GetClientRect(game,&client)'), isTrue);
    expect(pressGate.contains('ClientToScreen(game,&client_origin)'), isTrue);
    expect(pressGate.contains('FindSgreLookupGlyph('), isTrue);

    final int readTarget = detour.indexOf('ReadSgreLookupClickTarget(');
    final int advance = detour.indexOf('AdvanceSgreLookupClickGesture(');
    final int begin = detour.indexOf('SgreLookupClickAction::kBegin');
    final int latch = detour.indexOf(
      'fetch_or(fushi_voice_hook::kSgreLookupPrimaryButtonMask',
    );
    final int submit = detour.indexOf('SgreLookupClickAction::kSubmit');
    final int queue = detour.indexOf('QueueSgreLookupClickSubmit(');
    final int filter = detour.indexOf('FilterSgreDirectInputMouseButtons(');
    expect(readTarget, greaterThanOrEqualTo(0));
    expect(advance, greaterThan(readTarget));
    expect(begin, greaterThan(advance));
    expect(latch, greaterThan(begin));
    expect(submit, greaterThan(latch));
    expect(queue, greaterThan(submit));
    expect(filter, greaterThan(queue));
    expect(
      detour.contains('GetValidPublishedSgreDirectInputShieldPopup(game)') &&
          detour.contains('!shield_active&&game!=nullptr'),
      isTrue,
      reason: '已有弹框的关闭点击与底层单击查词必须互斥',
    );
  });

  test('DirectInput 热 detour 只搬定长快照，不编码、不发布 IPC', () {
    final String detour = compactCode(
      methodBody(source, 'HRESULT STDMETHODCALLTYPE SgreGetDeviceStateDetour('),
    );
    expect(detour.contains('WideCharToMultiByte'), isFalse);
    expect(detour.contains('PublishSgreLookupHit'), isFalse);
    expect(detour.contains('FindGameMainWindow'), isFalse);
    expect(detour.contains('std::wstring'), isFalse);
    expect(detour.contains('QueueSgreLookupClickSubmit('), isTrue);
  });

  test('手势先同步完整 up，屏幕位移取消，miss 不会半途开始吞点击', () {
    final String gesture = compactCode(
      methodBody(
        header,
        'inline SgreLookupClickAction AdvanceSgreLookupClickGesture(',
      ),
    );
    expect(gesture.contains('if(!state->synchronized)'), isTrue);
    expect(
      gesture.contains('if(!button_down)state->synchronized=true'),
      isTrue,
    );
    expect(gesture.contains('button_down&&!state->last_down'), isTrue);
    expect(gesture.contains('state->down_x=pointer_x'), isTrue);
    expect(gesture.contains('distance_squared>=threshold_squared'), isTrue);
    expect(gesture.contains('state->cancelled=true'), isTrue);
    expect(
      gesture.indexOf('returnSgreLookupClickAction::kSubmit') >
          gesture.indexOf('state->last_down=false'),
      isTrue,
      reason: 'down 只能 Begin；查词提交必须等匹配 release',
    );
  });

  test('worker 处理自包含事件并淘汰空白/过期绘制', () {
    final String tick = compactCode(
      methodBody(source, 'void ProcessSgreLookupTick()'),
    );
    final String capture = compactCode(
      methodBody(source, 'void CaptureSgreLookupDrawState('),
    );
    final String publish = compactCode(
      methodBody(source, 'bool PublishSgreLookupClickPayload('),
    );

    expect(tick.contains('ReadLatestSgreLookupClickSubmit('), isTrue);
    expect(tick.contains('PublishSgreLookupClickTarget('), isTrue);
    expect(tick.contains('InvalidateSgreLookupClickTarget()'), isTrue);
    expect(tick.contains('kSgreLookupActiveCaptureMaxAgeMs'), isTrue);
    expect(
      capture.contains('capture_result==SgreLookupCaptureResult::kNoGlyphs') &&
          capture.contains('g_sgre_lookup_scenario_surface.load(') &&
          capture.contains('PublishSgreLookupCaptureSnapshot(snapshot)'),
      isTrue,
      reason: '同一场景 surface 清空后必须发 tombstone，旧台词不能无限续命',
    );
    expect(publish.contains('1469598103934665603ull'), isTrue);
    expect(
      publish.contains('payload.capture_seq==g_sgre_lookup_last_hit'),
      isFalse,
      reason: 'capture seq 每帧变化，Shift+click 去重必须使用稳定可见内容',
    );
  });

  test('位图回退的卡外点击由 UI 单写者请求完整 dismiss', () {
    final String detour = compactCode(
      methodBody(source, 'HRESULT STDMETHODCALLTYPE SgreGetDeviceStateDetour('),
    );
    final String request = compactCode(
      methodBody(overlaySource, 'bool RequestLookupOverlayOutsideDismiss()'),
    );
    final String poll = compactCode(
      methodBody(overlaySource, 'void PollOverlayFrame()'),
    );
    final String handleInput = compactCode(
      methodBody(controllerSource, 'Future<void> handleInput('),
    );
    final String dismissControl = compactCode(
      methodBody(controllerSource, 'Future<void> _runQueuedOutsideDismiss('),
    );

    expect(ipcHeader.contains('kLookupInputDismissOutside = 5'), isTrue);
    expect(
      channelSource.contains('static const int dismissOutsideKind = 5'),
      isTrue,
    );
    expect(
      detour.contains('direct_popup==nullptr&&bitmap_popup_visible'),
      isTrue,
    );
    expect(detour.contains('WindowFromPoint(pointer)'), isTrue);
    expect(
      detour.contains('point_window==game||IsChild(game,point_window)'),
      isTrue,
      reason: '只允许真实落在前台游戏客户窗口的卡外 down 请求关闭',
    );
    expect(detour.contains('RequestLookupOverlayOutsideDismiss()'), isTrue);
    expect(request.contains('g_lookup_overlay_visibility_epoch'), isTrue);
    expect(request.contains('g_lookup_overlay_outside_dismiss_epoch'), isTrue);
    expect(
      poll.contains(
        'QueueOverlayInput(fushi_voice_hook::kLookupInputDismissOutside',
      ),
      isTrue,
      reason: 'DirectInput detour 不能与 overlay WndProc 并发写共享输入环',
    );
    final int queueDismiss = poll.indexOf('kLookupInputDismissOutside');
    final int queueReturn = poll.indexOf('return', queueDismiss);
    expect(queueDismiss, greaterThanOrEqualTo(0));
    expect(queueReturn, greaterThan(queueDismiss));
    expect(
      poll.substring(queueDismiss, queueReturn).contains('HideOverlay()'),
      isFalse,
      reason: '必须等 Dart 普通 dismiss 帧返回，期间保持 raw-input shield fail-closed',
    );
    expect(poll.contains('g_overlay.outside_dismiss_pending=true'), isTrue);
    expect(
      poll.contains('if(!g_overlay.outside_dismiss_pending)'),
      isTrue,
      reason: '同一 visibility epoch 的重复点击只能发布一次 kind=5',
    );
    expect(
      poll.contains(
        'g_overlay.outside_dismiss_pending&&(candidate->flags&fushi_voice_hook::kLookupFrameDismiss)==0',
      ),
      isTrue,
      reason: '关闭帧回来前不得让同一可见 HWND 呈现 route 竞态产生的新 full frame',
    );
    final int controlGate = handleInput.indexOf(
      'input.kind==GalLookupInput.dismissOutsideKind',
    );
    final int routeSnapshot = handleInput.indexOf(
      'finalGlobalLookupRoute?route=_activeRoute',
    );
    expect(controlGate, greaterThanOrEqualTo(0));
    expect(
      routeSnapshot,
      greaterThan(controlGate),
      reason: 'kind=5 是会话控制，不能先捕获随后可能过期的 route/generation',
    );
    expect(dismissControl.contains('_terminateCurrentLookup()'), isTrue);
    expect(dismissControl.contains('_isCurrentLookup('), isFalse);
    expect(dismissControl.contains('galLookupInput(input)'), isFalse);
  });
}

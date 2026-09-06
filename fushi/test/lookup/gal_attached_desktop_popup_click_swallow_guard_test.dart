// attached 校准字形表面（galgame 通用回退，kind=4/id=11）打开的**桌面弹窗**：
//
//   ① 点卡外关闭那一记 down/up 必须成对吞掉，不得穿透到游戏推进台词。
//      direct galCard 早有这条消费策略（BUG-1882，`consume_outside_owner`）；
//      attached 命中走的是普通桌面 route（`GlobalLookupController.lookupText`），
//      其 Reveal/RevealStack 只做异步穿透 Arm，`HandleGlobalClick` 只 Hide，那记
//      down 经 CallNextHookEx 落进游戏——点外关闭 = 游戏进下一句。
//   ② attached 表面补 Shift+悬浮查词（与台词浮窗 MaybeHoverLookup 同语义：Shift
//      是显式意图，不受 hover_auto_lookup 偏好控制），悬浮不进 v19 shield 事务、
//      不吞任何输入。
//
// 系统级 WH_MOUSE_LL / 定时器在 Dart 测试里伪造不了；这里锁住可自动证明的最强
// 结构 + channel 契约 + DTO 解析。runner 纯逻辑（AttachedHoverTracker）另有
// C++ 单测 tests/attached_hover_tracker_test.cpp。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_channel.dart';
import 'package:fushi/src/lookup/overlay_window_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

import '../helpers/source_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  final String windowSource = read('windows/runner/global_lookup_window.cpp');
  final String windowHeader = read('windows/runner/global_lookup_window.h');
  final String hookSource = read('windows/runner/low_level_mouse_hook.cpp');
  final String flutterWindowSource = read('windows/runner/flutter_window.cpp');
  final String attachedSource = read(
    'windows/runner/attached_text_surface_window.cpp',
  );
  final String attachedHeader = read(
    'windows/runner/attached_text_surface_window.h',
  );
  final String cmake = read('windows/runner/CMakeLists.txt');
  final String overlayController = read(
    'lib/src/lookup/gal_hook_text_overlay_controller.dart',
  );
  final String lookupController = read(
    'lib/src/lookup/global_lookup_controller.dart',
  );

  group('runner: attached 桌面弹窗点卡外吞点击', () {
    test('Reveal/RevealStack 在 owner 非空时走同步吞点击 Arm，失败退回穿透', () {
      final String header = compactCode(windowHeader);
      expect(
        header.contains('voidSetOutsideClickConsumeOwner(HWNDowner);'),
        isTrue,
        reason: 'runner 必须暴露 setter，Dart 在 showAt 之前设置 owner',
      );
      expect(
        header.contains('HWNDpending_outside_click_owner_=nullptr;'),
        isTrue,
      );

      final String reveal = compactCode(
        methodBody(windowSource, 'void GlobalLookupWindow::Reveal('),
      );
      final int adopt = reveal.indexOf(
        'if(consume_outside_owner==nullptr){consume_outside_owner=pending_outside_click_owner_;}',
      );
      final int armAndWait = reveal.indexOf(
        'ArmLowLevelMouseHookAndWait(hwnd_,consume_outside_owner)',
      );
      expect(adopt, greaterThanOrEqualTo(0));
      expect(
        armAndWait,
        greaterThan(adopt),
        reason: '参数为空时先采用 pending owner，再进入同步吞点击 Arm',
      );

      final String stack = compactCode(
        methodBody(windowSource, 'void GlobalLookupWindow::RevealStack('),
      );
      final int stackArm = stack.indexOf(
        'ArmLowLevelMouseHookAndWait(hwnd_,pending_outside_click_owner_)',
      );
      final int stackFallback = stack.indexOf('ArmLowLevelMouseHook(hwnd_);');
      expect(
        stackArm,
        greaterThanOrEqualTo(0),
        reason: 'RevealStack 才是桌面 route 真正上屏的入口，owner 非空必须同步吞点击 Arm',
      );
      expect(
        stack.contains('if(pending_outside_click_owner_!=nullptr){'),
        isTrue,
        reason: '普通桌面查词（owner 为空）必须维持原异步穿透 Arm',
      );
      expect(
        stackFallback,
        greaterThan(stackArm),
        reason: '同步 Arm 未被确认时退回穿透 Arm（卡片照常显示），而不是不上屏',
      );
      expect(
        stack.contains(
          'if(!consume_armed){fushi::ArmLowLevelMouseHook(hwnd_);}',
        ),
        isTrue,
      );
    });

    test('Hide 清 owner，Disarm 撤销 HWND 上的 consume-owner property', () {
      final String hide = compactCode(
        methodBody(windowSource, 'void GlobalLookupWindow::Hide('),
      );
      final int clear = hide.indexOf('pending_outside_click_owner_=nullptr;');
      final int release = hide.indexOf('ReleaseDismissHooks();');
      expect(clear, greaterThanOrEqualTo(0));
      expect(
        release,
        greaterThan(clear),
        reason: 'owner 只活一次查词：下一次普通桌面查词绝不能继承游戏 HWND 去吞点击',
      );

      final String disarm = compactCode(
        methodBody(hookSource, 'void DisarmLowLevelMouseHook('),
      );
      final int targetClear = disarm.indexOf('g_target.store(nullptr');
      final int removeProp = disarm.indexOf(
        'RemovePropW(expected_target,kConsumeOutsideOwnerProperty);',
      );
      expect(targetClear, greaterThanOrEqualTo(0));
      expect(
        removeProp,
        greaterThan(targetClear),
        reason:
            '桌面 popup HWND 现在会带 consume-owner property；异步 Arm 不碰属性，'
            '所以必须由 Disarm 在清 target 之后撤销，否则下一次普通查词照样吞游戏点击',
      );
    });

    test('flutter_window 暴露 setOutsideClickOwner 方法并转调 setter', () {
      final String code = compactCode(flutterWindowSource);
      final int method = code.indexOf('method=="setOutsideClickOwner"');
      expect(method, greaterThanOrEqualTo(0));
      final int setter = code.indexOf(
        'win->SetOutsideClickConsumeOwner(',
        method,
      );
      expect(setter, greaterThan(method));
      expect(
        code
            .substring(method, setter + 120)
            .contains('Int64FromValue(args,"hwnd",0)'),
        isTrue,
        reason: '参数 {hwnd:int64}，0 = 清空',
      );
    });
  });

  group('runner: attached Shift+悬浮查词', () {
    test('hover timer 只读物理 Shift、命中经 tracker 去重、不进 shield 事务', () {
      final String header = compactCode(attachedHeader);
      expect(header.contains('#include"attached_hover_tracker.h"'), isTrue);
      expect(
        header.contains('boolhover=false;'),
        isTrue,
        reason: 'LookupEvent 必须带 hover 字段，序列化到 Dart',
      );
      expect(
        header.contains('fushi::AttachedHoverTrackerhover_tracker_;'),
        isTrue,
      );

      final String tick = compactCode(
        methodBody(
          attachedSource,
          'void AttachedTextSurfaceWindow::TickHoverLookup()',
        ),
      );
      expect(
        tick.contains('GetAsyncKeyState(VK_SHIFT)&0x8000'),
        isTrue,
        reason: '窗口 NOACTIVATE 从不收键盘消息，GetKeyState 永远不更新，只能问物理键态',
      );
      expect(tick.contains('GetKeyState('), isFalse);
      expect(tick.contains('hover_tracker_.Observe('), isTrue);
      expect(tick.contains('EmitLookupEvent(cluster,true)'), isTrue);
      for (final String forbidden in <String>[
        'AdoptShieldTransaction(',
        'BeginPointerGesture(',
        'publish_shield_probe_',
        'ArmLowLevelMouseHook',
        'SetCapture(',
      ]) {
        expect(
          tick.contains(forbidden),
          isFalse,
          reason: '悬浮不吞任何输入、不走 v19 shield 事务：$forbidden',
        );
      }

      final String source = compactCode(attachedSource);
      expect(
        source.contains(
          'if(wparam==kHoverTimerId){TickHoverLookup();return0;}',
        ),
        isTrue,
      );
      expect(source.contains('constexprUINTkHoverTimerMs=60;'), isTrue);
      expect(
        source.contains('SetTimer(hwnd_,kHoverTimerId,kHoverTimerMs,nullptr)'),
        isTrue,
      );
      expect(source.contains('KillTimer(hwnd_,kHoverTimerId);'), isTrue);

      final String gesture = compactCode(
        methodBody(
          attachedSource,
          'void AttachedTextSurfaceWindow::EndPointerGesture(',
        ),
      );
      expect(
        gesture.contains('EmitLookupEvent(pressed_cluster,false)'),
        isTrue,
        reason: '点击与悬浮共用同一份 LookupEvent 构造，字段不会漂开',
      );
    });

    test('hover 字段序列化 + tracker C++ 单测已注册进 runner 构建门', () {
      final String code = compactCode(flutterWindowSource);
      expect(
        code.contains(
          '{flutter::EncodableValue("hover"),flutter::EncodableValue(event.hover)}',
        ),
        isTrue,
      );
      expect(cmake.contains('"tests/attached_hover_tracker_test.cpp"'), isTrue);
      expect(
        cmake.contains(
          'add_dependencies(\${BINARY_NAME} fushi_windows_attached_hover_tracker_gate)',
        ),
        isTrue,
        reason: 'C++ 纯逻辑单测必须和其余 attached 守卫一样随每次 runner 构建执行',
      );
      expect(
        File(
          'windows/runner/tests/attached_hover_tracker_test.cpp',
        ).existsSync(),
        isTrue,
      );
    });
  });

  group('Dart: attached hit → lookupText 必带游戏 HWND', () {
    test('_onAttachedLookupText 传 hit.target.targetHwnd，浮窗路径不传', () {
      final String attached = compactCode(
        methodBody(
          overlayController,
          'Future<void> _onAttachedLookupText(GalAttachedLookupHitV19 hit)',
        ),
      );
      expect(
        attached.contains(
          'consumeOutsideClicksOwnerHwnd:hit.target.targetHwnd',
        ),
        isTrue,
      );
      final String onLookup = compactCode(
        methodBody(overlayController, 'Future<void> _onLookupText('),
      );
      expect(
        onLookup.contains('int?consumeOutsideClicksOwnerHwnd'),
        isTrue,
        reason: '可选参数：台词浮窗（C 表面）不传，行为不变',
      );
      expect(
        onLookup.contains(
          'consumeOutsideClicksOwnerHwnd:consumeOutsideClicksOwnerHwnd',
        ),
        isTrue,
        reason:
            '_onLookupText 必须把 owner 原样转给 GlobalLookupController.lookupText',
      );
      // 只有 attached 命中这一处把游戏 HWND 当 owner；浮窗 onLookupText 直接绑
      // _onLookupText，不带该参数。
      expect(
        'consumeOutsideClicksOwnerHwnd:hit.target.targetHwnd'
            .allMatches(compactCode(overlayController))
            .length,
        1,
      );
      expect(
        compactCode(overlayController).contains('onLookupText:_onLookupText,'),
        isTrue,
      );
    });

    test('_lookupExternal 在 hide 之后、showAt 之前设置 owner，且仅在非空时', () {
      final String external = compactCode(
        methodBody(lookupController, 'Future<bool> _lookupExternal('),
      );
      final int hide = external.indexOf(
        'GlobalLookupChannel.hide(notify:false)',
      );
      final int guard = external.indexOf(
        'if(consumeOutsideClicksOwnerHwnd!=null&&consumeOutsideClicksOwnerHwnd!=0){',
      );
      final int setOwner = external.indexOf(
        'GlobalLookupChannel.setOutsideClickOwner(consumeOutsideClicksOwnerHwnd,)',
      );
      final int showAt = external.indexOf('GlobalLookupChannel.showAt(');
      expect(hide, greaterThanOrEqualTo(0));
      expect(
        guard,
        greaterThan(hide),
        reason: 'native Hide 会清 owner，所以必须在那次 hide(notify:false) 之后再设',
      );
      expect(setOwner, greaterThan(guard));
      expect(
        showAt,
        greaterThan(setOwner),
        reason: 'owner 要在 showAt/reveal 之前到达 runner，RevealStack 才会同步吞点击 Arm',
      );
      expect(
        'setOutsideClickOwner('.allMatches(external).length,
        1,
        reason: '普通桌面查词（owner 为空）不发这条 channel——非 Windows 也走本控制器',
      );
      final String routed = compactCode(
        methodBody(lookupController, 'Future<bool> _lookupTextRouted('),
      );
      expect(
        routed.contains(
          'consumeOutsideClicksOwnerHwnd:consumeOutsideClicksOwnerHwnd',
        ),
        isTrue,
      );
    });
  });

  group('channel 契约', () {
    final List<MethodCall> calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.globalLookup, (
            MethodCall call,
          ) async {
            calls.add(call);
            return null;
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.globalLookup, null);
    });

    test('setOutsideClickOwner 走 global_lookup channel 且带 hwnd', () async {
      await GlobalLookupChannel.setOutsideClickOwner(0x1234);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setOutsideClickOwner');
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect(args['hwnd'], 0x1234);
      expect(args['source'], 'desktop');

      calls.clear();
      await OverlayWindowChannel(
        FushiChannels.globalLookup,
      ).setOutsideClickOwner(0);
      expect(calls.single.method, 'setOutsideClickOwner');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['hwnd'],
        0,
        reason: '0 = 清空',
      );
    });
  });
}

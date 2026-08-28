// BUG-1882 源码守卫：direct galCard 点游戏区域时，第一整个点击只关闭查词框，
// 不得穿透到游戏推进台词。
//
// 这是 Win32 WH_MOUSE_LL + WebView2 composition 的输入事务，Dart 测试无法伪造
// 系统级钩子；这里锁住可自动证明的最强结构：
//   ① direct galCard 上屏前先确认 HHOOK，再绑定游戏 HWND；桌面查词仍穿透；
//   ② popup 的真实窗口 region 内放行，只吞绑定游戏 HWND/子窗的客户区；
//   ③ down 先异步发关闭消息再吞，配对 up 即使发生在 Hide/Disarm 后也会吞；
//   ④ 长按超过延迟卸钩宽限期时不能卸钩，必须等配对 up。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String hookSource = File(
    'windows/runner/low_level_mouse_hook.cpp',
  ).readAsStringSync();
  final String hookHeader = File(
    'windows/runner/low_level_mouse_hook.h',
  ).readAsStringSync();
  final String windowSource = File(
    'windows/runner/global_lookup_window.cpp',
  ).readAsStringSync();
  final String windowHeader = File(
    'windows/runner/global_lookup_window.h',
  ).readAsStringSync();
  final String flutterWindowSource = File(
    'windows/runner/flutter_window.cpp',
  ).readAsStringSync();
  final String flutterWindowHeader = File(
    'windows/runner/flutter_window.h',
  ).readAsStringSync();
  final String ipcHeader = File(
    '../native/galgame_hook/include/voice_hook_ipc.h',
  ).readAsStringSync();
  final String sgreLookupHeader = File(
    '../native/galgame_hook/hook/adapters/sgre_lookup.h',
  ).readAsStringSync();
  final String sgreLookupSource = File(
    '../native/galgame_hook/hook/adapters/sgre_lookup.inc',
  ).readAsStringSync();
  final String siglusLookupSource = File(
    '../native/galgame_hook/hook/adapters/siglus_lookup.inc',
  ).readAsStringSync();
  final String leafAquaplusSource = File(
    '../native/galgame_hook/hook/adapters/leaf_aquaplus_adapter.inc',
  ).readAsStringSync();

  test('direct galCard 在首帧 Reveal 事务中绑定游戏，桌面 route 默认不吞', () {
    final String direct = methodBody(
      windowSource,
      'bool GlobalLookupWindow::RevealOverProcessClient(',
    );
    final String reveal = methodBody(
      windowSource,
      'void GlobalLookupWindow::Reveal(',
    );
    final String directCode = compactCode(direct);
    final String revealCode = compactCode(reveal);
    final String headerCode = compactCode(windowHeader);
    final String hookHeaderCode = compactCode(hookHeader);

    expect(
      directCode.contains('Reveal(screen_width,screen_height,false,game);'),
      isTrue,
      reason:
          '游戏 HWND 必须随首次 Reveal 一起 Arm；先按桌面模式 Arm、显示后再补绑'
          '会留下首帧点击穿透窗口',
    );
    final int coldArm = revealCode.indexOf(
      'ArmLowLevelMouseHookAndWait(hwnd_,consume_outside_owner)',
    );
    final int show = revealCode.indexOf('SetWindowPos(hwnd_,HWND_TOPMOST');
    final int desktopArm = revealCode.indexOf(
      'ArmLowLevelMouseHook(hwnd_);',
      show,
    );
    expect(coldArm, greaterThanOrEqualTo(0));
    expect(
      show,
      greaterThan(coldArm),
      reason: 'direct popup 上屏前必须收到专用钩子线程的安装确认',
    );
    expect(
      desktopArm,
      greaterThan(show),
      reason: '桌面 route 保持上屏后异步 Arm，不启用游戏点击消费策略',
    );
    expect(
      headerCode.contains('HWNDconsume_outside_owner=nullptr'),
      isTrue,
      reason: '普通桌面 Reveal 的默认值必须为空，维持点外关闭并把点击交给原应用',
    );
    expect(
      hookHeaderCode.contains('voidArmLowLevelMouseHook(HWNDtarget);') &&
          hookHeaderCode.contains(
            'boolArmLowLevelMouseHookAndWait(HWNDtarget,HWNDconsume_outside_owner);',
          ),
      isTrue,
      reason: '桌面穿透 API 与 direct 等待/消费 API 必须显式分离',
    );
  });

  test('cold arm 与上屏均成功后才维持 target，失败让 direct presenter 降级', () {
    final String armAndWait = compactCode(
      methodBody(hookSource, 'bool ArmLowLevelMouseHookAndWait('),
    );
    final String threadMain = compactCode(
      methodBody(hookSource, 'void HookThreadMain()'),
    );
    final String reveal = compactCode(
      methodBody(windowSource, 'void GlobalLookupWindow::Reveal('),
    );

    final int request = armAndWait.indexOf(
      'g_arm_requested_generation.fetch_add(',
    );
    final int post = armAndWait.indexOf(
      'PostThreadMessage(thread_id,kThreadArm,generation,0)',
    );
    final int wait = armAndWait.indexOf('WaitForSingleObject(');
    final int active = armAndWait.indexOf('g_hook_active.load(');
    final int publish = armAndWait.indexOf('g_target.store(target');
    expect(request, greaterThanOrEqualTo(0));
    expect(post, greaterThan(request));
    expect(wait, greaterThan(post));
    expect(active, greaterThan(wait));
    expect(
      publish,
      greaterThan(active),
      reason: 'HHOOK 未确认成功时绝不能发布可消费的 direct target',
    );
    expect(
      armAndWait.contains('kArmAckTimeoutMs'),
      isTrue,
      reason: '安装确认必须有界，不能把 platform 线程无限挂住',
    );

    final int install = threadMain.indexOf('SetWindowsHookEx(WH_MOUSE_LL');
    expect(
      threadMain.contains('ack_generation=static_cast<uint32_t>(msg.wParam)'),
      isTrue,
      reason: '陈旧 async Arm 不能借读全局 requested generation 冒充本次同步 ack',
    );
    final int freshness = threadMain.indexOf(
      'now-callback_tick>kSynchronousArmFreshnessMs',
    );
    final int acknowledge = threadMain.indexOf(
      'g_arm_applied_generation.store(',
      install,
    );
    final int signal = threadMain.indexOf(
      'SetEvent(g_arm_applied_event)',
      install,
    );
    expect(
      freshness,
      greaterThanOrEqualTo(0),
      reason: 'Windows 静默摘钩后 HHOOK 仍非空；同步确认前必须淘汰无近期回调的陈旧句柄',
    );
    expect(
      threadMain.contains(
        'ack_generation!=0&&hook!=nullptr&&!has_pending_button',
      ),
      isTrue,
      reason: '已有被吞 down 等待 up 时不得重装 HHOOK，避免卸装缝隙把配对 up 漏给游戏',
    );
    expect(acknowledge, greaterThan(install));
    expect(signal, greaterThan(acknowledge));
    expect(
      reveal.contains(
        'if(!fushi::ArmLowLevelMouseHookAndWait(hwnd_,consume_outside_owner))',
      ),
      isTrue,
      reason: '安装失败必须 return 给 RevealOverProcessClient 触发既有 fallback',
    );
    final int show = reveal.indexOf('if(!SetWindowPos(hwnd_,HWND_TOPMOST');
    final int showWindow = reveal.indexOf('ShowWindow(hwnd_', show);
    expect(show, greaterThanOrEqualTo(0));
    expect(showWindow, greaterThan(show));
    final String failedShow = reveal.substring(show, showWindow);
    expect(
      failedShow.contains('fushi::DisarmLowLevelMouseHook(hwnd_)') &&
          failedShow.contains('mouse_hook_armed_=false') &&
          failedShow.contains('revealed_=false') &&
          failedShow.contains('visible_=false') &&
          failedShow.contains('return;'),
      isTrue,
      reason: '上屏失败必须撤销刚发布的游戏绑定，不能留下不可见却吞点击的 HWND',
    );
  });

  test('只吞 popup 外且真实命中绑定游戏客户区的 down', () {
    final String predicate = compactCode(
      methodBody(hookSource, 'bool ShouldConsumeGameClientClick('),
    );

    expect(predicate.contains('game==nullptr||!IsWindow(game)'), isTrue);
    expect(
      predicate.contains('PointInWindowClient(game,point)'),
      isTrue,
      reason: '标题栏、边框和任务栏等非游戏客户区不得被吞',
    );
    expect(predicate.contains('WindowFromPoint(point)'), isFalse);
    expect(
      predicate.contains('hit==target||(hit!=nullptr&&IsChild(target,hit))'),
      isTrue,
      reason: 'popup/WebView 子窗内的点击必须放行，按钮和嵌套查词才能工作',
    );
    expect(
      predicate.contains('hit==game||IsChild(game,hit)'),
      isTrue,
      reason: '不能只按 PID 或屏幕矩形吞；同进程其他窗口及覆盖其上的应用要放行',
    );
    expect(
      predicate.contains('GetForegroundWindow()==game'),
      isTrue,
      reason: '游戏失焦时用于切回游戏的第一次点击不能被误吞',
    );

    final String hookProc = compactCode(
      methodBody(hookSource, 'LRESULT CALLBACK HookProc('),
    );
    final String directArm = compactCode(
      methodBody(hookSource, 'bool ArmLowLevelMouseHookAndWait('),
    );
    final String desktopArm = compactCode(
      methodBody(hookSource, 'void ArmLowLevelMouseHook('),
    );
    final int targetSnapshot = hookProc.indexOf('g_target.load(');
    final int ownerForTarget = hookProc.indexOf(
      'GetPropW(target,kConsumeOutsideOwnerProperty)',
    );
    final int pointSnapshot = hookProc.indexOf('WindowFromPoint(info->pt)');
    final int insideFromSnapshot = hookProc.indexOf('point_window==target');
    final int consumeFromSnapshot = hookProc.indexOf(
      'ShouldConsumeGameClientClick(target,consume_owner,point_window,info->pt)',
    );
    expect(
      ownerForTarget,
      greaterThan(targetSnapshot),
      reason: 'owner 必须从已取到的同一个 target HWND 读取，不能用第二个独立 atomic',
    );
    expect(pointSnapshot, greaterThan(targetSnapshot));
    expect(
      insideFromSnapshot,
      greaterThan(pointSnapshot),
      reason: '圆角和卡间透明区必须按真实 HRGN 命中，不能按 HWND 包围矩形算 inside',
    );
    expect(
      consumeFromSnapshot,
      greaterThan(insideFromSnapshot),
      reason: '通知窗口线程与吞游戏点击必须复用同一次 WindowFromPoint 快照',
    );
    expect(hookProc.contains('GetWindowRect(target'), isFalse);
    expect(hookSource.contains('g_consume_outside_owner'), isFalse);
    final int barrierWait = directArm.indexOf('WaitForSingleObject(');
    final int bindOwner = directArm.indexOf(
      'SetPropW(target,kConsumeOutsideOwnerProperty',
    );
    final int publishTarget = directArm.indexOf('g_target.store(target');
    expect(
      bindOwner,
      greaterThan(barrierWait),
      reason: '替换复用 HWND 的 owner 前必须等 hook-thread barrier，排空已取旧 target 的回调',
    );
    expect(
      publishTarget,
      greaterThan(bindOwner),
      reason: 'direct owner 属性必须先绑定到专用 HWND，再发布 target',
    );
    expect(
      desktopArm.contains('kConsumeOutsideOwnerProperty'),
      isFalse,
      reason: '桌面/global 使用独立 HWND；异步 Arm 不得无 barrier 改 direct 属性',
    );
    final String ensureGalCard = compactCode(
      methodBody(
        flutterWindowSource,
        'GlobalLookupWindow* FlutterWindow::EnsureGalLookupCardWindow()',
      ),
    );
    final String flutterHeader = compactCode(flutterWindowHeader);
    expect(
      ensureGalCard.contains(
            'gal_lookup_card_window_=std::make_unique<GlobalLookupWindow>()',
          ) &&
          ensureGalCard.contains('returngal_lookup_card_window_.get()') &&
          !ensureGalCard.contains('returnglobal_lookup_window_.get()'),
      isTrue,
      reason: 'direct property 能留在 HWND 上的前提是 galCard 永远使用专用窗口实例',
    );
    expect(
      flutterHeader.contains(
            'std::unique_ptr<GlobalLookupWindow>global_lookup_window_;',
          ) &&
          flutterHeader.contains(
            'std::unique_ptr<GlobalLookupWindow>gal_lookup_card_window_;',
          ),
      isTrue,
      reason: '桌面与游戏查词必须保持两个独立 GlobalLookupWindow/HWND',
    );
  });

  test('down 先通知关闭再吞，Hide 后的配对 up 仍在 target 闸门前吞', () {
    final String hookProc = compactCode(
      methodBody(hookSource, 'LRESULT CALLBACK HookProc('),
    );
    final String buttonMap = compactCode(
      methodBody(hookSource, 'uint32_t ButtonBitForMessage('),
    );
    final String downMap = compactCode(
      methodBody(hookSource, 'bool IsButtonDownMessage('),
    );
    final String upMap = compactCode(
      methodBody(hookSource, 'bool IsButtonUpMessage('),
    );

    expect(downMap.contains('WM_LBUTTONDOWN'), isTrue);
    expect(downMap.contains('WM_RBUTTONDOWN'), isTrue);
    expect(upMap.contains('WM_LBUTTONUP'), isTrue);
    expect(upMap.contains('WM_RBUTTONUP'), isTrue);
    expect(buttonMap.contains('kSwallowedLeftButton'), isTrue);
    expect(buttonMap.contains('kSwallowedRightButton'), isTrue);
    expect(hookProc.contains('IsButtonDownMessage(wparam)'), isTrue);
    expect(hookProc.contains('IsButtonUpMessage(wparam)'), isTrue);

    final int upGate = hookProc.indexOf('g_swallowed_buttons.fetch_and(');
    final int staleDownReset = hookProc.indexOf(
      'g_swallowed_buttons.fetch_and(~bit',
      upGate + 1,
    );
    final int targetGate = hookProc.indexOf('g_target.load(');
    expect(upGate, greaterThanOrEqualTo(0));
    expect(
      targetGate,
      greaterThan(upGate),
      reason: 'Hide 会先清 target；up 的事务位必须在 target 提前返回之前检查',
    );
    expect(
      staleDownReset,
      inInclusiveRange(upGate + 1, targetGate - 1),
      reason: '新 down 必须先清同键丢失 up 的陈旧事务位，避免误吞新的正常 up',
    );

    final int postDismiss = hookProc.indexOf(
      'PostMessage(target,kLowLevelMouseClickMessage',
    );
    final int decideDown = hookProc.indexOf('constboolconsume_click=');
    final int markDown = hookProc.indexOf(
      'g_swallowed_buttons.fetch_or(',
      decideDown,
    );
    final int swallowDown = hookProc.indexOf('return1;', markDown);
    expect(decideDown, greaterThanOrEqualTo(0));
    expect(markDown, greaterThan(decideDown));
    expect(postDismiss, greaterThanOrEqualTo(0));
    expect(
      postDismiss,
      greaterThan(markDown),
      reason: '必须先冻结 down/up 事务再投递关闭；否则 Hide/Disarm 可能抢先清掉游戏绑定',
    );
    expect(
      swallowDown,
      greaterThan(postDismiss),
      reason: '关闭通知必须在 return 1 吞掉 down 之前异步投递',
    );
  });

  test('Disarm 不丢配对状态，长按超过宽限期也不卸钩', () {
    final String disarm = compactCode(
      methodBody(hookSource, 'void DisarmLowLevelMouseHook('),
    );
    final String threadMain = compactCode(
      methodBody(hookSource, 'void HookThreadMain()'),
    );
    final String reconcile = compactCode(
      methodBody(
        hookSource,
        'uint32_t ReconcileSwallowedButtonsWithPhysicalState()',
      ),
    );

    expect(
      disarm.contains('g_swallowed_buttons.store('),
      isFalse,
      reason: 'down 后的 Hide/Disarm 不能清事务位，否则随后 up 会漏给游戏',
    );
    expect(reconcile.contains('GetAsyncKeyState(VK_LBUTTON)'), isTrue);
    expect(reconcile.contains('GetAsyncKeyState(VK_RBUTTON)'), isTrue);
    expect(
      reconcile.contains('g_swallowed_buttons.fetch_and(still_held'),
      isTrue,
      reason: '丢失 up 只能按当前物理状态清残留，不能无条件清真实长按',
    );

    final int armBranch = threadMain.indexOf('msg.message==kThreadArm');
    final int livenessBranch = threadMain.indexOf(
      'msg.message==WM_TIMER&&liveness_timer',
      armBranch,
    );
    final String armCode = threadMain.substring(armBranch, livenessBranch);
    expect(
      armCode.contains('ReconcileSwallowedButtonsWithPhysicalState()'),
      isFalse,
      reason: 're-arm 时物理键可能已 up、但 WH_MOUSE_LL up 仍在队列；立即收敛会让该 up 漏给游戏',
    );
    expect(
      armCode.contains(
        'g_swallowed_buttons.load(std::memory_order_relaxed)!=0',
      ),
      isTrue,
      reason: 're-arm 只读 pending 位来保留/创建宽限期 timer',
    );
    expect(
      armCode.contains('disarm_timer!=0&&!has_pending_button'),
      isTrue,
      reason: '真实长按仍 pending 时 re-arm 不得 Kill 清理/保活 timer',
    );

    final int pending = threadMain.lastIndexOf(
      'ReconcileSwallowedButtonsWithPhysicalState()',
    );
    final int unhook = threadMain.indexOf('UnhookWindowsHookEx(hook)', pending);
    expect(pending, greaterThanOrEqualTo(0));
    expect(
      threadMain.indexOf('SetTimer(nullptr,0,kDisarmGraceMs,nullptr)', pending),
      inInclusiveRange(pending, unhook - 1),
      reason: '仍有按键等待 up 时必须重新排检查，而不是到期直接卸钩',
    );
    expect(unhook, greaterThan(pending));
  });

  test('SGRE direct route 以精确 DirectInput mouse detour 屏蔽按钮并锁存到 up', () {
    final String shared = compactCode(ipcHeader);
    final String nativeHeader = compactCode(sgreLookupHeader);
    final String install = compactCode(
      methodBody(sgreLookupSource, 'bool InstallSgreDirectInputShield()'),
    );
    final String detour = compactCode(
      methodBody(
        sgreLookupSource,
        'HRESULT STDMETHODCALLTYPE SgreGetDeviceStateDetour(',
      ),
    );
    final String readyRead = compactCode(
      methodBody(
        sgreLookupSource,
        'bool IsSgreDirectInputShieldReadyPublished(',
      ),
    );
    final String validPopup = compactCode(
      methodBody(
        sgreLookupSource,
        'HWND GetValidPublishedSgreDirectInputShieldPopup(',
      ),
    );
    final String readyPublish = compactCode(
      methodBody(sgreLookupSource, 'bool PublishSgreDirectInputShieldReady()'),
    );
    final String refreshWindow = compactCode(
      methodBody(
        sgreLookupSource,
        'bool RefreshSgreDirectInputPropertyWindow()',
      ),
    );
    final String filter = compactCode(
      methodBody(
        sgreLookupHeader,
        'inline uint8_t FilterSgreDirectInputMouseButtons(',
      ),
    );

    expect(
      shared.contains('Fushi.SGRE.DirectInputShield.Required') &&
          shared.contains('Fushi.SGRE.DirectInputShield.Ready') &&
          shared.contains('Fushi.SGRE.DirectInputShield.Window'),
      isTrue,
      reason: 'host/helper 的跨进程属性名必须只有 IPC 头这一份真值',
    );
    expect(
      nativeHeader.contains('kSgreDirectInputMouseDeviceRva=0xA96E18u') &&
          nativeHeader.contains(
            'kSgreDirectInputGetDeviceStateVtableIndex=9u',
          ) &&
          nativeHeader.contains('kSgreDirectInputMouseStateBytes=20u') &&
          nativeHeader.contains('kSgreDirectInputMouseButtonsOffset=12u'),
      isTrue,
      reason: '只能使用已由 admitted SGRE binary 证明的 mouse slot / DIMOUSESTATE2 ABI',
    );
    expect(install.contains('kSgreDirectInputMouseDeviceRva'), isTrue);
    expect(
      install.contains('VtableSlot(mouse_device,') &&
          install.contains('kSgreDirectInputGetDeviceStateVtableIndex'),
      isTrue,
    );
    expect(
      install.contains('if(g_sgre_get_device_state_target==nullptr)') &&
          install.contains('HookFn(target,') &&
          install.contains('g_sgre_get_device_state_original==nullptr') &&
          install.indexOf('g_sgre_get_device_state_target=target') >
              install.indexOf('HookFn(target,'),
      isTrue,
      reason: '只有 HookFn 与 trampoline 都成功后才能提交 enabled target/Ready',
    );
    expect(
      readyPublish.contains('g_sgre_direct_input_game_window.store(game') &&
          readyPublish.contains('SetPropW(game,') &&
          readyPublish.indexOf('g_sgre_direct_input_game_window.store(game') <
              readyPublish.indexOf('SetPropW(game,'),
      isTrue,
      reason: 'injected cache 必须先发布，Ready 属性是 host 可见的最后 commit',
    );
    expect(
      install.contains('kSgreDirectInputHealthIntervalMs') &&
          refreshWindow.contains('FindGameMainWindow()') &&
          refreshWindow.contains('current==previous') &&
          refreshWindow.contains('kSgreDirectInputShieldRequiredProperty'),
      isTrue,
      reason: '16ms 快路不枚举窗口，但 1s health 必须迁移重建后的 SGRE 主 HWND',
    );
    expect(
      detour.contains('constHRESULTresult=original(') &&
          detour.contains('device!=g_sgre_mouse_device.load(') &&
          detour.contains(
            'state_bytes!=fushi_voice_hook::kSgreDirectInputMouseStateBytes',
          ) &&
          detour.contains('FilterSgreDirectInputMouseButtons(') &&
          detour.contains(
            'g_sgre_direct_input_latched_buttons.compare_exchange_weak(',
          ),
      isTrue,
      reason: '必须先取 raw state，再只处理精确 mouse self + 20-byte 状态',
    );
    expect(
      readyRead.contains('kSgreDirectInputShieldReadyProperty') &&
          detour.contains(
            'GetValidPublishedSgreDirectInputShieldPopup(game)',
          ) &&
          validPopup.contains('GetWindow(popup,GW_OWNER)!=game') &&
          validPopup.contains('FushiGlobalLookupWindow'),
      isTrue,
      reason: '陈旧/伪造 HWND 不得让游戏永久进入输入屏蔽',
    );
    // 判据必须取自 detour **实际**用的表达式。此前这条断言取的是
    // IsPublishedSgreDirectInputShieldActive 的函数体，而 detour 早已改成只看
    // Window 属性、不再调它——函数零调用者、守卫恒绿，握手被静默拆掉也发现不了。
    expect(
      detour.contains(
        'constbooldirect_shield=direct_popup!=nullptr&&'
        'IsSgreDirectInputShieldReadyPublished(game);',
      ),
      isTrue,
      reason: 'direct route 的屏蔽必须过 Ready 握手，不能只看 Window 属性在不在',
    );
    expect(
      detour.contains(
        'constboolshield_active=direct_shield||bitmap_popup_visible;',
      ),
      isTrue,
      reason:
          'bitmap route 是注入侧自绘卡，进程内可见性即全部真相；'
          '两条 route 的语义不同，不得折成「有没有卡」一问',
    );
    expect(
      filter.contains('kSgreDirectInputMouseButtonsOffset+index') &&
          filter.contains('state[offset]=0') &&
          filter.contains('if(!down)latched_buttons&='),
      isTrue,
      reason: '轴必须保持原值；被屏蔽的 down 必须一直锁存到 raw up',
    );
  });

  test(
    'Siglus direct WebView 以 Required/Ready/Window 屏蔽 GetKeyState 到 matching up',
    () {
      final String shared = compactCode(ipcHeader);
      final String install = compactCode(
        methodBody(siglusLookupSource, 'bool InstallSiglusLookupSensor()'),
      );
      final String detour = compactCode(
        methodBody(
          siglusLookupSource,
          'SHORT WINAPI Detour_SiglusGetKeyState(',
        ),
      );
      final String messageDetour = compactCode(
        methodBody(
          siglusLookupSource,
          'void __stdcall Detour_SiglusInputMessage(',
        ),
      );
      final String readyPublish = compactCode(
        methodBody(
          siglusLookupSource,
          'bool PublishSiglusSampledInputShieldReady()',
        ),
      );
      final String validPopup = compactCode(
        methodBody(
          siglusLookupSource,
          'HWND GetValidPublishedSiglusSampledInputShieldPopup(',
        ),
      );
      final String tick = compactCode(
        methodBody(siglusLookupSource, 'void ProcessSiglusLookupTick()'),
      );

      expect(
        shared.contains('Fushi.Siglus.SampledInputShield.Required') &&
            shared.contains('Fushi.Siglus.SampledInputShield.Ready') &&
            shared.contains('Fushi.Siglus.SampledInputShield.Window'),
        isTrue,
        reason: 'Siglus 与 SGRE ABI 不同，属性命名必须独立但共享同一事务形状',
      );
      expect(
        install.contains('PublishSiglusSampledInputShieldRequired()') &&
            install.contains('HookFn(target,') &&
            install.contains('PublishSiglusSampledInputShieldReady()') &&
            install.indexOf('PublishSiglusSampledInputShieldRequired()') <
                install.indexOf('HookFn(target,') &&
            install.indexOf('PublishSiglusSampledInputShieldReady()') >
                install.lastIndexOf('HookFn(target,'),
        isTrue,
        reason: 'Required 先声明 fail-closed，三个 exact hook 就绪后 Ready 才能最后提交',
      );
      expect(
        readyPublish.contains(
              'g_siglus_sampled_input_game_window.store(game',
            ) &&
            readyPublish.contains('SetPropW(') &&
            readyPublish.indexOf(
                  'g_siglus_sampled_input_game_window.store(game',
                ) <
                readyPublish.indexOf('SetPropW('),
        isTrue,
        reason: 'detour 的 game cache 必须先于跨进程 Ready commit 可见',
      );
      expect(
        validPopup.contains('GetWindow(popup,GW_OWNER)!=game') &&
            validPopup.contains('FushiGlobalLookupWindow'),
        isTrue,
        reason: '陈旧或伪造 popup HWND 不得屏蔽游戏输入',
      );
      expect(
        detour.contains(
              'GetValidPublishedSiglusSampledInputShieldPopup(published_game)',
            ) &&
            detour.contains(
              'IsSiglusSampledInputShieldReadyPublished(published_game)',
            ) &&
            detour.contains(
              'constboolpopup_shield=direct_shield||bitmap_popup_visible;',
            ) &&
            detour.contains(
              'AdvanceSiglusLookupClickSample(button_down,popup_shield,',
            ),
        isTrue,
        reason: 'direct WebView 与 bitmap fallback 都必须进入既有完整 click owner 状态机',
      );
      final int popupShield = detour.indexOf(
        'constboolpopup_shield=direct_shield||bitmap_popup_visible;',
      );
      final int exactPollerGate = detour.indexOf('if(!admitted_lookup_poller)');
      expect(popupShield, greaterThanOrEqualTo(0));
      expect(exactPollerGate, greaterThan(popupShield));
      expect(
        detour.contains('g_siglus_lookup_left_button_filter_latched.load(') &&
            detour.contains(
              'FilterSiglusLookupGetKeyState('
              'raw,popup_shield||lookup_press_latched)',
            ) &&
            detour.contains(
              'if(decision.consume){'
              'g_siglus_lookup_left_button_filter_latched.store(true',
            ) &&
            detour.contains(
              'if(!button_down){'
              'g_siglus_lookup_left_button_filter_latched.store(false',
            ),
        isTrue,
        reason:
            'Siglus 的其它 VK_LBUTTON 消费点必须在 exact poller 早退之前看见 WebView shield；'
            '正文命中的 down 也必须跨 caller 锁存到 exact raw up',
      );
      expect(
        install.contains('profile->input_message_rva') &&
            install.contains('MatchesSiglusInputMessageEntry(target)') &&
            install.contains('Detour_SiglusInputMessage') &&
            install.contains('g_orig_SiglusInputMessage==nullptr'),
        isTrue,
        reason: 'Ready 前必须安装 Siglus 自己的 WM_LBUTTON 剧情边沿写入点',
      );
      expect(
        messageDetour.contains(
              'return_address-module!='
              'profile->main_input_message_return_rva',
            ) &&
            messageDetour.contains('DecideSiglusLookupMouseMessage(') &&
            messageDetour.contains(
              'g_siglus_lookup_message_left_button_latched.store(',
            ) &&
            messageDetour.contains(
              'if(decision.consume){'
              'g_siglus_lookup_left_button_filter_latched.store(true',
            ) &&
            messageDetour.contains('return;}original(message,wparam,lparam);'),
        isTrue,
        reason:
            '只允许主 HWND 的 exact caller 吞正文/弹窗事务；'
            '命中后 DOWN 到 matching UP 都不能写入游戏的剧情推进状态',
      );
      expect(
        tick.contains('constboolpopup_visible=') &&
            tick.contains('direct_popup_visible') &&
            tick.contains('if(!popup_visible)') &&
            tick.contains('||popup_visible||!game_point'),
        isTrue,
        reason: 'WebView 显示期间不能继续发布正文 click target 或接受 Shift 新查词',
      );
    },
  );

  test('Fushi 只在 helper ready 后发布 popup HWND，Hide/down-up 生命周期不 ABA', () {
    final String directPublish = compactCode(
      methodBody(hookSource, 'bool PublishDirectInputShieldIfReady('),
    );
    final String directArm = compactCode(
      methodBody(hookSource, 'bool ArmLowLevelMouseHookAndWait('),
    );
    final String desktopArm = compactCode(
      methodBody(hookSource, 'void ArmLowLevelMouseHook('),
    );
    final String disarm = compactCode(
      methodBody(hookSource, 'void DisarmLowLevelMouseHook('),
    );
    final String finalize = compactCode(
      methodBody(hookSource, 'void FinalizeLowLevelMouseDirectInputShield('),
    );
    final String hookProc = compactCode(
      methodBody(hookSource, 'LRESULT CALLBACK HookProc('),
    );
    final String requestFinalize = compactCode(
      methodBody(hookSource, 'void RequestDirectInputShieldFinalize()'),
    );
    final String revoke = compactCode(
      methodBody(hookSource, 'void RevokeDirectInputShieldIfIdle('),
    );
    final String abortInvalid = compactCode(
      methodBody(
        hookSource,
        'void AbortInvalidDirectInputShieldAfterBarrier()',
      ),
    );
    final String leafRevoke = compactCode(
      methodBody(leafAquaplusSource, 'void RevokeLeafSampledInputShieldReady('),
    );
    final String publishTail = compactCode(
      methodBody(hookSource, 'bool PublishSampledInputTailRequest('),
    );
    final String refreshTail = compactCode(
      methodBody(hookSource, 'void RefreshSampledInputTailAck('),
    );
    const String leafContractDeclaration =
        'constexpr SampledInputShieldContract '
        'kLeafAquaplusSampledInputShieldContract =';
    final int leafContractStart = hookSource.indexOf(leafContractDeclaration);
    final int leafContractEnd = hookSource.indexOf('};', leafContractStart);
    expect(leafContractStart, greaterThanOrEqualTo(0));
    expect(leafContractEnd, greaterThan(leafContractStart));
    final String leafContract = compactCode(
      hookSource.substring(leafContractStart, leafContractEnd),
    );
    final String barrier = compactCode(
      methodBody(
        hookSource,
        'HookThreadBarrierResult WaitForHookThreadBarrier(',
      ),
    );
    final String windowMessage = compactCode(
      methodBody(windowSource, 'LRESULT GlobalLookupWindow::HandleMessage('),
    );

    expect(
      hookSource.contains('kSgreSampledInputShieldContract') &&
          hookSource.contains('kSiglusSampledInputShieldContract') &&
          hookSource.contains('kLeafAquaplusSampledInputShieldContract') &&
          directPublish.contains('SelectSampledInputShieldContract(') &&
          directPublish.contains('SetPropW(game,contract->window_property') &&
          directPublish.contains(
            'IsSelectedSampledInputShieldContractReady(game,contract)',
          ) &&
          directPublish.contains('GetPropW(game,contract->window_property)') &&
          directPublish.contains('returnfalse;'),
      isTrue,
      reason:
          'SGRE/Siglus/Leaf 任一声明的 sampled-input 契约不完整或 SetProp 失败时，'
          '必须在 popup 上屏前 fail closed',
    );
    expect(
      leafContract.contains(
            'kLeafAquaplusSampledInputShieldTailRequestProperty',
          ) &&
          leafContract.contains(
            'kLeafAquaplusSampledInputShieldTailAckProperty',
          ) &&
          !leafContract.contains('nullptr'),
      isTrue,
      reason:
          'Leaf sampled-input 契约必须声明非空 TailRequest/TailAck；退化成 '
          'SGRE/Siglus 的无 tail 初始化会重新暴露两次轮询之间的完整快点',
    );
    expect(
      publishTail.contains('LeafAquaplusSampledInputTailButtons(previous)') &&
          publishTail.contains(
            'MakeLeafAquaplusSampledInputTailToken(generation,buttons)',
          ) &&
          publishTail.indexOf('SetPropW(game,contract->tail_request_property') <
              publishTail.indexOf(
                'g_direct_input_shield_tail_token.store(token',
              ) &&
          refreshTail.contains('if(ack!=token)return;') &&
          refreshTail.contains(
            'g_direct_input_shield_tail_token.compare_exchange_strong(',
          ) &&
          !refreshTail.contains('RemovePropW'),
      isTrue,
      reason:
          'Leaf tail token 必须合并未确认按钮、先跨进程发布再取得本地所有权，且只由'
          '精确 generation Ack 清零；陈旧 Ack 或回调并发不能提前撤销新事务',
    );
    expect(
      directPublish.contains('(pending!=0||pending_tail!=0)') &&
          directPublish.contains(
            'HasSampledInputTailHandshake(contract)&&pending_tail==0',
          ) &&
          revoke.contains('RefreshSampledInputTailAck(game,contract)') &&
          revoke.contains(
            'g_direct_input_shield_tail_token.load(std::memory_order_acquire)!=0',
          ),
      isTrue,
      reason:
          '未收到精确 Ack 的 Leaf tail 必须跨 Hide 保留，并阻止另一 popup 复用 publication；'
          '只有 pending_tail 已清零才可清理跨进程属性',
    );
    final int publish = directArm.indexOf(
      'PublishDirectInputShieldIfReady(target,consume_outside_owner)',
    );
    final int abortStale = directArm.indexOf(
      'AbortInvalidDirectInputShieldAfterBarrier()',
    );
    final int exposeTarget = directArm.indexOf('g_target.store(target');
    expect(publish, greaterThanOrEqualTo(0));
    expect(abortStale, greaterThanOrEqualTo(0));
    expect(publish, greaterThan(abortStale));
    expect(exposeTarget, greaterThan(publish));
    expect(
      desktopArm.contains('PublishDirectInputShieldIfReady'),
      isFalse,
      reason: '桌面/global 查词不得启用 SGRE 输入盾',
    );
    expect(
      hookProc.contains('g_direct_input_shield_buttons.fetch_or(bit') &&
          hookProc.contains('RequestDirectInputShieldFinalize()'),
      isTrue,
      reason: 'popup 内外 down 都需从 DirectInput 隐藏；up 只投递串行撤销消息',
    );
    final int tailPublish = hookProc.indexOf(
      'constbooltail_published=PublishSampledInputTailRequest(',
    );
    final int clickDispatch = hookProc.indexOf(
      'PostMessage(target,kLowLevelMouseClickMessage',
    );
    expect(tailPublish, greaterThanOrEqualTo(0));
    expect(clickDispatch, greaterThan(tailPublish));
    expect(
      hookProc.contains(
        'if(!tail_published){g_swallowed_buttons.fetch_or('
        'bit,std::memory_order_relaxed);return1;}',
      ),
      isTrue,
      reason:
          'Leaf TailRequest 发布失败时不得把 down 交给 WebView 或 dismiss：必须吞掉'
          '整次事务并保留 popup，避免完整快点落在两次游戏轮询之间后穿透',
    );
    expect(
      hookProc.contains(
        'g_swallowed_buttons.fetch_and(~bit,std::memory_order_relaxed);'
        'constuint32_tstale_shield=g_direct_input_shield_buttons.fetch_and('
        '~bit,std::memory_order_relaxed);',
      ),
      isTrue,
      reason:
          '同一物理键的新 down 必须同时丢掉两套位集合里的陈旧位。只清 '
          'g_swallowed_buttons 时，丢失的 up 会把 shield 位一直卡着，下一个浮窗的 '
          'PublishDirectInputShieldIfReady 因 pending!=0 且 popup 变了而 '
          'fail-closed，游戏内查词要等 3s 物理状态对账才恢复',
    );
    expect(
      disarm.contains('current==expected_target') &&
          disarm.contains(
            'WaitForHookThreadBarrier(thread_id,expected_target)',
          ) &&
          disarm.contains('RevokeDirectInputShieldIfIdle(expected_target)') &&
          barrier.contains('PostThreadMessage(thread_id,kThreadBarrier'),
      isTrue,
      reason: 'Hide 撤 publication 前必须排空已读取旧 target 的 hook callback',
    );
    expect(
      barrier.contains('returnHookThreadBarrierResult::kNotQueued;') &&
          barrier.contains('returnHookThreadBarrierResult::kQueuedPending;') &&
          barrier.contains('returnHookThreadBarrierResult::kCrossed;') &&
          disarm.contains('barrier!=HookThreadBarrierResult::kQueuedPending'),
      isTrue,
      reason:
          '「屏障消息压根没投出去」与「投了但同步等待超时」是两件事：只有后者最终'
          '会被处理并自己投递延迟收尾。折成同一个 false 时，前者会让游戏窗口上的'
          'kSgreDirectInputShieldWindowProperty 永久留着，游戏的 DirectInput '
          '立即状态被一直压制',
    );
    expect(
      barrier.split('HookThreadBarrierResult::kNotQueued').length - 1,
      2,
      reason: '没有钩子线程、以及 PostThreadMessage 失败，都属于「从未排队」',
    );
    expect(
      abortInvalid.contains(
            'IsSelectedSampledInputShieldContractReady(game,contract)',
          ) &&
          abortInvalid.contains(
            'GetPropW(game,contract->window_property))==popup',
          ) &&
          abortInvalid.contains(
            'GetPropW(game,contract->tail_request_property)))==token',
          ) &&
          abortInvalid.contains('g_direct_input_shield_tail_token.store(0') &&
          disarm.contains(
            'barrier==HookThreadBarrierResult::kCrossed)'
            '{AbortInvalidDirectInputShieldAfterBarrier();',
          ),
      isTrue,
      reason:
          'helper/game/window 失效后，只有跨过 callback barrier 才能取消永远不会再获真 Ack '
          '的 Leaf tail；跨进程属性必须按本地 token 精确删除，不能误删新事务',
    );
    final int leafReadyRevoke = leafRevoke.indexOf(
      'kLeafAquaplusSampledInputShieldReadyProperty',
    );
    final int leafWindowRevoke = leafRevoke.indexOf(
      'kLeafAquaplusSampledInputShieldWindowProperty',
    );
    expect(leafReadyRevoke, greaterThanOrEqualTo(0));
    expect(leafWindowRevoke, greaterThan(leafReadyRevoke));
    expect(
      requestFinalize.contains(
            'g_target.load(std::memory_order_acquire)!=popup',
          ) &&
          revoke.contains('g_target.load(std::memory_order_acquire)==popup') &&
          !revoke.contains('g_target.load(std::memory_order_acquire)!=nullptr'),
      isTrue,
      reason: '另一个 desktop/global target 不能阻止旧 gal publication 撤销',
    );
    expect(
      finalize.contains('g_binding_mutex') &&
          finalize.contains('RevokeDirectInputShieldIfIdle(target)'),
      isTrue,
      reason: '旧 up 的 publication 撤销必须回窗口线程与下一次 Reveal 串行',
    );
    expect(
      windowMessage.contains('kLowLevelMouseShieldReleaseMessage') &&
          windowMessage.contains(
            'FinalizeLowLevelMouseDirectInputShield(hwnd_)',
          ),
      isTrue,
    );
  });
}

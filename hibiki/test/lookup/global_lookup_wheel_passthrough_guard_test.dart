// BUG-1166 源码守卫：galgame 上查词，滚轮**不许**同时喂给游戏。
//
// 查词卡是 WS_EX_NOACTIVATE 的非激活窗（design §5 保证 3 — 查词不动前台程序的
// 键盘焦点），而 WM_MOUSEWHEEL 是投给焦点窗口的：焦点留在游戏上，滚轮就照样推进
// 游戏文本 / 弹出履历。修复落在已有的 WH_MOUSE_LL 专用线程钩子上——落在卡片内的
// 滚轮**吞掉**（回调返回非 0，事件不进任何输入队列），再由窗口线程还原成一条真
// 滚轮消息喂给 WebView2，卡片照滚、焦点不动。
//
// 这条链全在 C++ 里（Win32 输入队列 + WebView2），Dart 侧跑不了行为测试，故在源码
// 层锁死修复结构：
//   ① 钩子认滚轮，且**只在**落点在目标窗口内时返回 1（吞）；
//   ② 窗口外 / 无目标 / 非滚轮一律 CallNextHookEx 放行（不做全局滚轮黑洞）；
//   ③ 移动事件仍被纯比较挡在所有系统调用之前（BUG-1048/1077 的快路不得回退）；
//   ④ 钩子线程只 PostMessage，绝不 SendMessage、绝不碰 C++ 对象；
//   ⑤ 修饰键必须以**数据**形式抵达消费端，且方向端到端不翻；
//   ⑥ 窗口侧把它还原成真滚轮消息交给 WebView2 的既有输入路（windowed 走子窗，
//      composition 走 SendMouseInput），而不是 PostMessage 回顶层窗了事；
//   ⑦ 不许改焦点模型来「顺手」解决（瞬态查词窗必须保持不可激活）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/overlay_bridge_handlers.dart';

void main() {
  final String hookSrc =
      File('windows/runner/low_level_mouse_hook.cpp').readAsStringSync();
  final String hookHdr =
      File('windows/runner/low_level_mouse_hook.h').readAsStringSync();
  final String winSrc =
      File('windows/runner/global_lookup_window.cpp').readAsStringSync();
  final String winHdr =
      File('windows/runner/global_lookup_window.h').readAsStringSync();
  final String hostJs =
      File('assets/popup/global_lookup_host.js').readAsStringSync();
  final String injectionSrc =
      File('lib/src/pages/implementations/popup_settings_injection.dart')
          .readAsStringSync();

  // 钩子回调本体（HookProc 到它的收尾大括号）——所有「吞 / 放行」判定都必须在这里。
  final int procStart = hookSrc.indexOf('LRESULT CALLBACK HookProc(');
  final int procEnd = hookSrc.indexOf('void HookThreadMain()');
  final String hookProc = hookSrc.substring(procStart, procEnd);

  test('① 滚轮落在查词卡内必须被吞掉（BUG-1166）', () {
    expect(procStart, greaterThan(0));
    expect(procEnd, greaterThan(procStart));
    expect(
      hookProc.contains('wparam == WM_MOUSEWHEEL') &&
          hookProc.contains('wparam == WM_MOUSEHWHEEL'),
      isTrue,
      reason: '两个方向的滚轮都要认：只处理竖向的话横向滚轮照样穿到游戏',
    );
    expect(
      RegExp(r'return 1;').hasMatch(hookProc),
      isTrue,
      reason: '返回非 0 才是「事件到此为止」。改成 CallNextHookEx 等于没修——'
          '游戏是前台窗口，滚轮会照常投给它',
    );
    expect(
      hookHdr.contains('kLowLevelMouseWheelMessage'),
      isTrue,
      reason: '吞掉之后必须有一条投回窗口线程的消息，否则卡片自己也滚不动',
    );
  });

  test('② 卡片外 / 无目标的滚轮必须放行，不做全局滚轮黑洞', () {
    // 滚轮分支（点击分支在它之前，两条路的命中判定不共用）。
    final int wheelStart = hookProc.indexOf('// BUG-1166 — 滚轮落在查词卡上');
    expect(wheelStart, greaterThan(0));
    final int swallow = hookProc.indexOf('return 1;', wheelStart);
    expect(swallow, greaterThan(wheelStart));
    final String beforeSwallow = hookProc.substring(wheelStart, swallow);
    expect(
      beforeSwallow.contains('WindowFromPoint(info->pt)') &&
          beforeSwallow.contains('IsChild(target, hit)'),
      isTrue,
      reason: '命中必须按**窗口区域**判：级联查词窗是整叠卡片的包围盒，TODO-1345 的'
          '保留地板窗横跨大半个工作区，真正可见的只有 SetWindowRgn 裁出的卡片'
          '（BUG-749）。用 GetWindowRect 判等于卡片一开就吞掉半屏滚轮',
    );
    // 只看代码行：注释里解释「为什么不能用 GetWindowRect」不算违规。
    final String wheelCode = beforeSwallow
        .split('\n')
        .where((String line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    expect(
      wheelCode.contains('GetWindowRect'),
      isFalse,
      reason: '滚轮命中判定这条路上不许出现 rect 判定（点击那条路不受影响）',
    );
    expect(
      hookProc.contains('target == nullptr || !IsWindow(target)'),
      isTrue,
      reason: '没有查词卡（Disarm 宽限期内）时回调必须纯放行',
    );
    // 放行分支不止一处，且都走 CallNextHookEx。
    expect(
      'CallNextHookEx'.allMatches(hookProc).length >= 4,
      isTrue,
      reason: '非滚轮 / 无目标 / 窗口外 / 点击 四条路都必须放行',
    );
  });

  test('③ 移动事件仍被纯比较挡在所有系统调用之前（BUG-1048/1077 快路不回退）', () {
    final int firstCompare = hookProc.indexOf('const bool is_click =');
    final int firstSyscall = hookProc.indexOf('g_target.load');
    expect(firstCompare, greaterThan(0));
    expect(firstSyscall, greaterThan(firstCompare),
        reason: 'WH_MOUSE_LL 是同步钩子，每秒上千次的移动事件必须在读任何状态之前'
            '就被比较挡掉，否则全系统鼠标跟着卡（BUG-1048 的原始症状）');
    expect(
      hookProc.indexOf('GetWindowRect') > firstCompare,
      isTrue,
      reason: '几何查询也不许跑在移动事件的快路上',
    );
    expect(
      hookSrc.contains('THREAD_PRIORITY_TIME_CRITICAL'),
      isTrue,
      reason: 'BUG-1077：钩子线程优先级不得回退',
    );
  });

  test('④ 钩子线程只 PostMessage，绝不 SendMessage', () {
    expect(hookProc.contains('PostMessage(target, kLowLevelMouseWheelMessage'),
        isTrue);
    expect(
      hookSrc.contains('SendMessage'),
      isFalse,
      reason: 'SendMessage 会让钩子线程等窗口线程——窗口线程正忙于 WebView2/FFI 时，'
          '全系统输入跟着一起停（BUG-1048 的根因形状）',
    );
  });

  test('⑤ 有符号 delta 随载荷带走（打包/解包对称）', () {
    expect(hookProc.contains('GetAsyncKeyState(VK_CONTROL)'), isTrue);
    expect(hookProc.contains('GetAsyncKeyState(VK_SHIFT)'), isTrue);
    expect(
      hookProc.contains('GetKeyState('),
      isFalse,
      reason: '钩子线程的 GetKeyState 读的是它自己那份从不更新的输入状态，永远返回'
          '「没按下」；物理按键必须用 GetAsyncKeyState',
    );
    expect(
      hookProc.contains('static_cast<short>(HIWORD(info->mouseData))'),
      isTrue,
      reason: 'delta 必须按有符号取：向下滚是负值，当成无符号会变成巨大的正数',
    );
    // 解包同样要 sign-extend，否则向下滚会被还原成向上滚。
    expect(
      hookSrc.contains('static_cast<int16_t>((raw >> 16) & 0xFFFFull)'),
      isTrue,
      reason: '解包必须符号扩展，和打包对称',
    );
  });

  // ⑤bis —— 本 PR 复审推翻的那条假设的专属守卫。
  //
  // 旧守卫只断言「调用了 GetAsyncKeyState」，那是**假信心**：修饰键在钩子里取到了，
  // 却在下一道边界上全丢，守卫照样全绿。真实链路：windowed 模式下窗口线程 PostMessage
  // 一条**合成的** WM_MOUSEWHEEL 给 WebView2 子窗，而 Chromium 取 ctrlKey/altKey 走
  // KeyStateFlagsFromNative() → GetKeyState()，**根本不读 wparam 的 MK_ 位**；
  // GetKeyState 只随硬件输入消息出队才更新线程键状态表，合成消息不更新，覆盖窗又是
  // WS_EX_NOACTIVATE 不在前台输入队列 —— 于是 e.ctrlKey 恒 false，PR#462（BUG-1139）
  // 刚修好的 Ctrl+滚轮缩放静默失效；Alt 更是结构性丢失（WM_MOUSEWHEEL 没有 MK_ALT，
  // COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS 也没有 ALT）。
  // 修复：带 Ctrl/Alt 的滚轮不走合成消息，改把修饰键当**数据**送进 web 层。
  // 下面每条都已做负向验证：抽掉分流，对应断言就转红。
  group('⑤bis 修饰键必须以数据形式抵达消费端（不许指望 Chromium 的 GetKeyState）', () {
    test('钩子取物理 Alt，且 ctrl/alt 是独立载荷字段（不只是 MK_ 位）', () {
      expect(hookProc.contains('GetAsyncKeyState(VK_MENU)'), isTrue,
          reason: 'Alt 没有 MK_ 位，不单独取物理键就永远拿不到');
      expect(hookHdr.contains('bool ctrl = false;'), isTrue,
          reason: 'ctrl 必须是独立字段：MK_CONTROL 过不了 WebView2 那道边界');
      expect(hookHdr.contains('bool alt = false;'), isTrue,
          reason: 'alt 必须是独立字段：WM_MOUSEWHEEL 结构上没有 ALT 位');
      expect(hookSrc.contains('wheel.ctrl ? 1u : 0u'), isTrue);
      expect(hookSrc.contains('wheel.alt ? 1u : 0u'), isTrue);
      expect(
          hookSrc.contains('wheel.ctrl = ((raw >> 33) & 0x1ull) != 0;'), isTrue,
          reason: '解包必须与打包同位，否则分流判据恒 false');
      expect(
          hookSrc.contains('wheel.alt = ((raw >> 34) & 0x1ull) != 0;'), isTrue);
    });

    test('分流分支存在，且排在任何「合成消息」之前', () {
      final int i =
          winSrc.indexOf('void GlobalLookupWindow::HandleGlobalWheel(');
      expect(i, greaterThan(0));
      final String handler = winSrc.substring(
          i,
          winSrc.indexOf(
              'void GlobalLookupWindow::ForwardGlobalWheelToHost(', i));
      final int branch = handler.indexOf('wheel.ctrl || wheel.alt');
      expect(branch, greaterThan(0),
          reason: '必须按「有没有按 Ctrl/Alt」分流 —— 这是整条修复的落点');
      final int dispatch = handler.indexOf('ForwardGlobalWheelToHost(');
      expect(dispatch, greaterThan(branch), reason: '分流分支里必须真的走那条显式携带修饰键的路');
      final int post = handler.indexOf('PostMessage(');
      final int composition = handler.indexOf('ForwardCompositionMouse(');
      expect(post, greaterThan(dispatch),
          reason: 'PostMessage 合成消息丢修饰键，必须排在分流之后');
      expect(composition, greaterThan(dispatch),
          reason: 'SendMouseInput 带不了 Alt，同样排在分流之后');
    });

    test('裸滚轮 / 仅 Shift 不绕道，仍走原生子窗 PostMessage', () {
      expect(
          winSrc.contains('PostMessage(hit, message, wparam, lparam);'), isTrue,
          reason: '普通滚轮那条原生路本来就是对的；绕道反而丢掉浏览器自己的平滑滚动'
              '与 Shift→deltaX 横滚转换');
    });

    test('C++ 把三个修饰键显式作为实参交给 host JS', () {
      final int i =
          winSrc.indexOf('void GlobalLookupWindow::ForwardGlobalWheelToHost(');
      expect(i, greaterThan(0), reason: '必须有这条显式携带修饰键的落地点');
      final String fn = winSrc.substring(
          i, winSrc.indexOf('GlobalLookupWindow::GlobalLookupWindow()', i));
      expect(fn.contains('handleGlobalWheel('), isTrue);
      expect(fn.contains('wheel.ctrl ? L"true" : L"false"'), isTrue,
          reason: 'ctrl 必须作为实参显式传进 JS');
      expect(fn.contains('wheel.alt ? L"true" : L"false"'), isTrue,
          reason: 'alt 必须作为实参显式传进 JS');
      expect(fn.contains('MK_SHIFT) != 0 ? L"true" : L"false"'), isTrue,
          reason: 'shift 同样显式传，JS 侧绑定全等比对才不会误判');
    });

    test('host JS 用参数（而非环境键状态）填 flag，且只投给命中的那一帧', () {
      final int i = hostJs.indexOf('function handleGlobalWheel(');
      expect(i, greaterThan(0), reason: 'host 必须有这个入口');
      final String fn =
          hostJs.substring(i, hostJs.indexOf('function topPopupId()', i));
      expect(fn.contains('ctrlKey: !!ctrlKey'), isTrue,
          reason: 'flag 必须来自**参数** —— 这正是绕开 Chromium GetKeyState 的全部意义');
      expect(fn.contains('altKey: !!altKey'), isTrue);
      expect(fn.contains('shiftKey: !!shiftKey'), isTrue);
      expect(fn.contains('frameIdAtPoint(x, y)'), isTrue,
          reason: '只投给命中的那张卡，卡片间缝隙不投');
      expect(fn.contains('bubbles: true'), isTrue,
          reason: '缩放监听挂在 window 上，不冒泡就收不到');
      expect(fn.contains('cancelable: true'), isTrue,
          reason: '下游要 preventDefault');
    });

    test('方向端到端不翻：Win32 上滚 → DOM 负 deltaY → +1 档 → 字号真的变大', () {
      final int i =
          winSrc.indexOf('void GlobalLookupWindow::ForwardGlobalWheelToHost(');
      final String fn = winSrc.substring(
          i, winSrc.indexOf('GlobalLookupWindow::GlobalLookupWindow()', i));
      expect(
        fn.contains(
            'const double dom_delta_y = -static_cast<double>(wheel.delta);'),
        isTrue,
        reason: 'Win32 上滚 delta 为正、DOM 上滚 deltaY 为负 —— 不取负就把缩放做反了',
      );
      expect(
        injectionSrc.contains('pendingSteps += (e.deltaY < 0 ? 1 : -1);'),
        isTrue,
        reason: 'PR#462 的约定：上滚（deltaY<0）= +1 档 = 放大。改了这里方向就翻',
      );
      const double base = 16.0;
      expect(zoomFontSizeAfterSteps(base, 1), greaterThan(base),
          reason: '上滚一格必须放大');
      expect(zoomFontSizeAfterSteps(base, -1), lessThan(base),
          reason: '下滚一格必须缩小');
    });

    test('Ctrl 链路末端：popupZoomFontStep 真被既有 Dart 消费端接住', () {
      int rerenders = 0;
      final bool handled = maybeHandleOverlayZoomFontStep(
        model: null,
        handler: 'popupZoomFontStep',
        message: const <String, Object?>{
          'handler': 'popupZoomFontStep',
          'args': <Object?>[1],
        },
        onFontSizeChanged: () => rerenders++,
      );
      expect(handled, isTrue,
          reason: 'C++ 分流后 Ctrl 最终必须落到这个既有 handler 上（PR#462 原链路整条复用）');
      expect(rerenders, 0, reason: '无 model 时不重渲（不炸、不空转）');
    });
  });

  test('⑥ 窗口侧还原成真滚轮消息，走 WebView2 既有输入路', () {
    final int i = winSrc.indexOf('void GlobalLookupWindow::HandleGlobalWheel(');
    expect(i, greaterThan(0), reason: '窗口线程必须有滚轮落地点');
    final String handler =
        winSrc.substring(i, winSrc.indexOf('GlobalLookupWindow::~', i));
    expect(
      handler.contains('MAKEWPARAM(static_cast<WORD>(wheel.keys)'),
      isTrue,
      reason: '还原出来的 wparam 必须与真 WM_MOUSEWHEEL 同构（低字修饰键/高字 delta）',
    );
    expect(
      handler.contains('composition_active_'),
      isTrue,
      reason: 'composition 实例没有子窗，只能经 ForwardCompositionMouse/SendMouseInput',
    );
    expect(
      handler.contains('WindowFromPoint(screen_pt)') &&
          handler.contains('GetWindow(hwnd_, GW_CHILD)'),
      isTrue,
      reason: 'windowed 实例的 WebView2 输入落在子 HWND 上：投回顶层窗只会走'
          'DefWindowProc（顶层窗不往下传），卡片一样滚不动',
    );
    expect(
      winSrc.contains('case hibiki::kLowLevelMouseWheelMessage:'),
      isTrue,
      reason: '消息必须真的接进 HandleMessage，否则钩子吞了就石沉大海',
    );
  });

  test('⑦ 不许靠改焦点模型来解决（瞬态查词窗必须保持不可激活）', () {
    expect(
      winHdr.contains('bool activatable_ = false;'),
      isTrue,
      reason: '让查词卡抢焦点确实能挡住滚轮（剪贴板面板就是这么做的），但那会让'
          'galgame 失焦——很多 VN 一失焦就暂停/变暗。design §5 保证 3 不得放弃',
    );
    expect(
      winSrc.contains('(activatable_ ? 0 : WS_EX_NOACTIVATE)'),
      isTrue,
      reason: '瞬态覆盖窗的 NOACTIVATE 不得被顺手拿掉',
    );
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1981：Hook 台词浮窗的 HWND 被外部 WM_CLOSE / teardown 销毁后，旧
/// `FloatingLyricWindow` 对象仍跨 gal 会话复用。契约与姊妹窗
/// `global_lookup_dead_window_recreate_guard_test.dart` 完全对齐：
///
/// 1. `OwnsLiveWindow()`：IsWindow + WM_NCCREATE back-pointer 双判据（HWND 会被
///    系统回收给别的窗口，只判 IsWindow 会把别人的窗口认成自己的）。
/// 2. `ResetWindowInteractionState()`：窗口没了以后要归零的**全部**每窗口交互
///    状态，只此一份。
/// 3. `ForgetDeadWindow()`：句柄非我方活窗时清 `hwnd_` + 走上面那张表。
/// 4. `Show()` 在创建/幂等守卫前先 `ForgetDeadWindow()`。
/// 5. `IsShowing()` 用 `OwnsLiveWindow()` 而不是裸 `hwnd_ != nullptr`。
/// 6. `HandleMessage()` 用 **WndProc 透传进来的消息 hwnd**，不读成员 `hwnd_`：
///    旧窗口的 `WM_NCDESTROY` 可以晚于新窗口创建，用成员会把活着的新窗口拆掉。
/// 7. `hook_toolbar::SlotTooltipHost` 是同一 bug 家族的第二处：提示窗以宿主窗
///    为 owner 创建，宿主销毁时系统连带销毁它，所以它也要 `OwnsLiveWindow()` +
///    在 `EnsureWindow()` 的幂等守卫**之前** `ForgetDeadWindow()`。
/// 8. 窗口消失由 native 在 `WM_NCDESTROY` 里**推**给 Dart（`overlayDestroyed`），
///    Dart 的可见性镜像被动复位；没有这条事件，消费端只能退回按行 `isShowing()`
///    轮询。方法名是两侧的 wire 契约，必须同名。
///
/// 浮窗真弹出依赖 native Direct2D + 桌面合成，headless 测不了，故用源码扫描钉住。
void main() {
  /// 注释必须先剥掉再扫：本文件钉的判据（尤其第 5 条的**否定**断言）在注释里
  /// 也会以自然语言形式出现，不剥就会被注释那份先命中，断言退化成恒真空转。
  String maskComments(String src) {
    final StringBuffer out = StringBuffer();
    bool inLine = false;
    bool inBlock = false;
    bool inString = false;
    for (int i = 0; i < src.length; i++) {
      final String c = src[i];
      final String next = i + 1 < src.length ? src[i + 1] : '';
      if (inLine) {
        if (c == '\n') {
          inLine = false;
          out.write(c);
        }
        continue;
      }
      if (inBlock) {
        if (c == '*' && next == '/') {
          inBlock = false;
          i++;
        }
        continue;
      }
      if (inString) {
        if (c == r'\') {
          i++;
          continue;
        }
        if (c == '"') inString = false;
        out.write(c);
        continue;
      }
      if (c == '/' && next == '/') {
        inLine = true;
        continue;
      }
      if (c == '/' && next == '*') {
        inBlock = true;
        i++;
        continue;
      }
      if (c == '"') inString = true;
      out.write(c);
    }
    return out.toString();
  }

  /// 取顶层函数体（到第一个位于行首的 `}` 为止），再压掉空白。
  String functionBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature（改名了？）');
    final int end = src.indexOf('\n}', start);
    expect(end, greaterThan(start), reason: '$signature 的函数体没有正常闭合');
    return src.substring(start, end).replaceAll(RegExp(r'\s+'), '');
  }

  late String cpp;
  late String compact;
  late String header;
  late String hookCpp;
  late String hookHeader;

  setUpAll(() {
    cpp = maskComments(
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync(),
    );
    compact = cpp.replaceAll(RegExp(r'\s+'), '');
    header = File(
      'windows/runner/floating_lyric_window.h',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');
    hookCpp = maskComments(
      File('windows/runner/hook_toolbar_window.cpp').readAsStringSync(),
    );
    hookHeader = File(
      'windows/runner/hook_toolbar_window.h',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');
  });

  test(
    '头文件声明 OwnsLiveWindow / ResetWindowInteractionState / ForgetDeadWindow',
    () {
      expect(header, contains('boolOwnsLiveWindow()const;'));
      expect(header, contains('voidResetWindowInteractionState();'));
      expect(header, contains('voidForgetDeadWindow();'));
    },
  );

  test('OwnsLiveWindow 核对实例 back-pointer，不只判 IsWindow', () {
    final String body = functionBody(
      cpp,
      'bool FloatingLyricWindow::OwnsLiveWindow() const {',
    );
    expect(body, contains('IsWindow(hwnd_)'));
    expect(
      body,
      contains('GetWindowLongPtr(hwnd_,GWLP_USERDATA))==this;'),
      reason: 'IsWindow 单独不足以排除 HWND 被系统复用，必须核对实例 back-pointer',
    );
  });

  test('死窗复位表是唯一一份，且覆盖全部每窗口交互状态', () {
    final String body = functionBody(
      cpp,
      'void FloatingLyricWindow::ResetWindowInteractionState() {',
    );
    // 前四项是 BUG-1981 初版在两条死窗路径上双双漏掉的。`tracking_mouse_leave_`
    // 卡 true 会让 WM_MOUSEMOVE 的 `if (!tracking_mouse_leave_)` 恒假 → 新 HWND
    // 上永不再调 TrackMouseEvent → 永不收 WM_MOUSELEAVE → hovered_ 也清不掉，
    // 悬停查词与工具条自动隐藏本会话整个作废。
    for (final String reset in <String>[
      'hovered_=false;',
      'tracking_mouse_leave_=false;',
      'toolbar_revealed_=false;',
      'ResetHoverLookupAnchor();',
      'visible_=false;',
      'CancelPointerGesture();',
      'StopHoverLookupPolling();',
      'StopToolbarRevealPolling();',
      'slot_tooltip_.Hide();',
      'pass_through_toolbar_.Hide();',
    ]) {
      expect(body, contains(reset), reason: '死窗复位表漏了 $reset');
    }
  });

  test('ForgetDeadWindow 只在句柄非我方活窗时清零，活窗时是 no-op', () {
    final String body = functionBody(
      cpp,
      'void FloatingLyricWindow::ForgetDeadWindow() {',
    );
    expect(
      body,
      contains('if(OwnsLiveWindow()){return;}'),
      reason: '活窗必须原样返回，否则 Show() 开头无条件调用会把好窗口拆了',
    );
    expect(body, contains('hwnd_=nullptr;'));
    expect(
      body,
      contains('ResetWindowInteractionState();'),
      reason: '不得再就地手写第二份复位表（BUG-1981 初版就是这么漏项的）',
    );
  });

  test('Show 在重建前先 ForgetDeadWindow', () {
    final String body = functionBody(cpp, 'bool FloatingLyricWindow::Show(');
    final int forget = body.indexOf('ForgetDeadWindow();');
    final int create = body.indexOf('if(hwnd_==nullptr)');
    expect(forget, greaterThanOrEqualTo(0), reason: '死掉的窗口必须被重建');
    expect(
      create,
      greaterThan(forget),
      reason: 'ForgetDeadWindow 必须在「已有窗口就复用」的守卫之前',
    );
  });

  test('IsShowing 用 OwnsLiveWindow 而非裸 hwnd_ != nullptr', () {
    final String body = functionBody(
      cpp,
      'bool FloatingLyricWindow::IsShowing() const {',
    );
    expect(
      body,
      contains('OwnsLiveWindow()'),
      reason: '否则悬垂/回收句柄让 IsShowing 报 true，Dart 镜像永不复位',
    );
    expect(
      body.contains('hwnd_!=nullptr&&IsWindowVisible'),
      isFalse,
      reason: '不得退回裸 hwnd_ != nullptr 判据（BUG 回归 signature）',
    );
  });

  test('WM_NCDESTROY 认消息自带的 hwnd，撤 back-pointer 后才动成员与复位表', () {
    expect(
      compact,
      contains('caseWM_NCDESTROY:'),
      reason: '窗口生命周期结束点必须同步清 Dart 复用对象持有的原生句柄',
    );
    expect(
      compact,
      contains(
        'constHWNDdestroyed=hwnd;'
        'SetWindowLongPtr(destroyed,GWLP_USERDATA,0);',
      ),
      reason: '被销毁的是消息自带的那一个窗口，back-pointer 必须从它身上撤',
    );
    expect(
      compact,
      contains(
        'if(hwnd_==destroyed){ResetWindowInteractionState();hwnd_=nullptr;',
      ),
      reason:
          '成员句柄与复位表只能在「死的正是我方当前这一个」时才动 —— 旧窗口的\n'
          'NCDESTROY 晚于新窗口创建时，无条件清零会把活着的新窗口拆了',
    );
  });

  test('HandleMessage 收 WndProc 透传的 hwnd，函数体不再读成员 hwnd_', () {
    expect(
      header,
      contains(
        'LRESULTHandleMessage(HWNDhwnd,UINTmessage,WPARAMwparam,'
        'LPARAMlparam)noexcept;',
      ),
      reason: '签名不带 hwnd 就只能拿成员冒充，这正是要根除的形状',
    );
    expect(
      compact,
      contains('returnself->HandleMessage(hwnd,message,wparam,lparam);'),
      reason: 'WndProc 必须把消息自己的 hwnd 透传下去',
    );
    final String body = functionBody(
      cpp,
      'LRESULT FloatingLyricWindow::HandleMessage(',
    );
    // 唯一允许的两处成员用法就是 WM_NCDESTROY 里的「是不是我这一个」比较和
    // 随之而来的清零；其余任何 `hwnd_` 都是拿成员冒充消息宿主。
    final List<String> offenders = RegExp(r'hwnd_.{0,14}')
        .allMatches(body)
        .map((Match m) => m.group(0)!)
        .where(
          (String use) =>
              !use.startsWith('hwnd_==destroyed') &&
              !use.startsWith('hwnd_=nullptr;'),
        )
        .toList();
    expect(
      offenders,
      isEmpty,
      reason: 'HandleMessage 处理的是 |hwnd| 那个窗口的消息，不是「当前成员」的',
    );
  });

  test('窗口消失由 native 推事件，不靠 Dart 按行轮询', () {
    final String body = functionBody(
      cpp,
      'LRESULT FloatingLyricWindow::HandleMessage(',
    );
    expect(
      body,
      contains('if(on_destroyed_)on_destroyed_();'),
      reason: 'HWND 生命周期终点是唯一能如实报告「窗口没了」的地方',
    );
    expect(header, contains('usingDestroyedCallback=std::function<void()>;'));
    final String wiring = maskComments(
      File('windows/runner/flutter_window.cpp').readAsStringSync(),
    ).replaceAll(RegExp(r'\s+'), '');
    expect(
      wiring,
      contains('gal_hook_text_window_->SetDestroyedCallback('),
      reason: 'native 不推事件的话，消费端只能退回按行 isShowing() 往返',
    );
    expect(
      wiring,
      contains('InvokeMethod("overlayDestroyed"'),
      reason:
          '方法名是与 GalHookTextOverlayChannel 的 wire 契约；改一侧不改另一侧，'
          '事件静默消失、镜像永不复位（回到 BUG-1981 的症状）',
    );
  });

  group('SlotTooltipHost（同一 bug 家族的第二处死句柄）', () {
    test('头文件声明 OwnsLiveWindow / ForgetDeadWindow', () {
      expect(hookHeader, contains('boolOwnsLiveWindow()const;'));
      expect(hookHeader, contains('voidForgetDeadWindow();'));
    });

    test('OwnsLiveWindow 核对实例 back-pointer，不只判 IsWindow', () {
      final String body = functionBody(
        hookCpp,
        'bool SlotTooltipHost::OwnsLiveWindow() const {',
      );
      expect(body, contains('IsWindow(hwnd_)'));
      expect(
        body,
        contains('GetWindowLongPtr(hwnd_,GWLP_USERDATA))==this;'),
        reason: 'IsWindow 单独不足以排除 HWND 被系统回收给别的窗口',
      );
    });

    test('ForgetDeadWindow 活窗 no-op，死窗清全部每窗口状态', () {
      final String body = functionBody(
        hookCpp,
        'void SlotTooltipHost::ForgetDeadWindow() {',
      );
      expect(
        body,
        contains('if(OwnsLiveWindow()){return;}'),
        reason: '活窗必须原样返回，否则每次 Update 都会把好提示窗拆了',
      );
      for (final String reset in <String>[
        'hwnd_=nullptr;',
        'active_slot_=-1;',
        'current_text_.clear();',
        'tool_={};',
      ]) {
        expect(body, contains(reset), reason: '死窗复位表漏了 \$reset');
      }
    });

    test('EnsureWindow 在幂等守卫之前先忘掉死句柄，并给新窗打 back-pointer', () {
      final String body = functionBody(
        hookCpp,
        'bool SlotTooltipHost::EnsureWindow(HWND owner) {',
      );
      final int forget = body.indexOf('ForgetDeadWindow();');
      final int guard = body.indexOf('if(hwnd_!=nullptr){returntrue;}');
      expect(
        forget,
        greaterThanOrEqualTo(0),
        reason: '宿主窗被销毁会连带销毁这个 owned popup，hwnd_ 却不会被通知',
      );
      expect(
        guard,
        greaterThan(forget),
        reason: '幂等守卫在前就永久短路：浮窗重建后槽位提示整会话再也不出',
      );
      expect(
        body,
        contains(
          'SetWindowLongPtr(hwnd_,GWLP_USERDATA,'
          'reinterpret_cast<LONG_PTR>(this));',
        ),
        reason: '不打 back-pointer 的话 OwnsLiveWindow 的第二条判据恒假',
      );
    });

    test('析构先忘死句柄再 DestroyWindow，不去拆被回收的别人家窗口', () {
      final String body = functionBody(
        hookCpp,
        'SlotTooltipHost::~SlotTooltipHost() {',
      );
      final int forget = body.indexOf('ForgetDeadWindow();');
      final int destroy = body.indexOf('DestroyWindow(hwnd_);');
      expect(forget, greaterThanOrEqualTo(0));
      expect(destroy, greaterThan(forget));
    });
  });

  test('抬窗失败回 false，不让 Dart 把无窗口记成已显示', () {
    expect(
      compact,
      contains('if(!SetWindowPos(hwnd_,topmost_?HWND_TOPMOST:HWND_NOTOPMOST'),
    );
  });
}

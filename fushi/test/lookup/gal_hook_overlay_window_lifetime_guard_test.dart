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

  setUpAll(() {
    cpp = maskComments(
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync(),
    );
    compact = cpp.replaceAll(RegExp(r'\s+'), '');
    header = File(
      'windows/runner/floating_lyric_window.h',
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

  test('WM_NCDESTROY 走同一张复位表并撤回 back-pointer', () {
    expect(
      compact,
      contains('caseWM_NCDESTROY:'),
      reason: '窗口生命周期结束点必须同步清 Dart 复用对象持有的原生句柄',
    );
    expect(compact, contains('ResetWindowInteractionState();'));
    expect(
      compact,
      contains('SetWindowLongPtr(destroyed,GWLP_USERDATA,0);hwnd_=nullptr;'),
      reason: 'WM_NCDESTROY 必须同时撤回 back-pointer 与成员句柄',
    );
  });

  test('抬窗失败回 false，不让 Dart 把无窗口记成已显示', () {
    expect(
      compact,
      contains('if(!SetWindowPos(hwnd_,topmost_?HWND_TOPMOST:HWND_NOTOPMOST'),
    );
  });
}

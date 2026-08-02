// galgame Hook 台词浮窗的两件新交互（源码守卫）：
//
//  ① **按住 Shift 悬停查词**——与阅读器 `onShiftHover` / 视频字幕
//     `_handleShiftHover` 同语义，让「查词快捷键」在 gal 浮窗上也成立；
//  ② **置顶（📌）按钮**——工具栏槽表里新增一个 always-on-top 开关。
//
// 浮窗是 runner 自有的 Win32 分层窗（Direct2D/DirectWrite 直绘，独立于 Flutter
// 视图树），C++ 无法在 Dart 测试里执行，所以在源码层锁死这两件事的**结构**：
// 断言全部挑「只可能出现在代码里」的字面量（带类型转换 / 带参数的调用形态），
// 避免注释里的同名词把守卫变成假绿。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final String runner = p.join('windows', 'runner');
  final String window =
      File(p.join(runner, 'floating_lyric_window.cpp')).readAsStringSync();
  final String windowHeader =
      File(p.join(runner, 'floating_lyric_window.h')).readAsStringSync();
  final String toolbarHeader =
      File(p.join(runner, 'hook_toolbar_window.h')).readAsStringSync();
  final String toolbar =
      File(p.join(runner, 'hook_toolbar_window.cpp')).readAsStringSync();
  final String host =
      File(p.join(runner, 'flutter_window.cpp')).readAsStringSync();

  group('Shift-悬停查词', () {
    test('点击查词与悬停查词共用同一个派发出口', () {
      // 两条路径各抄一份「取字 → UTF-8 → 客户区 px 换算成屏幕逻辑 px」，迟早
      // 会漂成两种锚点行为。出口只能有一个。
      expect(
        window.contains('bool FloatingLyricWindow::DispatchLookupAt('),
        isTrue,
        reason: '查词派发必须收进 DispatchLookupAt 一个出口',
      );
      expect(
        window.contains(
            'on_context_lookup_(context_id_, utf8, index, screen_rect)'),
        isTrue,
        reason: '查词事件必须带上屏幕逻辑 px 的词矩形（锚定到词而非鼠标）',
      );
      expect(
        'on_context_lookup_(context_id_, utf8, index, screen_rect)'
            .allMatches(window)
            .length,
        1,
        reason: '派发只能有一处；出现两次说明点击 / 悬停各抄了一份',
      );
      // 点击（WM_LBUTTONUP）走的是同一个出口。
      expect(
        window.contains('DispatchLookupAt(static_cast<float>(lookup_pt.x),'),
        isTrue,
        reason: '单击查词必须走 DispatchLookupAt',
      );
    });

    test('鼠标移动与轮询两条触发都汇入 MaybeHoverLookup', () {
      expect(
        window.contains('MaybeHoverLookup(static_cast<float>(GET_X_LPARAM('),
        isTrue,
        reason: 'WM_MOUSEMOVE 必须驱动悬停查词（按住 Shift 划过即逐字查）',
      );
      expect(
        window.contains('MaybeHoverLookup(static_cast<float>(client.x),'),
        isTrue,
        reason: '轮询路径必须用当前光标位置驱动同一个判定函数',
      );
    });

    test('Shift 读物理键态（GetAsyncKeyState），不读线程同步键态', () {
      // 浮窗是 WS_EX_NOACTIVATE 的分层窗，键盘焦点永远在游戏那边：GetKeyState
      // 读的是本线程消息队列的同步键态，对一个从不收键盘消息的窗口永远不更新，
      // 用它写出来的 Shift 判据是恒 false。
      expect(
        window.contains('GetAsyncKeyState(VK_SHIFT) & 0x8000'),
        isTrue,
        reason: 'Shift 必须问全局物理键态',
      );
      expect(
        window.contains('GetKeyState(VK_SHIFT)'),
        isFalse,
        reason: 'GetKeyState 在这个永远不获焦的窗口上恒为「未按下」',
      );
    });

    test('静止光标也能触发：进窗口挂轮询表，离开 / 隐藏就停表', () {
      // BUG-880（视频页）同款坑：只绑 hover 事件 = 光标不动时按 Shift 不出词。
      expect(
        window.contains('void FloatingLyricWindow::StartHoverLookupPolling()'),
        isTrue,
      );
      expect(
        window.contains('SetTimer(hwnd_, kHoverLookupTimerId,'),
        isTrue,
        reason: '轮询必须真的挂表',
      );
      expect(
        window.contains('KillTimer(hwnd_, kHoverLookupTimerId)'),
        isTrue,
        reason: '必须能停表，否则鼠标离开后仍在后台空转',
      );
      // 三个停表点：WM_MOUSELEAVE、Hide()、以及轮询自查（光标已在窗外）。
      expect(
        'StopHoverLookupPolling();'.allMatches(window).length >= 3,
        isTrue,
        reason: '离开 / 隐藏 / 光标已在窗外三处都必须停表',
      );
    });

    test('去重锚：同一个字不重复查，换台词 / 移出 / 松 Shift 复位', () {
      expect(
        window.contains('if (index == hover_lookup_index_)'),
        isTrue,
        reason: '命中同一个字必须直接返回，否则轮询会每 60ms 查一次同一个词',
      );
      expect(
        window.contains('void FloatingLyricWindow::ResetHoverLookupAnchor()'),
        isTrue,
      );
      // UpdateText 里必须复位：换句之后同号下标是另一个字了。
      final int updateTextAt =
          window.indexOf('void FloatingLyricWindow::UpdateText(');
      expect(updateTextAt, greaterThan(0));
      final String updateTextBody = window.substring(
          updateTextAt, window.indexOf('void FloatingLyricWindow::Highlight('));
      expect(
        updateTextBody.contains('ResetHoverLookupAnchor();'),
        isTrue,
        reason: '换台词必须清去重锚，否则新句子里同号的字悬停不查',
      );
    });

    test('穿透态不查词：判据写在函数里，不靠「收不到鼠标消息」', () {
      // 轮询读的是全局光标位置，会绕过 WS_EX_TRANSPARENT 这条天然边界。
      final int hoverAt =
          window.indexOf('void FloatingLyricWindow::MaybeHoverLookup(');
      expect(hoverAt, greaterThan(0));
      final String hoverBody = window.substring(hoverAt, hoverAt + 1600);
      expect(
        hoverBody.contains('if (pass_through_) {'),
        isTrue,
        reason: '穿透态「鼠标整个属于游戏」，悬停不得查词',
      );
      expect(
        hoverBody.contains(
            '!hook_text_mode_ || !click_lookup_enabled_ || pressed_ || dragging_'),
        isTrue,
        reason: '悬停查词只属于 gal hook 浮窗，且拖窗 / 按下期间不查；'
            '歌词条与剪贴板文本窗必须保持「点字才查」',
      );
    });

    test('「悬停即查词」开关从 Dart 下发（show 载荷 + live setter）', () {
      expect(
        windowHeader.contains('void SetHoverAutoLookup(bool enabled);'),
        isTrue,
      );
      expect(
        host.contains('SetHoverAutoLookup('),
        isTrue,
        reason: 'gal_hook_text channel 必须把偏好接到 native 窗口上',
      );
      expect(
        host.contains('"hoverAutoLookup"'),
        isTrue,
        reason: 'show 载荷必须带上开关初值',
      );
      expect(
        host.contains('method == "setHoverAutoLookup"'),
        isTrue,
        reason: '设置页改完要能 live 推给开着的浮窗',
      );
      final String channel = File(p.join(
        'lib',
        'src',
        'platform',
        'gal_hook_text_overlay_channel.dart',
      )).readAsStringSync();
      expect(channel.contains("'hoverAutoLookup': hoverAutoLookup"), isTrue);
      expect(
        channel
            .contains('static Future<void> setHoverAutoLookup(bool enabled)'),
        isTrue,
      );
      final String controller = File(p.join(
        'lib',
        'src',
        'lookup',
        'gal_hook_text_overlay_controller.dart',
      )).readAsStringSync();
      expect(
        controller.contains(
            'Future<void> applyHoverAutoLookupFromPreferences() async'),
        isTrue,
      );
      final String settings = File(p.join(
        'lib',
        'src',
        'settings',
        'settings_schema_lookup.dart',
      )).readAsStringSync();
      expect(
        settings.contains('applyHoverAutoLookupFromPreferences()'),
        isTrue,
        reason: '设置项 onChanged 必须把新值推给浮窗，否则要关掉浮窗重开才生效',
      );
    });
  });

  group('置顶（📌）按钮', () {
    test('槽表里有 topmost，且排在 close 之前（最右仍是关闭）', () {
      final int tableStart = toolbarHeader.indexOf('kSlotActions');
      expect(tableStart, greaterThan(0));
      final String table = toolbarHeader.substring(
          tableStart, toolbarHeader.indexOf('};', tableStart));
      final List<String> actions = RegExp('"([a-zA-Z]+)"')
          .allMatches(table)
          .map((RegExpMatch m) => m.group(1)!)
          .toList();
      expect(actions.contains('topmost'), isTrue, reason: '缺置顶按钮');
      expect(actions.last, 'close', reason: '最右按钮必须仍是关闭（肌肉记忆）');
      expect(
        actions.indexOf('topmost'),
        actions.indexOf('close') - 1,
        reason: '置顶插在关闭之前；插到别处会打乱既有槽位下标',
      );
    });

    test('按钮状态：📌 字形 + 真实 topmost 高亮 + 状态参与重绘比对', () {
      expect(
        toolbarHeader.contains('bool topmost = true;'),
        isTrue,
        reason: 'States 必须带上 topmost，独立工具条窗才画得出高亮',
      );
      expect(
        toolbar.contains(r'return L"\U0001F4CC";'),
        isTrue,
        reason: '置顶槽必须有 📌 字形',
      );
      expect(
        toolbar.contains('return states.topmost;'),
        isTrue,
        reason: '置顶槽的高亮必须跟随真实 topmost 状态',
      );
      expect(
        toolbar.contains('a.topmost == b.topmost'),
        isTrue,
        reason: 'SameStates 漏比 topmost = 点了按钮独立工具条不重绘（看着没反应）',
      );
      expect(
        window.contains('states.topmost = topmost_;'),
        isTrue,
        reason: '正文窗必须把自己的 topmost_ 映射进 States',
      );
    });

    test('置顶只作用于正文窗：穿透逃生工具条永远保持 topmost', () {
      // BUG-951：穿透态下那个独立工具条是用户**唯一**能点到的东西，被压到游戏
      // 底下就等于彻底失联。
      expect(
        toolbar.contains('states_.topmost ? HWND_TOPMOST'),
        isFalse,
        reason: '逃生工具条的 Z 序不得跟随 pin',
      );
      expect(
        window.contains(
            'SetWindowPos(hwnd_, topmost_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,'),
        isTrue,
        reason: '正文窗的 pin 必须真的改自己的 Z 序',
      );
    });

    test('最小宽度跟着槽数走（9 槽 = 350dip 行宽，下限必须更大）', () {
      final Match? declared =
          RegExp(r'kSlotCount\s*=\s*(\d+)\s*;').firstMatch(toolbarHeader);
      expect(declared, isNotNull);
      final int slots = int.parse(declared!.group(1)!);
      final Match? minWidth =
          RegExp(r'kHookTextMinStripWidthDip = ([\d.]+)f;').firstMatch(window);
      expect(minWidth, isNotNull);
      final double floor = double.parse(minWidth!.group(1)!);
      // 行宽 = N * 按钮 30dip + (N-1) * 间隙 10dip。
      final double rowWidth = slots * 30.0 + (slots - 1) * 10.0;
      expect(
        floor,
        greaterThanOrEqualTo(rowWidth),
        reason: '窗口下限比工具栏行还窄 = 用户能把自己的按钮拖没',
      );
    });

    test('置顶按会话复位为开（浮窗不会藏在下一局游戏后面）', () {
      expect(
        windowHeader.contains('void SetTopmost(bool enabled);'),
        isTrue,
        reason: '没有复位入口，native 的 topmost_ 会跨会话粘住',
      );
      expect(
        host.contains('BoolFromValue(args, "topmost", true)'),
        isTrue,
        reason: 'show 必须按载荷复位置顶',
      );
      final String channel = File(p.join(
        'lib',
        'src',
        'platform',
        'gal_hook_text_overlay_channel.dart',
      )).readAsStringSync();
      expect(
        channel.contains("'topmost': true"),
        isTrue,
        reason: '每次 show 都要把置顶复位成开',
      );
    });

    test('恢复出来的旧窗口宽度会被夹到当前下限', () {
      expect(
        window.contains('std::max(restored_width, min_width)'),
        isTrue,
        reason: '老版本存下的窄窗口恢复后会裁掉首尾按钮',
      );
    });
  });
}

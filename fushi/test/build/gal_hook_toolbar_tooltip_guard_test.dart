// 源码守卫：galgame hook 浮窗工具条的 9 槽悬停提示 + 槽位几何单一真相。
//
// 工具条是 runner 自有的 Win32 自绘分层窗（Direct2D 直绘 + 手动 hit-test），
// C++ 在 Dart 测试里跑不起来，所以在源码层锁死这套东西赖以成立的结构性前提：
//   ① 提示文案是**一张表**（hook_toolbar::SetSlotTooltips / SlotTooltip），
//      正文内工具条和穿透工具条窗读同一张，两处说明不可能各说各话；
//   ② TTM_TRACKPOSITION 的坐标是**有符号**的：副屏摆在主屏左边 / 上边时屏幕
//      坐标为负，裸 static_cast<WORD> 会把 -8 截成 65528，提示被甩出屏幕。
//      必须先窄化成 SHORT 再取位模式；
//   ③ TOOLINFOW::lpszText 是裸指针，且 comctl32 在提示活着的整段时间里都会
//      回读它。绝不能指向共享表的内部缓冲——SetSlotTooltips 是整表 move 赋值，
//      旧串一析构就是悬垂指针。SlotTooltipHost 必须自持一份；
//   ④ comctl32 初始化只做一次且失败不崩：拿不到 tooltip 就静默降级，工具条
//      本身必须照常可点（它是穿透模式下唯一的逃生口，BUG-951）；
//   ⑤ hook 槽位几何单一真相：绘制、命中、穿透工具条窗定位、悬停提示四处共用
//      HookToolbarRowWidth / HookToolbarRowLeft / HookToolbarSlotAt。四处各算
//      各的，提示就会指着隔壁那颗按钮；
//   ⑥ 提示条数与 native 槽位数严格同长——加了第 10 颗按钮却没加文案，下标一
//      对不上就会整体错位。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String toolbarCpp = File(
    'windows/runner/hook_toolbar_window.cpp',
  ).readAsStringSync();
  final String toolbarHeader = File(
    'windows/runner/hook_toolbar_window.h',
  ).readAsStringSync();
  final String window = File(
    'windows/runner/floating_lyric_window.cpp',
  ).readAsStringSync();
  final String flutterWindow = File(
    'windows/runner/flutter_window.cpp',
  ).readAsStringSync();
  final String controller = File(
    'lib/src/lookup/gal_hook_text_overlay_controller.dart',
  ).readAsStringSync();
  final String channel = File(
    'lib/src/platform/gal_hook_text_overlay_channel.dart',
  ).readAsStringSync();

  test('① 文案是一张共享表，两个工具条宿主都接了提示', () {
    expect(
      toolbarCpp.contains('void SetSlotTooltips(std::vector<std::wstring>'),
      isTrue,
      reason: '文案表的唯一写入口必须是 hook_toolbar::SetSlotTooltips',
    );
    // 两个宿主各自持有一个 SlotTooltipHost，但文案都从共享表来（Update 内部
    // 只拿到 slot 下标，自己去 SlotTooltip 查）。宿主绝不许自带文案数组。
    expect(
      toolbarHeader.contains('hook_toolbar::SlotTooltipHost tooltip_;'),
      isTrue,
      reason: '穿透工具条窗必须持有 SlotTooltipHost',
    );
    expect(
      File('windows/runner/floating_lyric_window.h')
          .readAsStringSync()
          .contains('hook_toolbar::SlotTooltipHost slot_tooltip_;'),
      isTrue,
      reason: '正文内工具条（body 窗）必须持有 SlotTooltipHost',
    );
    // Update 的签名只吃 slot + 屏幕坐标：文案不经过宿主，宿主就没法各说各话。
    expect(
      RegExp(
        r'void Update\(HWND owner, int slot, int screen_x, int screen_y\);',
      ).hasMatch(toolbarHeader),
      isTrue,
      reason: 'Update 只接受槽位下标；文案一旦经宿主传入就不再是单一真相',
    );
    // 隐藏 / 按下 / 离开三处都要收掉提示，否则会留一块孤儿浮在桌面上。
    for (final String host in <String>[toolbarCpp, window]) {
      expect(
        RegExp(r'(tooltip_|slot_tooltip_)\.Hide\(\);').allMatches(host).length,
        greaterThanOrEqualTo(3),
        reason: 'Hide() / WM_MOUSELEAVE / WM_LBUTTONDOWN 三处都必须收掉提示',
      );
    }
  });

  test('② TTM_TRACKPOSITION 负坐标不截断（多显示器）', () {
    expect(
      RegExp(
        r'TTM_TRACKPOSITION, 0,\s*'
        r'MAKELPARAM\(static_cast<WORD>\(static_cast<SHORT>\(screen_x\)\),\s*'
        r'static_cast<WORD>\(static_cast<SHORT>\(screen_y\)\)\)\);',
      ).hasMatch(toolbarCpp),
      isTrue,
      reason:
          'TTM_TRACKPOSITION 坐标必须先窄化成 SHORT 再取无符号位模式；'
          '裸 static_cast<WORD> 会把副屏的负坐标截成 65000+，提示飞出屏幕',
    );
    // 反向：整份源码里不许再出现「直接把 screen_* 塞进 WORD」的写法。
    expect(
      RegExp(r'static_cast<WORD>\(screen_[xy]\)').hasMatch(toolbarCpp),
      isFalse,
      reason: '不得对屏幕坐标做裸 WORD 窄化（负坐标会被截断）',
    );
  });

  test('③ lpszText 指向自持串，不是共享表的内部缓冲', () {
    expect(
      toolbarHeader.contains('std::wstring current_text_;'),
      isTrue,
      reason: 'SlotTooltipHost 必须自持一份文案',
    );
    expect(
      RegExp(
        r'current_text_ = text;\s*tool_\.lpszText = current_text_\.data\(\);',
      ).hasMatch(toolbarCpp),
      isTrue,
      reason:
          'lpszText 必须指向自持的 current_text_；'
          '指向 SlotTooltip 返回的共享表元素会在下一次 SetSlotTooltips 后悬垂',
    );
    // 反向：不许把共享表元素的缓冲直接交给 comctl32。
    expect(
      RegExp(r'lpszText = const_cast<wchar_t\*>\(text\.').hasMatch(toolbarCpp),
      isFalse,
      reason: 'lpszText 不得指向 SlotTooltip 返回的引用（整表 move 后悬垂）',
    );
  });

  test('④ comctl32 初始化一次且失败静默降级', () {
    expect(
      RegExp(
        r'static const bool common_controls_ready = \[\] \{[\s\S]{0,400}?'
        r'InitCommonControlsEx\(&icc\) != FALSE;',
      ).hasMatch(toolbarCpp),
      isTrue,
      reason: 'InitCommonControlsEx 必须挂在 function-local static 上只做一次',
    );
    expect(
      RegExp(
        r'if \(!common_controls_ready\) \{\s*return false;\s*\}',
      ).hasMatch(toolbarCpp),
      isTrue,
      reason:
          '初始化失败必须 return false 静默降级——'
          '工具条是穿透模式下唯一的逃生口，绝不许因为没有提示而崩',
    );
    expect(
      RegExp(
        r'if \(hwnd_ == nullptr\) \{\s*return false;\s*\}',
      ).hasMatch(toolbarCpp),
      isTrue,
      reason: 'CreateWindowExW 失败同样必须静默降级',
    );
  });

  test('⑤ hook 槽位几何单一真相', () {
    // 命中只有一个入口。
    expect(
      RegExp(
        r'int FloatingLyricWindow::HookToolbarSlotAt\(float x, float y\)',
      ).hasMatch(window),
      isTrue,
      reason: 'HookToolbarSlotAt 必须存在',
    );
    expect(
      RegExp(
        r'const int slot = HookToolbarSlotAt\(x, y\);\s*'
        r'return slot >= 0 \? hook_toolbar::kSlotActions\[slot\]',
      ).hasMatch(window),
      isTrue,
      reason:
          'ControlActionAt 的 hook 分支必须走 HookToolbarSlotAt——'
          '命中与悬停提示必须指同一颗按钮',
    );
    // 行宽 / 行起点在整份源码里各只算一次；绘制与穿透工具条窗定位都问它。
    expect(
      RegExp(r'btn \* kHookTextControlSlotCount \+').allMatches(window).length,
      1,
      reason: '一行按钮的总宽只允许在 HookToolbarRowWidth 里算一次',
    );
    expect(
      RegExp(r'HookToolbarRowLeft\(').allMatches(window).length,
      greaterThanOrEqualTo(4),
      reason:
          '声明 + 定义 + 绘制 + 穿透工具条窗定位；'
          '任何一处自己算居中起点，提示就会指着隔壁那颗按钮',
    );
    // 槽位几何必须用 hook 专属的按钮尺寸常量：kButtonSizeDip(30/10) 与
    // kHookTextButtonSizeDip(32/4) 不同，混用会让命中整体偏移。
    expect(
      RegExp(
        r'float FloatingLyricWindow::HookToolbarRowWidth\(\) const \{\s*'
        r'const float btn = ScaleForDpi\(kHookTextButtonSizeDip\);\s*'
        r'const float gap = ScaleForDpi\(kHookTextButtonGapDip\);',
      ).hasMatch(window),
      isTrue,
      reason: 'hook 工具条必须用 kHookTextButton*Dip，不是通用的 kButton*Dip',
    );
  });

  test('⑥ 提示条数与 native 槽位数同长，且键都在 i18n 里', () {
    final Match? table = RegExp(
      r'constexpr const char\* kSlotActions\[kSlotCount\] = \{([\s\S]*?)\};',
    ).firstMatch(toolbarHeader);
    expect(table, isNotNull, reason: 'kSlotActions 表必须存在');
    final int slotCount = RegExp(
      r'"[a-zA-Z]+",',
    ).allMatches(table!.group(1)!).length;
    expect(slotCount, 9, reason: 'kSlotActions 当前是 9 槽');

    final Match? tooltips = RegExp(
      r'List<String> get _slotTooltips => <String>\[([\s\S]*?)\];',
    ).firstMatch(controller);
    expect(tooltips, isNotNull, reason: '_slotTooltips 必须存在');
    final List<String> keys = RegExp(r't\.(game_hook_btn_[a-z]+)')
        .allMatches(tooltips!.group(1)!)
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    expect(
      keys.length,
      slotCount,
      reason:
          '提示条数必须与 native 槽位数一致——少一条就整体错位，'
          '第 N 颗按钮会顶着第 N-1 颗的说明',
    );

    final Map<String, dynamic> en =
        jsonDecode(File('lib/i18n/strings.i18n.json').readAsStringSync())
            as Map<String, dynamic>;
    for (final String key in keys) {
      expect(
        en.containsKey(key),
        isTrue,
        reason: 'i18n 缺 key $key（必须用 tool/i18n_sync.dart 新增）',
      );
    }

    // 载荷键名两侧对齐；不传时 native 侧就是无提示（老 payload 行为）。
    expect(
      channel.contains("'slotTooltips': slotTooltips"),
      isTrue,
      reason: 'channel 必须把 slotTooltips 放进 show 载荷',
    );
    expect(
      flutterWindow.contains('WideListFromValue(args,'),
      isTrue,
      reason: 'native show 处理必须解析 slotTooltips 载荷',
    );
    expect(
      RegExp(r'hook_toolbar::SetSlotTooltips\(').hasMatch(flutterWindow),
      isTrue,
      reason: 'native 必须把解析出来的文案下发到共享表',
    );
  });
}

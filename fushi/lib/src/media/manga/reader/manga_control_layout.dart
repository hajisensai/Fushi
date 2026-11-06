/// 漫画阅读器工具栏按钮的可视化布局模型（与小说阅读器 `ReaderControlLayout`、视频页
/// `VideoControlLayout` 同一套泛型骨架 `ControlLayout<S, I>`）。
///
/// 漫画 chrome 的几何与小说不同：返回键与标题胶囊是顶栏固定件（不进布局），可编辑的
/// 只有三处——右上角动作胶囊（[MangaControlSlot.top]，默认平铺、放不下才按优先级收进
/// ⋯）、底部悬浮纯图标工具栏（[MangaControlSlot.toolbar]，窄屏放不下按优先级降到右上
/// 角）、恒在 ⋯ 里的「更多」（[MangaControlSlot.overflow]）。另有 hidden（移出阅读器）。
///
/// 每颗按钮有一个固定的收起优先级 [MangaControlItem.foldPriority]（越大越晚收起），
/// 数值沿用布局化之前写死在页面里的那张表——出厂布局下旧有按钮的顺序与收起次序与
/// 旧版一致。唯一可见变化是右上角新增的书签键：它多占一格，窄屏下其它顶栏按钮会比
/// 旧版早一步收进 ⋯。
///
/// 持久化键 `manga_control_layout`（宽窗）/ `manga_control_layout_compact`（窄窗），
/// JSON `{version:1, slots:{...}, removed:[...]}`（与阅读器同形）。
library;

import 'dart:convert';

import 'package:fushi/src/controls/control_layout.dart';

enum MangaControlSlot implements ControlSlotSpec {
  /// 右上角动作胶囊（默认全部平铺，宽度放不下时按优先级收进 ⋯）。
  top('top'),

  /// 底部悬浮纯图标工具栏（拇指区）。窄屏放不下时按优先级降到右上角。
  toolbar('toolbar'),

  /// 「更多」菜单：恒在右上角 ⋯ 里，不占工具栏位置。
  overflow('overflow'),
  hidden('hidden');

  const MangaControlSlot(this.storageValue);

  @override
  final String storageValue;

  /// 编辑器上的可放置区（hidden 是编辑器自己的托盘，也在这里列出以便菜单遍历）。
  static const List<MangaControlSlot> editableSlots = <MangaControlSlot>[
    top,
    toolbar,
    overflow,
    hidden,
  ];
}

enum MangaControlItem implements ControlItemSpec<MangaControlSlot> {
  /// 章节目录（只有书架在线条目才渲染）。
  chapters('chapters', foldPriority: 8, recoverySlot: MangaControlSlot.toolbar),

  /// 页面一览（全部页缩略图网格）。
  pageGrid('pageGrid', foldPriority: 4, recoverySlot: MangaControlSlot.toolbar),

  /// 阅读模式（spread ↔ webtoon）。
  readingMode(
    'readingMode',
    foldPriority: 6,
    recoverySlot: MangaControlSlot.toolbar,
  ),

  /// 单双页偏好循环（只在 spread 模式渲染）。
  spreadPreference(
    'spreadPreference',
    foldPriority: 3,
    recoverySlot: MangaControlSlot.toolbar,
  ),

  /// 翻页方向（RTL ↔ LTR）。
  direction(
    'direction',
    foldPriority: 2,
    recoverySlot: MangaControlSlot.toolbar,
  ),

  /// 快捷设置面板。
  quickSettings(
    'quickSettings',
    foldPriority: 10,
    recoverySlot: MangaControlSlot.toolbar,
  ),

  /// 识别框开关：只在 Apple 设计系统下作为按钮渲染（Material 下是底部 FAB）。
  ocrBoxes(
    'ocrBoxes',
    foldPriority: 100,
    recoverySlot: MangaControlSlot.toolbar,
  ),

  /// 取消整卷 OCR（任务运行中才渲染）。
  ocrCancel('ocrCancel', foldPriority: 9, recoverySlot: MangaControlSlot.top),

  /// 窗口全屏（桌面才渲染）。
  fullscreen('fullscreen', foldPriority: 7, recoverySlot: MangaControlSlot.top),

  /// 书签面板（有持久书行时才渲染；在线源预览没有书身份）。
  bookmarks('bookmarks', foldPriority: 6, recoverySlot: MangaControlSlot.top),

  /// 全部设置（阅读设置侧板）。必需：它是本布局编辑器在阅读器内的入口。
  settings(
    'settings',
    foldPriority: 5,
    pinnedRequired: true,
    recoverySlot: MangaControlSlot.top,
  ),

  /// 识别本卷（OCR 触发方式为「手动」时才渲染）。
  ocrVolume('ocrVolume', foldPriority: 4, recoverySlot: MangaControlSlot.top),

  /// 回到开头。
  backToStart(
    'backToStart',
    foldPriority: 1,
    recoverySlot: MangaControlSlot.top,
  ),

  /// 重新识别本卷（已有识别结果时才渲染）。
  ocrRerun('ocrRerun', foldPriority: 1, recoverySlot: MangaControlSlot.top),

  /// 隐藏界面（与快捷键 M / 手柄 Y 同一执行体）。
  hideChrome('hideChrome', foldPriority: 0, recoverySlot: MangaControlSlot.top);

  const MangaControlItem(
    this.storageValue, {
    required this.foldPriority,
    required this.recoverySlot,
    this.pinnedRequired = false,
  });

  @override
  final String storageValue;

  /// 收起优先级：越大越晚收起（底部放不下时越晚降到右上角，右上角放不下时越晚
  /// 收进 ⋯）。沿用布局化之前的写死数值。
  final int foldPriority;

  @override
  final bool pinnedRequired;

  @override
  final MangaControlSlot recoverySlot;

  /// 漫画触屏与桌面共用同一套 chrome，没有「触屏才必需」的按钮。
  @override
  bool get pinnedOnTouch => false;

  @override
  bool get isSingleInstance => true;

  /// 任何按钮都能去任意可见区；必需项不能移出阅读器。
  @override
  bool canMoveToSlot(MangaControlSlot target, {bool isTouchControls = false}) {
    if (target == MangaControlSlot.hidden) return !pinnedRequired;
    return true;
  }

  static MangaControlItem? fromStorage(String value) {
    for (final MangaControlItem item in values) {
      if (item.storageValue == value) return item;
    }
    return null;
  }
}

const ControlLayoutScheme<MangaControlSlot, MangaControlItem>
kMangaControlScheme = ControlLayoutScheme<MangaControlSlot, MangaControlItem>(
  slots: MangaControlSlot.values,
  hiddenSlot: MangaControlSlot.hidden,
  items: MangaControlItem.values,
);

/// 窄于此宽度（逻辑 px，MD3 compact window class 上界）用窄窗布局（与小说阅读器同
/// 一判据）。
const double kMangaControlCompactWidth = 600;

/// 漫画按钮布局：`ControlLayout` 的薄包装，负责出厂布局与 JSON 编解码。
class MangaControlLayout {
  const MangaControlLayout._(this.core);

  final ControlLayout<MangaControlSlot, MangaControlItem> core;

  factory MangaControlLayout.fromCore(
    ControlLayout<MangaControlSlot, MangaControlItem> core,
  ) => MangaControlLayout._(core);

  /// 出厂布局 = 布局化之前写死的那一套 + 新增的书签键：
  ///  * 底部工具栏：章节目录 / 页面一览 / 阅读模式 / 单双页 / 翻页方向 / 快捷设置
  ///    （/ Apple 下的识别框开关）——与旧 `_chromeActionGroups` 的声明顺序一致；
  ///  * 右上角：按旧版「按优先级从高到低」排好的顺序（取消 OCR 9 / 全屏 7 / 书签 6 /
  ///    全部设置 5 / 识别本卷 4 / 回到开头 1 / 重新识别 1 / 隐藏界面 0）。书签是新增项，
  ///    按它的优先级插在全屏与全部设置之间。
  static final MangaControlLayout defaults = MangaControlLayout._(
    ControlLayout<MangaControlSlot, MangaControlItem>.fromSlots(
      kMangaControlScheme,
      <MangaControlSlot, List<MangaControlItem>>{
        MangaControlSlot.toolbar: <MangaControlItem>[
          MangaControlItem.chapters,
          MangaControlItem.pageGrid,
          MangaControlItem.readingMode,
          MangaControlItem.spreadPreference,
          MangaControlItem.direction,
          MangaControlItem.quickSettings,
          MangaControlItem.ocrBoxes,
        ],
        MangaControlSlot.top: <MangaControlItem>[
          MangaControlItem.ocrCancel,
          MangaControlItem.fullscreen,
          MangaControlItem.bookmarks,
          MangaControlItem.settings,
          MangaControlItem.ocrVolume,
          MangaControlItem.backToStart,
          MangaControlItem.ocrRerun,
          MangaControlItem.hideChrome,
        ],
      },
    ),
  );

  /// 窄窗（手机竖屏）出厂布局：与宽窗相同——旧版本来就不分宽窄，窄屏的差异由
  /// 「放不下按优先级降到右上角 / 收进 ⋯」在运行时处理。
  static final MangaControlLayout compactDefaults = MangaControlLayout._(
    defaults.core,
  );

  static Map<MangaControlItem, MangaControlSlot> _defaultAssignments(
    MangaControlLayout base,
  ) => <MangaControlItem, MangaControlSlot>{
    for (final MangaControlItem item in MangaControlItem.values)
      item: base.core.slotOf(item),
  };

  List<MangaControlItem> itemsIn(MangaControlSlot slot) => core.itemsIn(slot);

  String encode() {
    final List<String> removed = core.encodeRemoved();
    return jsonEncode(<String, Object>{
      'version': 1,
      'slots': core.encodeSlots(),
      if (removed.isNotEmpty) 'removed': removed,
    });
  }

  /// 空 / 坏 JSON → [fallback]（缺省 = 宽窗出厂布局）；一个可见按钮都没有 →
  /// [fallback]。JSON 里缺席的按钮按 [fallback] 的位置回填（以后新增按钮时存量布局
  /// 自动带上它）。
  static MangaControlLayout decode(
    String json, {
    MangaControlLayout? fallback,
  }) {
    final MangaControlLayout base = fallback ?? defaults;
    if (json.trim().isEmpty) return base;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return base;
      final Object? slotsRaw = raw['slots'];
      if (slotsRaw is! Map<String, dynamic>) return base;
      final ControlLayout<MangaControlSlot, MangaControlItem>? core =
          ControlLayout.decodeSlots<MangaControlSlot, MangaControlItem>(
            kMangaControlScheme,
            slotsRaw,
            removedRaw: raw['removed'],
            fallbackAssignments: _defaultAssignments(base),
          );
      return core == null ? base : MangaControlLayout._(core);
    } catch (_) {
      return base;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MangaControlLayout && other.core == core;

  @override
  int get hashCode => core.hashCode;
}

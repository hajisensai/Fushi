/// 歌词模式（有声书播放页）次要按钮的可视化布局模型（与小说阅读器
/// `ReaderControlLayout`、漫画 `MangaControlLayout` 同一套泛型骨架
/// `ControlLayout<S, I>`）。
///
/// 播放键行（−10 秒 / 上一句 / 播放 / 下一句 / +10 秒）、进度条、⋯ 与 × 是播放页的
/// 固定件，不进布局；可编辑的是其余次要按钮落在哪儿：
///  * [LyricsControlSlot.toolbar]：播放卡里的工具条（MD3 播放卡次要按钮组 / Apple
///    宽屏面板底部小按钮行 / Apple 窄屏播放键两侧）；
///  * [LyricsControlSlot.top]：顶部（MD3 窄屏顶栏胶囊 / 宽屏底板右上角 / Apple 页眉）；
///  * [LyricsControlSlot.overflow]：收进 ⋯ 菜单（排在阅读器动作之前）；
///  * hidden：移出歌词页（快捷键照常可用）。
///
/// 宽屏（双栏）与窄屏（手机竖屏）各存一份：持久化键 `lyrics_control_layout` /
/// `lyrics_control_layout_compact`，JSON `{version:1, slots:{...}, removed:[...]}`
/// （与阅读器 / 漫画同形）。
library;

import 'dart:convert';

import 'package:fushi/src/controls/control_layout.dart';

enum LyricsControlSlot implements ControlSlotSpec {
  /// 顶部（窄屏顶栏胶囊 / 宽屏右上角）。
  top('top'),

  /// 播放卡工具条。
  toolbar('toolbar'),

  /// 「更多」菜单：恒在 ⋯ 里。
  overflow('overflow'),
  hidden('hidden');

  const LyricsControlSlot(this.storageValue);

  @override
  final String storageValue;

  /// 编辑器上的可放置区（含 hidden 托盘，便于菜单遍历）。
  static const List<LyricsControlSlot> editableSlots = <LyricsControlSlot>[
    top,
    toolbar,
    overflow,
    hidden,
  ];
}

enum LyricsControlItem implements ControlItemSpec<LyricsControlSlot> {
  /// 倍速面板。
  speed('speed'),

  /// 停 / 续阅读统计计时（与阅读器顶栏计时键、快捷键 P 同一入口）。
  studyTimer('studyTimer'),

  /// 重播当前句。
  replayCue('replayCue'),

  /// 歌词遮罩（听力沉浸模糊）。
  mask('mask'),

  /// Aa 歌词文字面板。
  typography('typography'),

  /// 阅读统计侧栏。
  statistics('statistics'),

  /// 回到书籍模式（正文）。窄屏左上角已有返回键，出厂只在宽屏摆出。
  bookMode('bookMode'),

  /// 宽屏左右互换（窄屏单栏时不渲染）。
  swapSides('swapSides');

  const LyricsControlItem(this.storageValue);

  @override
  final String storageValue;

  /// 歌词页没有「移走就再也找不到」的按钮：⋯ 与返回键是固定件，任何次要按钮都能
  /// 移出。
  @override
  bool get pinnedRequired => false;

  @override
  bool get pinnedOnTouch => false;

  @override
  bool get isSingleInstance => true;

  @override
  LyricsControlSlot get recoverySlot => LyricsControlSlot.toolbar;

  @override
  bool canMoveToSlot(
    LyricsControlSlot target, {
    bool isTouchControls = false,
  }) => true;
}

const ControlLayoutScheme<LyricsControlSlot, LyricsControlItem>
kLyricsControlScheme =
    ControlLayoutScheme<LyricsControlSlot, LyricsControlItem>(
      slots: LyricsControlSlot.values,
      hiddenSlot: LyricsControlSlot.hidden,
      items: LyricsControlItem.values,
    );

/// 歌词按钮布局：`ControlLayout` 的薄包装，负责出厂布局与 JSON 编解码。
class LyricsControlLayout {
  const LyricsControlLayout._(this.core);

  final ControlLayout<LyricsControlSlot, LyricsControlItem> core;

  factory LyricsControlLayout.fromCore(
    ControlLayout<LyricsControlSlot, LyricsControlItem> core,
  ) => LyricsControlLayout._(core);

  /// 宽屏出厂布局 = 布局化之前 MD3 宽屏的摆法（睡眠定时换成统计计时键）：播放卡
  /// 工具条 倍速 / 计时 / 重播 / 遮罩 / Aa / 统计，右上角 书籍模式 / 左右互换。
  static final LyricsControlLayout defaults = LyricsControlLayout._(
    ControlLayout<LyricsControlSlot, LyricsControlItem>.fromSlots(
      kLyricsControlScheme,
      <LyricsControlSlot, List<LyricsControlItem>>{
        LyricsControlSlot.toolbar: <LyricsControlItem>[
          LyricsControlItem.speed,
          LyricsControlItem.studyTimer,
          LyricsControlItem.replayCue,
          LyricsControlItem.mask,
          LyricsControlItem.typography,
          LyricsControlItem.statistics,
        ],
        LyricsControlSlot.top: <LyricsControlItem>[
          LyricsControlItem.bookMode,
          LyricsControlItem.swapSides,
        ],
      },
    ),
  );

  /// 窄屏出厂布局 = 布局化之前 MD3 窄屏的摆法：顶栏胶囊 遮罩 / Aa / 统计，播放卡
  /// 头行 倍速 / 计时 / 重播。书籍模式（左上角已有返回键）与左右互换（单栏无意义）
  /// 出厂移出。
  static final LyricsControlLayout compactDefaults = LyricsControlLayout._(
    ControlLayout<LyricsControlSlot, LyricsControlItem>.fromSlots(
      kLyricsControlScheme,
      <LyricsControlSlot, List<LyricsControlItem>>{
        LyricsControlSlot.top: <LyricsControlItem>[
          LyricsControlItem.mask,
          LyricsControlItem.typography,
          LyricsControlItem.statistics,
        ],
        LyricsControlSlot.toolbar: <LyricsControlItem>[
          LyricsControlItem.speed,
          LyricsControlItem.studyTimer,
          LyricsControlItem.replayCue,
        ],
      },
      removedItems: <LyricsControlItem>{
        LyricsControlItem.bookMode,
        LyricsControlItem.swapSides,
      },
    ),
  );

  static Map<LyricsControlItem, LyricsControlSlot> _defaultAssignments(
    LyricsControlLayout base,
  ) => <LyricsControlItem, LyricsControlSlot>{
    for (final LyricsControlItem item in LyricsControlItem.values)
      item: base.core.slotOf(item),
  };

  List<LyricsControlItem> itemsIn(LyricsControlSlot slot) => core.itemsIn(slot);

  String encode() {
    final List<String> removed = core.encodeRemoved();
    return jsonEncode(<String, Object>{
      'version': 1,
      'slots': core.encodeSlots(),
      if (removed.isNotEmpty) 'removed': removed,
    });
  }

  /// 空 / 坏 JSON → [fallback]（缺省 = 宽屏出厂布局）；一个可见按钮都没有且没有
  /// 显式移除 → [fallback]。JSON 里缺席的按钮按 [fallback] 的位置回填（以后新增
  /// 按钮时存量布局自动带上它）。
  static LyricsControlLayout decode(
    String json, {
    LyricsControlLayout? fallback,
  }) {
    final LyricsControlLayout base = fallback ?? defaults;
    if (json.trim().isEmpty) return base;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return base;
      final Object? slotsRaw = raw['slots'];
      if (slotsRaw is! Map<String, dynamic>) return base;
      final ControlLayout<LyricsControlSlot, LyricsControlItem>? core =
          ControlLayout.decodeSlots<LyricsControlSlot, LyricsControlItem>(
            kLyricsControlScheme,
            slotsRaw,
            removedRaw: raw['removed'],
            fallbackAssignments: _defaultAssignments(base),
          );
      return core == null ? base : LyricsControlLayout._(core);
    } catch (_) {
      return base;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LyricsControlLayout && other.core == core;

  @override
  int get hashCode => core.hashCode;
}

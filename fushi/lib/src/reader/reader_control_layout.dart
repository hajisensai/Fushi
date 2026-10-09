/// 阅读器顶栏 / 底栏按钮的可视化布局模型（与视频页 `VideoControlLayout` 同一套
/// 泛型骨架 `ControlLayout<S, I>`，用户 2026-09-13 要求「和视频一样支持可视化调整」）。
///
/// 六个可见槽位 + hidden：顶栏左 / 中 / 右、底栏左 / 中 / 右。顶栏中间只放书名；
/// 书名也只能在顶栏中间（或移出）。返回与设置是必需项：任何平台都不能移出——返回是
/// 退书的唯一可见入口（BUG-2230 同一口径），设置是其它所有面板的入口。
///
/// 悬浮球不是这里的槽：它的按钮在 设置 → 悬浮球 → 阅读器 里勾选
/// （`docs/specs/2026-09-28-floating-ball.md`）。旧版布局 JSON 里的 `floatingBall`
/// 槽解码时按未知槽丢弃，里面的按钮回落到出厂位置（有声书传输键在托盘）。
///
/// 持久化键 `reader_control_layout`，JSON `{version:1, slots:{...}, removed:[...]}`
/// （与视频 v3 同形；阅读器没有历史布局，不需要迁移）。
library;

import 'dart:convert';

import 'package:fushi/src/controls/control_layout.dart';

enum ReaderControlSlot implements ControlSlotSpec {
  topLeft('topLeft'),
  topCenter('topCenter'),
  topRight('topRight'),
  bottomLeft('bottomLeft'),
  bottomCenter('bottomCenter'),
  bottomRight('bottomRight'),

  /// 「更多」溢出菜单（⋯）：按钮仍可用，但不占工具栏位置（2026-10 工具栏精简：
  /// 中频按钮收进这里）。悬浮 / 贴边两种工具栏样式都把它画成末尾的 ⋯ 菜单。
  overflow('overflow'),
  hidden('hidden');

  const ReaderControlSlot(this.storageValue);

  @override
  final String storageValue;

  bool get isTop =>
      this == ReaderControlSlot.topLeft ||
      this == ReaderControlSlot.topCenter ||
      this == ReaderControlSlot.topRight;

  bool get isBottom =>
      this == ReaderControlSlot.bottomLeft ||
      this == ReaderControlSlot.bottomCenter ||
      this == ReaderControlSlot.bottomRight;

  /// 编辑器舞台上的槽位（不含 hidden，hidden 是编辑器自己的托盘）：顶栏三区、
  /// 底栏三区、「更多」菜单。
  static const List<ReaderControlSlot> editableSlots = <ReaderControlSlot>[
    topLeft,
    topCenter,
    topRight,
    bottomLeft,
    bottomCenter,
    bottomRight,
    overflow,
  ];
}

enum ReaderControlItem implements ControlItemSpec<ReaderControlSlot> {
  /// ← 退书（maybePop → PopScope 落位置 / 关书同步）。必需。
  back('back', pinnedRequired: true, recoverySlot: ReaderControlSlot.topLeft),

  /// 歌词 / 书模式切换（只在挂了有声书控制器时渲染）。
  modeToggle('modeToggle', recoverySlot: ReaderControlSlot.topLeft),

  /// 目录 / 搜索 / 收藏（左侧导航抽屉）。
  navigation('navigation', recoverySlot: ReaderControlSlot.topLeft),

  /// 插图册。
  gallery('gallery', recoverySlot: ReaderControlSlot.topLeft),

  /// 书内统计侧栏。
  statistics('statistics', recoverySlot: ReaderControlSlot.topLeft),

  /// 暂停 / 继续阅读统计计时（与状态行计时键、快捷键 P 同一入口）。出厂在托盘，
  /// 悬浮球出厂带上它（见 设置 → 悬浮球 → 阅读器）；可拖去顶栏 / 底栏。
  studyTimer('studyTimer', recoverySlot: ReaderControlSlot.topRight),

  /// 书名（只能在顶栏中间）。
  title('title', recoverySlot: ReaderControlSlot.topCenter),

  /// 有声书：已挂 → 面板；未挂 → 导入。「听书」模块关掉时不渲染。
  audiobook('audiobook', recoverySlot: ReaderControlSlot.topRight),

  /// 窗口全屏（桌面）。
  fullscreen('fullscreen', recoverySlot: ReaderControlSlot.topRight),

  /// 关掉 / 开回顶栏和底栏（与 设置 → 阅读界面 的开关同一个偏好）。出厂在托盘。
  /// 栏关掉后由悬浮球接管：这颗键连同返回、设置被固定在球上（见
  /// [kReaderToolbarsTakeoverItems]），开回来的入口就是球上的它。
  toolbars('toolbars', recoverySlot: ReaderControlSlot.topRight),

  /// 外观 / 阅读设置抽屉。必需。
  settings(
    'settings',
    pinnedRequired: true,
    recoverySlot: ReaderControlSlot.topRight,
  ),

  // ── 有声书传输键（只在挂了有声书控制器时渲染）。出厂都在托盘（悬浮球出厂放
  // 上一句 / 播放暂停 / 下一句，见 设置 → 悬浮球）；都可以拖去顶栏 / 底栏。上一句 /
  // 下一句跟随「跳转方式」偏好（按句或按 N 秒），与底栏播放条同一语义。
  audiobookPrev('audiobookPrev', recoverySlot: ReaderControlSlot.bottomCenter),
  audiobookPlayPause(
    'audiobookPlayPause',
    recoverySlot: ReaderControlSlot.bottomCenter,
  ),
  audiobookNext('audiobookNext', recoverySlot: ReaderControlSlot.bottomCenter),
  audiobookSeekBack(
    'audiobookSeekBack',
    recoverySlot: ReaderControlSlot.bottomCenter,
  ),
  audiobookSeekForward(
    'audiobookSeekForward',
    recoverySlot: ReaderControlSlot.bottomCenter,
  ),
  audiobookFollow(
    'audiobookFollow',
    recoverySlot: ReaderControlSlot.bottomCenter,
  );

  const ReaderControlItem(
    this.storageValue, {
    this.pinnedRequired = false,
    required this.recoverySlot,
  });

  @override
  final String storageValue;

  @override
  final bool pinnedRequired;

  /// 阅读器没有「触屏才必需」的按钮：触屏与桌面共用同一套 chrome。
  @override
  bool get pinnedOnTouch => false;

  /// 所有阅读器按钮都是单实例（同一颗不该出现在两处）。
  @override
  bool get isSingleInstance => true;

  @override
  final ReaderControlSlot recoverySlot;

  /// 有声书传输键（上一句 / 播放暂停 / 下一句 / ±10s / 跟随）。
  bool get isAudiobookTransport => switch (this) {
        ReaderControlItem.audiobookPrev ||
        ReaderControlItem.audiobookPlayPause ||
        ReaderControlItem.audiobookNext ||
        ReaderControlItem.audiobookSeekBack ||
        ReaderControlItem.audiobookSeekForward ||
        ReaderControlItem.audiobookFollow =>
          true,
        _ => false,
      };

  @override
  bool canMoveToSlot(ReaderControlSlot target, {bool isTouchControls = false}) {
    if (target == ReaderControlSlot.hidden) return !pinnedRequired;
    // 顶栏中间只收书名；书名只去顶栏中间。
    if (this == ReaderControlItem.title) {
      return target == ReaderControlSlot.topCenter;
    }
    // 返回是退书的唯一可见入口（BUG-2230 口径），不许藏进「更多」多一步。
    if (this == ReaderControlItem.back &&
        target == ReaderControlSlot.overflow) {
      return false;
    }
    return target != ReaderControlSlot.topCenter;
  }

  static ReaderControlItem? fromStorage(String value) {
    for (final ReaderControlItem item in values) {
      if (item.storageValue == value) return item;
    }
    return null;
  }
}

/// 顶栏和底栏被关掉后，悬浮球**必带**的按钮（不看 设置 → 悬浮球 → 阅读器 的勾选，
/// 按此顺序排在球的最上面、离球最远）：布局里的必需项（返回 = 退书的唯一可见入口、
/// 设置 = 其它所有面板的入口，理由同 [ReaderControlItem.pinnedRequired]）+ 开回栏
/// 的那颗键。歌词模式另加模式切换键（页面追加，与顶栏在歌词模式强制保留它同理）。
const List<ReaderControlItem> kReaderToolbarsTakeoverItems =
    <ReaderControlItem>[
  ReaderControlItem.back,
  ReaderControlItem.settings,
  ReaderControlItem.toolbars,
];

/// 顶栏中间只有书名：其它按钮误进 topCenter 时挪回各自的 recoverySlot。
void _readerPostNormalize(
  Map<ReaderControlSlot, List<ReaderControlItem>> slots,
  Set<ReaderControlItem> removed,
) {
  final List<ReaderControlItem> center = slots[ReaderControlSlot.topCenter]!;
  for (final ReaderControlItem item in List<ReaderControlItem>.of(center)) {
    if (item == ReaderControlItem.title) continue;
    center.remove(item);
    final List<ReaderControlItem> home = slots[item.recoverySlot]!;
    if (!home.contains(item)) home.add(item);
  }
  for (final ReaderControlSlot slot in ReaderControlSlot.values) {
    if (slot == ReaderControlSlot.topCenter) continue;
    slots[slot]!.remove(ReaderControlItem.title);
  }
}

const ControlLayoutScheme<ReaderControlSlot, ReaderControlItem>
    kReaderControlScheme =
    ControlLayoutScheme<ReaderControlSlot, ReaderControlItem>(
  slots: ReaderControlSlot.values,
  hiddenSlot: ReaderControlSlot.hidden,
  items: ReaderControlItem.values,
  postNormalize: _readerPostNormalize,
);

/// 窄于此宽度（逻辑 px，MD3 compact window class 上界）用窄窗布局
/// （[ReaderControlLayout.compactDefaults] / 偏好 `reader_control_layout_compact`）。
const double kReaderControlCompactWidth = 600;

/// 阅读器按钮布局：`ControlLayout` 的薄包装，负责出厂布局与 JSON 编解码。
class ReaderControlLayout {
  const ReaderControlLayout._(this.core);

  final ControlLayout<ReaderControlSlot, ReaderControlItem> core;

  factory ReaderControlLayout.fromCore(
    ControlLayout<ReaderControlSlot, ReaderControlItem> core,
  ) =>
      ReaderControlLayout._(core);

  /// 宽窗（≥ [kReaderControlCompactWidth]）出厂布局（2026-10 工具栏精简，按使用频率
  /// 重排）：左「← 返回」，中「书名」（点它 = 打开导航），右主操作组「导航 /
  /// 有声书 / 阅读设置」；中频的「歌词模式 / 统计 / 插图 / 全屏」收进「更多」；
  /// 计时 / 开关栏 / 有声书传输键留在托盘（传输键由播放条与 FAB 承担）。
  ///
  /// 只影响**没有存过布局**的用户：存量布局 JSON 把每颗按钮都显式列在某个槽或
  /// removed 里，解码不经出厂表（[decode] 的 fallback 只回填 JSON 里缺席的按钮）。
  static final ReaderControlLayout defaults = ReaderControlLayout._(
    ControlLayout<ReaderControlSlot, ReaderControlItem>.fromSlots(
      kReaderControlScheme,
      <ReaderControlSlot, List<ReaderControlItem>>{
        ReaderControlSlot.topLeft: <ReaderControlItem>[
          ReaderControlItem.back,
        ],
        ReaderControlSlot.topCenter: <ReaderControlItem>[
          ReaderControlItem.title,
        ],
        ReaderControlSlot.topRight: <ReaderControlItem>[
          ReaderControlItem.navigation,
          ReaderControlItem.audiobook,
          ReaderControlItem.settings,
        ],
        ReaderControlSlot.overflow: <ReaderControlItem>[
          ReaderControlItem.modeToggle,
          ReaderControlItem.statistics,
          ReaderControlItem.gallery,
          ReaderControlItem.fullscreen,
        ],
      },
    ),
  );

  /// 窄窗（手机竖屏，< [kReaderControlCompactWidth]）出厂布局：顶部只留「← 返回 /
  /// 书名 / ⋯」，主操作下沉到拇指区的底部悬浮工具栏「导航 / 有声书 / 设置 /
  /// 统计」（等宽图标 + 小字标签）；有声书在场时 FAB 是变形播放键。
  static final ReaderControlLayout compactDefaults = ReaderControlLayout._(
    ControlLayout<ReaderControlSlot, ReaderControlItem>.fromSlots(
      kReaderControlScheme,
      <ReaderControlSlot, List<ReaderControlItem>>{
        ReaderControlSlot.topLeft: <ReaderControlItem>[
          ReaderControlItem.back,
        ],
        ReaderControlSlot.topCenter: <ReaderControlItem>[
          ReaderControlItem.title,
        ],
        ReaderControlSlot.bottomCenter: <ReaderControlItem>[
          ReaderControlItem.navigation,
          ReaderControlItem.audiobook,
          ReaderControlItem.settings,
          ReaderControlItem.statistics,
        ],
        ReaderControlSlot.overflow: <ReaderControlItem>[
          ReaderControlItem.modeToggle,
          ReaderControlItem.gallery,
          ReaderControlItem.fullscreen,
        ],
      },
    ),
  );

  static Map<ReaderControlItem, ReaderControlSlot> _defaultAssignments(
    ReaderControlLayout base,
  ) =>
      <ReaderControlItem, ReaderControlSlot>{
        for (final ReaderControlItem item in ReaderControlItem.values)
          item: base.core.slotOf(item),
      };

  List<ReaderControlItem> itemsIn(ReaderControlSlot slot) => core.itemsIn(slot);

  /// 顶栏 / 底栏任一槽位有可见按钮。
  bool get hasBottomItems => ReaderControlSlot.values
      .where((ReaderControlSlot s) => s.isBottom)
      .any((ReaderControlSlot s) => core.itemsIn(s).isNotEmpty);

  bool get showsTitle => core
      .itemsIn(ReaderControlSlot.topCenter)
      .contains(ReaderControlItem.title);

  String encode() {
    final List<String> removed = core.encodeRemoved();
    return jsonEncode(<String, Object>{
      'version': 1,
      'slots': core.encodeSlots(),
      if (removed.isNotEmpty) 'removed': removed,
    });
  }

  /// 空 / 坏 JSON → [fallback]（缺省 = 宽窗出厂布局）；一个可见按钮都没有 →
  /// [fallback]。JSON 里缺席的按钮按 [fallback] 的位置回填。
  static ReaderControlLayout decode(
    String json, {
    ReaderControlLayout? fallback,
  }) {
    final ReaderControlLayout base = fallback ?? defaults;
    if (json.trim().isEmpty) return base;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return base;
      final Object? slotsRaw = raw['slots'];
      if (slotsRaw is! Map<String, dynamic>) return base;
      final ControlLayout<ReaderControlSlot, ReaderControlItem>? core =
          ControlLayout.decodeSlots<ReaderControlSlot, ReaderControlItem>(
        kReaderControlScheme,
        slotsRaw,
        removedRaw: raw['removed'],
        fallbackAssignments: _defaultAssignments(base),
      );
      return core == null ? base : ReaderControlLayout._(core);
    } catch (_) {
      return base;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderControlLayout && other.core == core;

  @override
  int get hashCode => core.hashCode;
}

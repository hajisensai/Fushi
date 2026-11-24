import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/video_control_customization.dart';

// 视频播放器 Apple（Cupertino，`isGlassDesign`）外观的区域规划：方案 C「分层」
// （Apple TV app / AVKit 式，用户 2026-11-24 拍板，效果图
// `fushi/build/video_player_cupertino_design/index.html`），并按用户修改去掉画面
// 中央的大三键——播放 / 暂停、后退 10 秒、前进 10 秒并入底部控制条首位，画面中央
// 任何时候都不放控件。
//
// 区域（[VideoAppleChromePlan]）：
//
// - 左上：返回圆钮 + 靠左标题；
// - 右上：一枚玻璃胶囊，只放少量动作 + 全局唯一的「⋯」；
// - 底部：传输组（播放 / −10 / +10）起首，其后是前导簇，进度条与时间在中段（桌面
//   单行条里行内；触屏在胶囊上方独立一行），末尾是后随簇；
// - 屏幕左 / 右侧栏：沿用用户布局（沉浸锁等）。
//
// 用户布局（[VideoControlLayout]，8 槽 + hidden）到区域的映射是纯函数，规则见
// [planVideoAppleChrome]。只决定「哪个按钮落哪个区域、什么顺序」；放不下时的逐颗
// 收进「⋯」仍交给 `VideoControlBar` / `planVideoControlBar`，密度档判据不变。
// 本文件与设计系统无关（纯数据），MD3 / M3E 外观完全不读它。

/// 两种排版形态：桌面（macOS 宽窗：单行宽浮动条）与触屏（iOS 横屏：进度条一行 +
/// 左右两枚胶囊）。判据是控制条走桌面还是触屏那套（`_isDesktopVideoControls`），
/// 不是平台——平台只决定用不用 Apple 外观之外的东西，外观判据唯一是 `isGlassDesign`。
enum VideoAppleChromeForm { desktop, touch }

/// 一个按钮落在某区域的一次摆放：[sourceSlot] 是它在用户布局里的来源槽（浮层锚点 /
/// 「从哪个槽触发」的上下文沿用它，与 M3E 同一套执行体）。
@immutable
class VideoApplePlacement {
  const VideoApplePlacement(this.item, this.sourceSlot);

  final VideoControlItem item;
  final VideoControlSlot sourceSlot;

  @override
  bool operator ==(Object other) =>
      other is VideoApplePlacement &&
      other.item == item &&
      other.sourceSlot == sourceSlot;

  @override
  int get hashCode => Object.hash(item, sourceSlot);

  @override
  String toString() => '${item.name}@${sourceSlot.name}';
}

/// 方案 C 的区域规划结论。
@immutable
class VideoAppleChromePlan {
  const VideoAppleChromePlan({
    required this.showBack,
    required this.showTitle,
    required this.topTrailing,
    required this.transport,
    required this.bottomLeading,
    required this.bottomTrailing,
    required this.showPositionIndicator,
    required this.railsExclude,
    required this.extraFolded,
  });

  /// 左上返回圆钮。
  final bool showBack;

  /// 左上靠左标题。
  final bool showTitle;

  /// 右上玻璃胶囊里的按钮（「⋯」之前，按序）。
  final List<VideoApplePlacement> topTrailing;

  /// 底部条起首的传输组：播放 / 暂停、后退 10 秒、前进 10 秒（恒在，画面中央不再
  /// 放任何控件）。
  final List<VideoApplePlacement> transport;

  /// 传输组之后的前导簇（底部条左段；触屏是左胶囊里传输组之后）。
  final List<VideoApplePlacement> bottomLeading;

  /// 后随簇（底部条右段；触屏是右胶囊）。
  final List<VideoApplePlacement> bottomTrailing;

  /// 进度条两端的时间（已播 / 剩余）。
  final bool showPositionIndicator;

  /// 侧栏（screenLeft / screenRight）里要跳过的按钮：被本规划挪进别的区域的出厂项。
  final Set<VideoControlItem> railsExclude;

  /// 除「被用户移出播放器」之外额外进「⋯」的按钮（触屏的截图：方案 C iOS 收进「⋯」）。
  final List<VideoApplePlacement> extraFolded;

  /// 落在可见区域（不含侧栏）的全部按钮。
  Set<VideoControlItem> get placedItems => <VideoControlItem>{
    for (final VideoApplePlacement p in topTrailing) p.item,
    for (final VideoApplePlacement p in transport) p.item,
    for (final VideoApplePlacement p in bottomLeading) p.item,
    for (final VideoApplePlacement p in bottomTrailing) p.item,
  };
}

/// 传输组：恒在底部条首位（播放最显眼，其后 −10 / +10）。
const List<VideoControlItem> kVideoAppleTransportItems = <VideoControlItem>[
  VideoControlItem.playPause,
  VideoControlItem.seekBackward,
  VideoControlItem.seekForward,
];

/// 出厂布局里的按钮被方案 C 重新安家的去处（只对**留在出厂槽位**的那次摆放生效；
/// 用户亲手挪过的按钮一律按槽位映射，尊重用户的选择）。
enum _AppleHome { topTrailing, bottomTrailing, folded }

_AppleHome? _appleHomeOf(VideoControlItem item, VideoAppleChromeForm form) {
  switch (item) {
    // 「字幕」气泡与聊天回放：AVKit 右上（出厂在右下）。
    case VideoControlItem.subtitleTrack:
    case VideoControlItem.liveChat:
      return _AppleHome.topTrailing;
    // 字幕列表（学习侧栏）：出厂在屏幕右侧栏，方案 C 进底部条后随簇。
    case VideoControlItem.subtitleList:
      return _AppleHome.bottomTrailing;
    // 设置：macOS 底部条（全屏键之前）；iOS 右上常驻（触屏不可进「⋯」）。
    case VideoControlItem.settings:
      return form == VideoAppleChromeForm.desktop
          ? _AppleHome.bottomTrailing
          : _AppleHome.topTrailing;
    // 截图：macOS 右上；iOS 收进「⋯」。
    case VideoControlItem.screenshot:
      return form == VideoAppleChromeForm.desktop
          ? _AppleHome.topTrailing
          : _AppleHome.folded;
    default:
      return null;
  }
}

/// 把用户布局映射到方案 C 的区域。
///
/// 规则（逐次摆放判，按钮可在多个槽各放一份）：
///
/// 1. 播放 / 暂停、±10 秒是底部条首位的传输组，恒在；它们在别的顶部 / 底部槽的摆放
///    与「⋯」里的行一并去重（不会出现两份）。屏幕侧栏是用户的单手操作区，不动。
/// 2. 返回、标题：放在任一可见槽即在左上（返回圆钮 + 靠左标题）。
/// 3. 仍在**出厂槽位**（[VideoControlLayout.currentChrome]）的几颗按方案 C 重新安家：
///    字幕轨 / 聊天回放 → 右上；字幕列表 → 底部后随簇；设置 → 桌面底部后随簇、触屏右上；
///    截图 → 桌面右上、触屏「⋯」。
/// 4. 其余（含用户挪过的）按槽位：topLeft / topCenter / topRight → 右上胶囊；
///    bottomLeft / bottomCenter → 底部前导簇；bottomRight → 底部后随簇；
///    screenLeft / screenRight → 侧栏原样；hidden → 「⋯」（既有「移出播放器」规则）。
/// 5. 每个区域内同一按钮只出现一次；时间指示器只决定进度条两端显不显时间。
///
/// [renders] 是页面的运行期门控（合集 / 章节 / 平台 / 网页档等），不渲染的按钮不进
/// 任何区域（与 M3E 同一道门）。音量不经这道门（与既有底栏一致），只认底部槽位。
VideoAppleChromePlan planVideoAppleChrome({
  required VideoControlLayout layout,
  required VideoAppleChromeForm form,
  required bool Function(VideoControlItem item) renders,
}) {
  final VideoControlLayout factory = VideoControlLayout.currentChrome;
  final List<VideoApplePlacement> top = <VideoApplePlacement>[];
  final List<VideoApplePlacement> lead = <VideoApplePlacement>[];
  final List<VideoApplePlacement> trail = <VideoApplePlacement>[];
  final List<VideoApplePlacement> relocatedTop = <VideoApplePlacement>[];
  final List<VideoApplePlacement> relocatedTrail = <VideoApplePlacement>[];
  final List<VideoApplePlacement> extraFolded = <VideoApplePlacement>[];
  final Set<VideoControlItem> railsExclude = <VideoControlItem>{};
  bool showBack = false;
  bool showTitle = false;
  bool showPosition = false;

  bool visible(VideoControlItem item) =>
      item == VideoControlItem.volume || renders(item);

  void addUnique(List<VideoApplePlacement> into, VideoApplePlacement p) {
    if (into.any((VideoApplePlacement e) => e.item == p.item)) return;
    into.add(p);
  }

  const List<VideoControlSlot> slotOrder = <VideoControlSlot>[
    VideoControlSlot.topLeft,
    VideoControlSlot.topCenter,
    VideoControlSlot.topRight,
    VideoControlSlot.bottomLeft,
    VideoControlSlot.bottomCenter,
    VideoControlSlot.bottomRight,
    VideoControlSlot.screenLeft,
    VideoControlSlot.screenRight,
  ];
  for (final VideoControlSlot slot in slotOrder) {
    for (final VideoControlItem item in layout.itemsIn(slot)) {
      if (item == VideoControlItem.back) {
        if (slot != VideoControlSlot.screenLeft &&
            slot != VideoControlSlot.screenRight) {
          showBack = showBack || renders(item);
        }
        continue;
      }
      if (item == VideoControlItem.title) {
        showTitle = true;
        continue;
      }
      if (item == VideoControlItem.positionIndicator) {
        showPosition = true;
        continue;
      }
      final bool rail =
          slot == VideoControlSlot.screenLeft ||
          slot == VideoControlSlot.screenRight;
      final VideoApplePlacement placement = VideoApplePlacement(item, slot);
      final _AppleHome? home = factory.slotsOf(item).contains(slot)
          ? _appleHomeOf(item, form)
          : null;
      if (home != null) {
        if (rail) railsExclude.add(item);
        if (!visible(item)) continue;
        switch (home) {
          case _AppleHome.topTrailing:
            addUnique(relocatedTop, placement);
          case _AppleHome.bottomTrailing:
            addUnique(relocatedTrail, placement);
          case _AppleHome.folded:
            addUnique(extraFolded, placement);
        }
        continue;
      }
      if (rail) continue;
      if (kVideoAppleTransportItems.contains(item)) continue;
      if (!visible(item)) continue;
      // 音量只能住底部（模型层 canMoveToSlot 也只放它进 bottomLeft / bottomRight）。
      switch (slot) {
        case VideoControlSlot.topLeft:
        case VideoControlSlot.topCenter:
        case VideoControlSlot.topRight:
          if (item != VideoControlItem.volume) addUnique(top, placement);
        case VideoControlSlot.bottomLeft:
        case VideoControlSlot.bottomCenter:
          addUnique(lead, placement);
        case VideoControlSlot.bottomRight:
          addUnique(trail, placement);
        case VideoControlSlot.screenLeft:
        case VideoControlSlot.screenRight:
        case VideoControlSlot.hidden:
          break;
      }
    }
  }

  // 右上：重新安家的几颗排在用户顶部按钮之前（选集 / 章节等出厂右上项本就在
  // [top] 里，按用户顺序）；截图 / 设置排最后、紧挨「⋯」。
  final List<VideoApplePlacement> topTrailing = <VideoApplePlacement>[];
  int rankTop(VideoControlItem item) {
    switch (item) {
      case VideoControlItem.screenshot:
        return 2;
      case VideoControlItem.settings:
        return 3;
      default:
        return relocatedTop.any((VideoApplePlacement p) => p.item == item)
            ? 1
            : 0;
    }
  }

  final List<VideoApplePlacement> mergedTop = <VideoApplePlacement>[
    ...top,
    ...relocatedTop,
  ];
  // 稳定排序：同档保持原相对顺序。
  final List<int> order = List<int>.generate(mergedTop.length, (int i) => i)
    ..sort((int a, int b) {
      final int byRank = rankTop(
        mergedTop[a].item,
      ).compareTo(rankTop(mergedTop[b].item));
      return byRank != 0 ? byRank : a.compareTo(b);
    });
  for (final int i in order) {
    addUnique(topTrailing, mergedTop[i]);
  }

  // 后随簇：重新安家的（字幕列表 / 设置）插在全屏键之前（AVKit 全屏在最右），
  // 设置恒紧挨全屏键。重新安家的顺序不能取槽位遍历序：出厂设置在 topRight、
  // 字幕列表在 screenRight，遍历序会把设置排到字幕列表前面。
  final List<VideoApplePlacement> relocatedTrailOrdered = <VideoApplePlacement>[
    for (final VideoApplePlacement p in relocatedTrail)
      if (p.item != VideoControlItem.settings) p,
    for (final VideoApplePlacement p in relocatedTrail)
      if (p.item == VideoControlItem.settings) p,
  ];
  final List<VideoApplePlacement> bottomTrailing = <VideoApplePlacement>[];
  final int fullscreenAt = trail.indexWhere(
    (VideoApplePlacement p) => p.item == VideoControlItem.fullscreen,
  );
  final List<VideoApplePlacement> before = fullscreenAt < 0
      ? trail
      : trail.sublist(0, fullscreenAt);
  final List<VideoApplePlacement> after = fullscreenAt < 0
      ? const <VideoApplePlacement>[]
      : trail.sublist(fullscreenAt);
  for (final VideoApplePlacement p in <VideoApplePlacement>[
    ...before,
    ...relocatedTrailOrdered,
    ...after,
  ]) {
    addUnique(bottomTrailing, p);
  }

  // 同一按钮只占一个区域：右上优先于底部（右上是方案 C 指定的去处），前导优先于后随。
  final Set<VideoControlItem> taken = <VideoControlItem>{
    for (final VideoApplePlacement p in topTrailing) p.item,
  };
  final List<VideoApplePlacement> bottomLeading = <VideoApplePlacement>[
    for (final VideoApplePlacement p in lead)
      if (taken.add(p.item)) p,
  ];
  final List<VideoApplePlacement> trailing = <VideoApplePlacement>[
    for (final VideoApplePlacement p in bottomTrailing)
      if (taken.add(p.item)) p,
  ];

  return VideoAppleChromePlan(
    showBack: showBack,
    showTitle: showTitle,
    topTrailing: List<VideoApplePlacement>.unmodifiable(topTrailing),
    transport: List<VideoApplePlacement>.unmodifiable(<VideoApplePlacement>[
      for (final VideoControlItem item in kVideoAppleTransportItems)
        if (renders(item))
          VideoApplePlacement(item, _transportSourceSlot(layout, item)),
    ]),
    bottomLeading: List<VideoApplePlacement>.unmodifiable(bottomLeading),
    bottomTrailing: List<VideoApplePlacement>.unmodifiable(trailing),
    showPositionIndicator: showPosition,
    railsExclude: Set<VideoControlItem>.unmodifiable(railsExclude),
    extraFolded: List<VideoApplePlacement>.unmodifiable(<VideoApplePlacement>[
      for (final VideoApplePlacement p in extraFolded)
        if (!taken.contains(p.item)) p,
    ]),
  );
}

/// 传输键的来源槽：用户把它放在哪个可见槽就记哪个（浮层 / 执行上下文），一个都没有
/// （出厂 ±10 在 hidden）时记底部中簇。
VideoControlSlot _transportSourceSlot(
  VideoControlLayout layout,
  VideoControlItem item,
) {
  for (final VideoControlSlot slot in layout.slotsOf(item)) {
    if (slot.isOnPlayer) return slot;
  }
  return VideoControlSlot.bottomCenter;
}

/// 「⋯」里要去重的按钮：传输组恒在底部条，不再作为「移出播放器」的行出现。
bool videoAppleFoldedExcludes(VideoControlItem item) =>
    kVideoAppleTransportItems.contains(item);

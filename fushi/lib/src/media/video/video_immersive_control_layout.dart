/// 沉浸锁定态的按钮排列（「沉浸布局」，设计案
/// `docs/specs/2026-10-25-video-immersive-one-hand.md` §3.2）。
///
/// 与普通 9 槽布局 [VideoControlLayout] **分开**：沉浸锁定后顶栏 / 底栏整个不画，屏幕上
/// 只剩左右两条侧栏，所以这里只有 [VideoImmersiveSlot.screenLeft] /
/// [VideoImmersiveSlot.screenRight] + 隐藏托盘。骨架复用泛型 [ControlLayout]（不变式、写
/// 操作、编码与可视化编辑器同一套）。
///
/// 规则：
/// - 锁按钮必选（[VideoImmersiveItem.pinnedRequired]）：它是沉浸态唯一可见的退出口，不能
///   拖进隐藏托盘；左右、上下位置随意，且只有一份（[VideoImmersiveItem.isSingleInstance]）。
/// - **按钮在任何沉浸档位都有效**：放什么由本布局决定，[VideoImmersiveMode] 只管画面手势与
///   按键（2026-10-25 所有者拍板）。所以可放的只有点了就直接执行、不依赖控制条与浮层的
///   动作——倍速等需要锚在控制条上的浮层按钮、会弹设置面板的按钮都不在 [values] 里。
/// - **默认只有锁按钮**（零行为变化）：没存过沉浸布局时由普通布局派生
///   （[VideoImmersiveControlLayout.derivedFrom]）：锁在普通布局的屏幕右栏就放右栏，否则
///   放左栏（= 历史上沉浸态解锁口的位置）。只有用户在编辑器里改过才落盘，否则一直跟着
///   普通布局派生，不会出现「普通布局里锁挪了位置、沉浸布局还停在旧处」。
///
/// 持久化键 `video_immersive_control_layout`，JSON `{version:1, slots:{...}, removed:[...]}`；
/// 空串 = 未改过（派生）。
library;

import 'dart:convert';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';

/// 沉浸布局的槽位：屏幕左 / 右侧栏 + 隐藏托盘。存储名与 [VideoControlSlot] 同名槽一致。
enum VideoImmersiveSlot implements ControlSlotSpec {
  screenLeft('screenLeft'),
  screenRight('screenRight'),
  hidden('hidden');

  const VideoImmersiveSlot(this.storageValue);

  @override
  final String storageValue;

  /// 侧栏渲染时借用的普通槽位（弹层定位 / 按钮激活的 sourceSlot 口径）。
  VideoControlSlot get controlSlot {
    switch (this) {
      case VideoImmersiveSlot.screenLeft:
        return VideoControlSlot.screenLeft;
      case VideoImmersiveSlot.screenRight:
        return VideoControlSlot.screenRight;
      case VideoImmersiveSlot.hidden:
        return VideoControlSlot.hidden;
    }
  }

  /// 屏幕上真正渲染的两条侧栏（按左、右顺序）。
  static const List<VideoImmersiveSlot> railSlots = <VideoImmersiveSlot>[
    VideoImmersiveSlot.screenLeft,
    VideoImmersiveSlot.screenRight,
  ];
}

/// 沉浸布局里可放的按钮：普通按钮库 [VideoControlItem] 的子集，一一对应同一实现
/// （点击走页面同一个 `_activateVideoControlItem`）。
enum VideoImmersiveItem implements ControlItemSpec<VideoImmersiveSlot> {
  immersiveLock(VideoControlItem.immersiveLock),
  previousCue(VideoControlItem.previousCue),
  replayCue(VideoControlItem.replayCue),
  nextCue(VideoControlItem.nextCue),
  favoriteSentence(VideoControlItem.favoriteSentence),
  playPause(VideoControlItem.playPause),
  seekBackward(VideoControlItem.seekBackward),
  seekForward(VideoControlItem.seekForward);

  const VideoImmersiveItem(this.controlItem);

  /// 对应的普通按钮（图标 / 文案 / 点击执行都按它走）。
  final VideoControlItem controlItem;

  @override
  String get storageValue => controlItem.storageValue;

  @override
  bool get pinnedRequired => this == VideoImmersiveItem.immersiveLock;

  @override
  bool get pinnedOnTouch => false;

  @override
  bool get isSingleInstance => this == VideoImmersiveItem.immersiveLock;

  @override
  VideoImmersiveSlot get recoverySlot => VideoImmersiveSlot.screenLeft;

  @override
  bool canMoveToSlot(
    VideoImmersiveSlot target, {
    bool isTouchControls = false,
  }) => !(pinnedRequired && target == VideoImmersiveSlot.hidden);
}

class VideoImmersiveControlLayout {
  const VideoImmersiveControlLayout._(this._core);

  static const ControlLayoutScheme<VideoImmersiveSlot, VideoImmersiveItem>
  scheme = ControlLayoutScheme<VideoImmersiveSlot, VideoImmersiveItem>(
    slots: VideoImmersiveSlot.values,
    hiddenSlot: VideoImmersiveSlot.hidden,
    items: VideoImmersiveItem.values,
    postNormalize: _keepSingleLock,
  );

  /// 未改过沉浸布局时的派生默认：只有锁按钮，放在普通布局里锁所在的那一侧
  /// （只在右栏 → 右栏；其余一律左栏）。
  factory VideoImmersiveControlLayout.derivedFrom(VideoControlLayout base) =>
      VideoImmersiveControlLayout._(
        ControlLayout<VideoImmersiveSlot, VideoImmersiveItem>.fromAssignments(
          scheme,
          _derivedAssignments(base),
        ),
      );

  /// 编辑器交回的泛型布局重新包一层（编辑器不会换 scheme）。
  factory VideoImmersiveControlLayout.fromCore(
    ControlLayout<VideoImmersiveSlot, VideoImmersiveItem> core,
  ) {
    assert(identical(core.scheme, scheme), 'foreign ControlLayoutScheme');
    return VideoImmersiveControlLayout._(core);
  }

  /// 解码持久化值。空串 / 坏值 / 未知结构一律回派生默认（不抛）；缺失的按钮按派生默认
  /// 回填（锁回到派生那一侧，其余进隐藏托盘），所以以后新增可放按钮不会凭空冒出来。
  static VideoImmersiveControlLayout decode(
    String json, {
    required VideoControlLayout base,
  }) {
    final VideoImmersiveControlLayout fallback =
        VideoImmersiveControlLayout.derivedFrom(base);
    if (json.trim().isEmpty) return fallback;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return fallback;
      final Object? slotsRaw = raw['slots'];
      if (raw['version'] != 1 || slotsRaw is! Map<String, dynamic>) {
        return fallback;
      }
      final ControlLayout<VideoImmersiveSlot, VideoImmersiveItem>? decoded =
          ControlLayout.decodeSlots<VideoImmersiveSlot, VideoImmersiveItem>(
            scheme,
            slotsRaw,
            removedRaw: raw['removed'],
            fallbackAssignments: _derivedAssignments(base),
          );
      return decoded == null
          ? fallback
          : VideoImmersiveControlLayout._(decoded);
    } catch (_) {
      return fallback;
    }
  }

  final ControlLayout<VideoImmersiveSlot, VideoImmersiveItem> _core;

  /// 泛型布局本体（给泛型编辑器）。
  ControlLayout<VideoImmersiveSlot, VideoImmersiveItem> get core => _core;

  /// 槽内有序按钮。
  List<VideoImmersiveItem> itemsIn(VideoImmersiveSlot slot) =>
      _core.itemsIn(slot);

  /// 锁按钮所在的侧栏（归一化保证它恰好在一条侧栏里）。
  VideoImmersiveSlot get lockSlot =>
      _core.slotOf(VideoImmersiveItem.immersiveLock);

  String encode() {
    final List<String> removed = _core.encodeRemoved();
    return jsonEncode(<String, Object>{
      'version': 1,
      'slots': _core.encodeSlots(),
      if (removed.isNotEmpty) 'removed': removed,
    });
  }

  static Map<VideoImmersiveItem, VideoImmersiveSlot> _derivedAssignments(
    VideoControlLayout base,
  ) {
    final List<VideoControlSlot> lockSlots = base.slotsOf(
      VideoControlItem.immersiveLock,
    );
    final VideoImmersiveSlot lockSide =
        lockSlots.contains(VideoControlSlot.screenRight) &&
            !lockSlots.contains(VideoControlSlot.screenLeft)
        ? VideoImmersiveSlot.screenRight
        : VideoImmersiveSlot.screenLeft;
    return <VideoImmersiveItem, VideoImmersiveSlot>{
      for (final VideoImmersiveItem item in VideoImmersiveItem.values)
        item: item == VideoImmersiveItem.immersiveLock
            ? lockSide
            : VideoImmersiveSlot.hidden,
    };
  }

  /// 锁按钮只留一份：载荷里两条侧栏都写了锁时保留先出现的那一份（左栏优先）。
  static void _keepSingleLock(
    Map<VideoImmersiveSlot, List<VideoImmersiveItem>> slots,
    Set<VideoImmersiveItem> removed,
  ) {
    bool seen = false;
    for (final VideoImmersiveSlot slot in VideoImmersiveSlot.railSlots) {
      final List<VideoImmersiveItem> list = slots[slot]!;
      if (!list.contains(VideoImmersiveItem.immersiveLock)) continue;
      if (seen) {
        list.remove(VideoImmersiveItem.immersiveLock);
      } else {
        seen = true;
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VideoImmersiveControlLayout && _core == other._core);

  @override
  int get hashCode => _core.hashCode;
}

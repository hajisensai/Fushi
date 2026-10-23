/// 手机字幕遥控器控制卡的按钮布局模型（与视频页 / 阅读器同一套泛型骨架
/// `ControlLayout<S, I>`，用户 2026-10-12：「支持自定义按钮」）。
///
/// 两个可见槽位 + hidden：
///  * [VideoRemoteControlSlot.primary]：主控制组（竖屏底部浮动卡的大按钮组、
///    横屏左栏的主控制组）。出厂 上一句 / 播放暂停 / 下一句。
///  * [VideoRemoteControlSlot.secondary]：次组（竖屏卡片第二行的图标按钮、
///    横屏左栏的按钮网格）。出厂 重播本句 / 收藏 / 回到当前句 / 选集 / 字幕轨 /
///    在线字幕 / 音量。
///
/// 没有「制卡」按钮（用户 2026-10-21：点字幕里的字就能查词制卡，按钮多余）。旧存档
/// 里的 `mine` 是未知值，解码时按未知按钮丢掉。
///
/// 播放暂停是必需项：任何时候都不能移出（遥控器的核心动作）。
///
/// 持久化键 `video_remote_control_layout`，JSON
/// `{version:1, slots:{primary:[...], secondary:[...]}, removed:[...]}`
/// （与阅读器 / 视频 v3 同形）。纯 Dart，无 Flutter 依赖。
library;

import 'dart:convert';

import 'package:fushi/src/controls/control_layout.dart';

/// 遥控器控制卡的槽位。
enum VideoRemoteControlSlot implements ControlSlotSpec {
  primary('primary'),
  secondary('secondary'),
  hidden('hidden');

  const VideoRemoteControlSlot(this.storageValue);

  @override
  final String storageValue;

  /// 编辑器舞台上的槽位（hidden 是编辑器自己的托盘）。
  static const List<VideoRemoteControlSlot> editableSlots =
      <VideoRemoteControlSlot>[primary, secondary];
}

/// 遥控器控制卡上可放的按钮。
enum VideoRemoteControlItem implements ControlItemSpec<VideoRemoteControlSlot> {
  /// 上一句（只在主轨上导航）。
  previousCue('previousCue', recoverySlot: VideoRemoteControlSlot.primary),

  /// 播放 / 暂停（形变播放键）。必需。
  playPause(
    'playPause',
    pinnedRequired: true,
    recoverySlot: VideoRemoteControlSlot.primary,
  ),

  /// 下一句。
  nextCue('nextCue', recoverySlot: VideoRemoteControlSlot.primary),

  /// 重播本句。
  replayCue('replayCue', recoverySlot: VideoRemoteControlSlot.secondary),

  /// 收藏 / 取消收藏当前句。
  favorite('favorite', recoverySlot: VideoRemoteControlSlot.secondary),

  /// 回到当前句（恢复列表自动跟随）。
  followCurrent(
    'followCurrent',
    recoverySlot: VideoRemoteControlSlot.secondary,
  ),

  /// 倍速。
  speed('speed', recoverySlot: VideoRemoteControlSlot.secondary),

  /// 电脑上字幕显示 / 隐藏。
  subtitleVisibility(
    'subtitleVisibility',
    recoverySlot: VideoRemoteControlSlot.secondary,
  ),

  /// 后退 10 秒。
  seekBack('seekBack', recoverySlot: VideoRemoteControlSlot.secondary),

  /// 前进 10 秒。
  seekForward('seekForward', recoverySlot: VideoRemoteControlSlot.secondary),

  /// 选集（切到同一作品的其它集）。
  episodes('episodes', recoverySlot: VideoRemoteControlSlot.secondary),

  /// 切换电脑上的主字幕轨。
  subtitleTrack(
    'subtitleTrack',
    recoverySlot: VideoRemoteControlSlot.secondary,
  ),

  /// 在电脑上搜索在线字幕并应用。
  subtitleSearch(
    'subtitleSearch',
    recoverySlot: VideoRemoteControlSlot.secondary,
  ),

  /// 电脑音量。
  volume('volume', recoverySlot: VideoRemoteControlSlot.secondary);

  const VideoRemoteControlItem(
    this.storageValue, {
    this.pinnedRequired = false,
    required this.recoverySlot,
  });

  @override
  final String storageValue;

  @override
  final bool pinnedRequired;

  /// 遥控器只在触屏上用，触屏与持久化同一口径：没有「仅触屏必需」的按钮。
  @override
  bool get pinnedOnTouch => false;

  /// 同一颗按钮不该同时出现在两处。
  @override
  bool get isSingleInstance => true;

  @override
  final VideoRemoteControlSlot recoverySlot;

  @override
  bool canMoveToSlot(
    VideoRemoteControlSlot target, {
    bool isTouchControls = false,
  }) {
    if (target == VideoRemoteControlSlot.hidden) return !pinnedRequired;
    return true;
  }

  static VideoRemoteControlItem? fromStorage(String value) {
    for (final VideoRemoteControlItem item in values) {
      if (item.storageValue == value) return item;
    }
    return null;
  }
}

const ControlLayoutScheme<VideoRemoteControlSlot, VideoRemoteControlItem>
kVideoRemoteControlScheme =
    ControlLayoutScheme<VideoRemoteControlSlot, VideoRemoteControlItem>(
      slots: VideoRemoteControlSlot.values,
      hiddenSlot: VideoRemoteControlSlot.hidden,
      items: VideoRemoteControlItem.values,
    );

/// 遥控器按钮布局：`ControlLayout` 的薄包装，负责出厂布局与 JSON 编解码。
class VideoRemoteControlLayout {
  const VideoRemoteControlLayout._(this.core);

  factory VideoRemoteControlLayout.fromCore(
    ControlLayout<VideoRemoteControlSlot, VideoRemoteControlItem> core,
  ) => VideoRemoteControlLayout._(core);

  final ControlLayout<VideoRemoteControlSlot, VideoRemoteControlItem> core;

  /// 出厂布局：主组 上一句 / 播放 / 下一句；次组 重播本句 / 收藏 / 回到当前句 /
  /// 选集 / 字幕轨 / 在线字幕 / 音量；倍速、字幕显隐、±10 秒在托盘（用户可拖上来）。
  /// 旧存档里没有后三颗时由 [decode] 按这里的位置回填到次组末尾。
  static final VideoRemoteControlLayout defaults = VideoRemoteControlLayout._(
    ControlLayout<VideoRemoteControlSlot, VideoRemoteControlItem>.fromSlots(
      kVideoRemoteControlScheme,
      <VideoRemoteControlSlot, List<VideoRemoteControlItem>>{
        VideoRemoteControlSlot.primary: <VideoRemoteControlItem>[
          VideoRemoteControlItem.previousCue,
          VideoRemoteControlItem.playPause,
          VideoRemoteControlItem.nextCue,
        ],
        VideoRemoteControlSlot.secondary: <VideoRemoteControlItem>[
          VideoRemoteControlItem.replayCue,
          VideoRemoteControlItem.favorite,
          VideoRemoteControlItem.followCurrent,
          VideoRemoteControlItem.episodes,
          VideoRemoteControlItem.subtitleTrack,
          VideoRemoteControlItem.subtitleSearch,
          VideoRemoteControlItem.volume,
        ],
      },
    ),
  );

  List<VideoRemoteControlItem> itemsIn(VideoRemoteControlSlot slot) =>
      core.itemsIn(slot);

  /// 主控制组。
  List<VideoRemoteControlItem> get primaryItems =>
      core.itemsIn(VideoRemoteControlSlot.primary);

  /// 次组。
  List<VideoRemoteControlItem> get secondaryItems =>
      core.itemsIn(VideoRemoteControlSlot.secondary);

  /// 已移出的按钮（托盘）。
  List<VideoRemoteControlItem> get removedItems => core.removedItems;

  /// 把 [item] 移进 [target]（[index] = 槽内位置）；必需项移入 hidden 被拒。
  VideoRemoteControlLayout moveItem(
    VideoRemoteControlItem item,
    VideoRemoteControlSlot target, {
    int? index,
  }) => VideoRemoteControlLayout._(core.moveItem(item, target, index: index));

  String encode() {
    final List<String> removed = core.encodeRemoved();
    return jsonEncode(<String, Object>{
      'version': 1,
      'slots': core.encodeSlots(),
      if (removed.isNotEmpty) 'removed': removed,
    });
  }

  static Map<VideoRemoteControlItem, VideoRemoteControlSlot>
  _defaultAssignments() => <VideoRemoteControlItem, VideoRemoteControlSlot>{
    for (final VideoRemoteControlItem item in VideoRemoteControlItem.values)
      item: defaults.core.slotOf(item),
  };

  /// 空 / 坏 JSON → 出厂布局；一个可见按钮都没有且没有显式移除 → 出厂布局。
  /// JSON 里缺席的按钮（新版本新增的按钮）按出厂位置回填。
  static VideoRemoteControlLayout decode(String json) {
    if (json.trim().isEmpty) return defaults;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return defaults;
      final Object? slotsRaw = raw['slots'];
      if (slotsRaw is! Map<String, dynamic>) return defaults;
      final ControlLayout<VideoRemoteControlSlot, VideoRemoteControlItem>?
      core =
          ControlLayout.decodeSlots<
            VideoRemoteControlSlot,
            VideoRemoteControlItem
          >(
            kVideoRemoteControlScheme,
            slotsRaw,
            removedRaw: raw['removed'],
            fallbackAssignments: _defaultAssignments(),
          );
      return core == null ? defaults : VideoRemoteControlLayout._(core);
    } on FormatException {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VideoRemoteControlLayout && other.core == core;

  @override
  int get hashCode => core.hashCode;
}

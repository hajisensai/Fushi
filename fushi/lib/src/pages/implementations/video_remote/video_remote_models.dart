import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

// 手机字幕遥控器的纯展示数据。页面（网络 / 状态机）把快照翻译成这些不可变
// 值交给展示组件；组件不认识 HTTP、不读 Riverpod，所有操作都经回调回到页面。

/// 字幕列表的一行（只放主轨；副轨译文挂在 [secondaryText]）。
@immutable
class VideoRemoteTranscriptLine {
  const VideoRemoteTranscriptLine({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    this.secondaryText,
    this.favorited = false,
  });

  /// 稳定标识（cue id）：列表 key、收藏状态都按它对齐。
  final String id;

  /// 主轨文本（逐字可点）。
  final String text;

  final Duration start;
  final Duration end;

  /// 副轨译文（显示为本句下方的小字，不参与导航）；没有副轨为 null。
  final String? secondaryText;

  /// 本句是否已收藏（行内显示星标）。
  final bool favorited;

  @override
  bool operator ==(Object other) =>
      other is VideoRemoteTranscriptLine &&
      other.id == id &&
      other.text == text &&
      other.start == start &&
      other.end == end &&
      other.secondaryText == secondaryText &&
      other.favorited == favorited;

  @override
  int get hashCode =>
      Object.hash(id, text, start, end, secondaryText, favorited);
}

/// 正在遥控的视频的展示快照。
@immutable
class VideoRemoteNowPlaying {
  const VideoRemoteNowPlaying({
    this.title = '',
    this.episodeLabel,
    this.hostName,
    this.cover,
    this.isPlaying = false,
    this.speed = 1.0,
    this.subtitlesVisible = true,
    this.currentFavorited = false,
    this.volume,
  });

  /// 作品名。
  final String title;

  /// 集数（如「第 3 话」）；未知为 null。
  final String? episodeLabel;

  /// 被遥控电脑的名字；未知为 null。
  final String? hostName;

  /// 封面（背景取色 + 横屏信息卡缩略图）；没有为 null。
  final ImageProvider? cover;

  final bool isPlaying;

  /// 当前倍速（倍速按钮的 tooltip / 标签）。
  final double speed;

  /// 电脑上字幕是否显示（字幕显隐按钮的选中态）。
  final bool subtitlesVisible;

  /// 当前句是否已收藏（收藏按钮的选中态）。
  final bool currentFavorited;

  /// 电脑音量 0..100；电脑不上报（旧版本）为 null。
  final int? volume;

  /// 「作品名 · 集数」。
  String get titleWithEpisode {
    final String episode = (episodeLabel ?? '').trim();
    if (episode.isEmpty) return title;
    if (title.isEmpty) return episode;
    return '$title · $episode';
  }
}

/// 收藏列表的一条。
@immutable
class VideoRemoteFavoriteEntry {
  const VideoRemoteFavoriteEntry({
    required this.id,
    required this.text,
    required this.videoTitle,
    required this.start,
    this.secondaryText,
    this.episodeLabel,
    this.isCurrentVideo = false,
  });

  /// 稳定标识（批量取消按它回传）。
  final String id;
  final String text;
  final String? secondaryText;

  /// 所属视频名（「全部视频」时显示）。
  final String videoTitle;
  final String? episodeLabel;

  /// 句子在视频里的起点。
  final Duration start;

  /// 属于电脑上当前打开的视频。
  final bool isCurrentVideo;
}

/// 内联状态卡（等待 / 出错 / 断线）。不用 MaterialBanner：卡片嵌在内容流里，
/// 与列表同一套圆角和进场动效。
enum VideoRemoteNoticeKind { waiting, error, disconnected }

@immutable
class VideoRemoteNotice {
  const VideoRemoteNotice({
    required this.kind,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final VideoRemoteNoticeKind kind;
  final String message;

  /// 卡片里的按钮（如「重新连接」）；null = 不显示。
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 查词高亮画在哪一处：字幕列表的行，还是收藏卡。
enum VideoRemoteLookupSurface { transcript, favorite }

/// 当前查词弹框正在查的词在行内的高亮：哪一处（[surface] + [id]：字幕行
/// [VideoRemoteTranscriptLine.id] / 收藏 [VideoRemoteFavoriteEntry.id]）的哪一段
/// grapheme 区间。[text] 一并核对，行文本变了（换字幕版本）就不再高亮。
@immutable
class VideoRemoteLookupHighlight {
  const VideoRemoteLookupHighlight({
    required this.surface,
    required this.id,
    required this.text,
    required this.graphemeStart,
    required this.graphemeCount,
  });

  final VideoRemoteLookupSurface surface;
  final String id;
  final String text;
  final int graphemeStart;
  final int graphemeCount;

  ({int start, int count})? _rangeFor(
    VideoRemoteLookupSurface surface,
    String id,
    String text,
  ) => surface == this.surface && id == this.id && text == this.text
      ? (start: graphemeStart, count: graphemeCount)
      : null;

  /// 字幕行 [line] 上要画的区间；不是这一行为 null。
  ({int start, int count})? rangeForLine(VideoRemoteTranscriptLine line) =>
      _rangeFor(VideoRemoteLookupSurface.transcript, line.id, line.text);

  /// 收藏卡 [entry] 上要画的区间；不是这一条为 null。
  ({int start, int count})? rangeForFavorite(VideoRemoteFavoriteEntry entry) =>
      _rangeFor(VideoRemoteLookupSurface.favorite, entry.id, entry.text);

  @override
  bool operator ==(Object other) =>
      other is VideoRemoteLookupHighlight &&
      other.surface == surface &&
      other.id == id &&
      other.text == text &&
      other.graphemeStart == graphemeStart &&
      other.graphemeCount == graphemeCount;

  @override
  int get hashCode =>
      Object.hash(surface, id, text, graphemeStart, graphemeCount);
}

/// 页签。
enum VideoRemoteTab { transcript, favorites }

/// 收藏范围。
enum VideoRemoteFavoritesScope { currentVideo, allVideos }

/// 字幕列表的「跟随」状态：手动滚动后关闭跟随（显示「回到当前句」），
/// [returnToCurrent] 恢复跟随并滚回当前句。控制卡上的「回到当前句」按钮与
/// 列表里的悬浮按钮共用这一个控制器。
class VideoRemoteTranscriptController extends ChangeNotifier {
  bool _following = true;
  int _recenterRequests = 0;

  /// 列表是否自动跟随当前句。
  bool get following => _following;

  /// 每次 [returnToCurrent] 自增：列表据此判断要不要滚回当前句。
  int get recenterRequests => _recenterRequests;

  /// 恢复跟随并滚回当前句。
  void returnToCurrent() {
    _following = true;
    _recenterRequests++;
    notifyListeners();
  }

  /// 用户手动滚动：关闭跟随。
  void stopFollowing() {
    if (!_following) return;
    _following = false;
    notifyListeners();
  }
}

/// 控制按钮的图标（语义图标层，Apple 设计系统自动换 SF 替身）。
IconData videoRemoteControlIcon(
  VideoRemoteControlItem item, {
  bool active = false,
}) => switch (item) {
  VideoRemoteControlItem.previousCue => FushiIcons.skipPrevious,
  VideoRemoteControlItem.playPause =>
    active ? FushiIcons.pause : FushiIcons.play,
  VideoRemoteControlItem.nextCue => FushiIcons.skipNext,
  VideoRemoteControlItem.replayCue => FushiIcons.replay,
  VideoRemoteControlItem.favorite =>
    active ? FushiIcons.filled(FushiIcons.star) : FushiIcons.star,
  VideoRemoteControlItem.followCurrent => FushiIcons.myLocation,
  VideoRemoteControlItem.speed => FushiIcons.speed,
  VideoRemoteControlItem.subtitleVisibility =>
    active ? FushiIcons.subtitles : FushiIcons.subtitlesOff,
  VideoRemoteControlItem.seekBack => FushiIcons.replay10,
  VideoRemoteControlItem.seekForward => FushiIcons.forward10,
  VideoRemoteControlItem.episodes => FushiIcons.playlist,
  VideoRemoteControlItem.subtitleTrack => FushiIcons.subtitles,
  VideoRemoteControlItem.subtitleSearch => FushiIcons.manageSearch,
  VideoRemoteControlItem.volume =>
    active ? FushiIcons.volumeOff : FushiIcons.volumeUp,
};

/// 控制按钮的文案（tooltip / 无障碍 / 横屏网格标签 / 编辑器）。
String videoRemoteControlLabel(
  VideoRemoteControlItem item, {
  bool active = false,
}) => switch (item) {
  VideoRemoteControlItem.previousCue => t.video_remote_previous,
  VideoRemoteControlItem.playPause => active ? t.pause : t.play,
  VideoRemoteControlItem.nextCue => t.video_remote_next,
  VideoRemoteControlItem.replayCue => t.video_remote_control_replay,
  VideoRemoteControlItem.favorite =>
    active
        ? t.video_remote_control_unfavorite
        : t.video_remote_control_favorite,
  VideoRemoteControlItem.followCurrent => t.video_remote_current,
  VideoRemoteControlItem.speed => t.playback_speed,
  VideoRemoteControlItem.subtitleVisibility =>
    t.video_remote_control_subtitle_visibility,
  VideoRemoteControlItem.seekBack => t.video_remote_control_seek_back,
  VideoRemoteControlItem.seekForward => t.video_remote_control_seek_forward,
  VideoRemoteControlItem.episodes => t.video_episode_list,
  VideoRemoteControlItem.subtitleTrack => t.video_control_subtitle_track,
  VideoRemoteControlItem.subtitleSearch =>
    t.video_remote_control_subtitle_search,
  VideoRemoteControlItem.volume => t.audio_volume,
};

/// 按钮当前是不是「开着」的状态（图标 / 选中态用）。
bool videoRemoteControlActive(
  VideoRemoteControlItem item,
  VideoRemoteNowPlaying nowPlaying,
) => switch (item) {
  VideoRemoteControlItem.playPause => nowPlaying.isPlaying,
  VideoRemoteControlItem.favorite => nowPlaying.currentFavorited,
  VideoRemoteControlItem.subtitleVisibility => nowPlaying.subtitlesVisible,
  // 音量按钮的「开着」= 电脑静音（图标换成静音）。
  VideoRemoteControlItem.volume => nowPlaying.volume == 0,
  _ => false,
};

/// 倍速显示：`1×` / `1.25×`。
String formatVideoRemoteSpeed(double speed) {
  String text = speed.toStringAsFixed(2);
  while (text.contains('.') && (text.endsWith('0') || text.endsWith('.'))) {
    text = text.substring(0, text.length - 1);
  }
  return '$text×';
}

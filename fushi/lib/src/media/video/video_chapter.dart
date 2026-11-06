import 'package:flutter/foundation.dart' show immutable;

// 从 video_player_controller.dart 抽出的纯值对象：netflix_metadata.dart 等只要章节
// 数据形状的文件 import 这里，不必经播放器控制器把整个播放栈拖进 import 环
// （test/build/import_cycle_guard_test.dart）。

/// mkv/mp4 内封章节（chapter）的一条记录（TODO-424）。只读值对象：序号 + 标题 +
/// 起始位置，由 `VideoPlayerController.refreshChapters` 从 libmpv `chapter-list`
/// 属性解析得到，章节面板渲染 + 跳转用。
///
/// [index] 是 libmpv `chapter` 属性的 0-based 章节下标（跳转时直接写回 `chapter`
/// 或 seek 到 [start]）；[title] 为容器里写的章节名（如 `Chapter 01`，可能为空，
/// 调用方据此回退成「章节 N」之类占位）；[start] 为该章在时间轴上的起点。
@immutable
class VideoChapter {
  const VideoChapter({
    required this.index,
    required this.title,
    required this.start,
  });

  /// 0-based 章节下标（对齐 libmpv `chapter` 属性）。
  final int index;

  /// 章节标题（容器里写的 `title`，可能为空字符串）。
  final String title;

  /// 章节在时间轴上的起点。
  final Duration start;

  @override
  bool operator ==(Object other) =>
      other is VideoChapter &&
      other.index == index &&
      other.title == title &&
      other.start == start;

  @override
  int get hashCode => Object.hash(index, title, start);

  @override
  String toString() =>
      'VideoChapter(index: $index, title: "$title", start: $start)';
}

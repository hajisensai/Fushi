/// 作品详情页的技术规格区块（v95）。
///
/// 呈现粒度**跟着数据粒度走**：规格属于文件，不属于作品。所以完整规格表只出现在
/// 「一个文件 = 一部作品」的地方（单文件作品详情页、某一集的媒体信息弹窗）；合集
/// 详情页的作品级信息区**刻意不放**——一个合集十几集，各集分辨率/音轨可以完全不同，
/// 在作品级摆一份规格必然是在骗人（挑第一集还是最常见的？都不对）。合集里逐集看，
/// 走集卡上的 [VideoSpecsInlineLine] 与集卡菜单的媒体信息弹窗。
///
/// 注意 slang 的 `t`：`Translations.of(context)` 返回的是 library-private 类型，
/// **不能写成字段/参数类型**（只能 `final t = ...` 靠推断）。所以下面每个需要文案的
/// widget 都在自己的 `build` 里取一次 t，而不是层层传递。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_badges.dart'
    show isProbableStreamUrl;
import 'package:fushi/src/media/video/video_duration_probe.dart';
import 'package:fushi/src/media/video/video_specs_display.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 完整规格表：分辨率 / 动态范围 / 编码 / 色深 / 帧率 / 码率 / 音轨 / 字幕轨。
///
/// 规格未探到时**整块不渲染**（返回 SizedBox.shrink），不显示「加载中」骨架——探测
/// 通常几十毫秒就回来，先闪一个骨架再换成内容比直接出现更晃眼。
class VideoSpecsPanel extends ConsumerStatefulWidget {
  const VideoSpecsPanel({
    required this.filePath,
    this.showTitle = true,
    super.key,
  });

  final String? filePath;

  /// 是否显示「媒体信息」小标题（弹窗里已有标题栏，就不重复）。
  final bool showTitle;

  @override
  ConsumerState<VideoSpecsPanel> createState() => _VideoSpecsPanelState();
}

class _VideoSpecsPanelState extends ConsumerState<VideoSpecsPanel> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(VideoSpecsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) _resolve();
  }

  void _resolve() {
    final String? path = widget.filePath;
    if (path == null || path.isEmpty || isProbableStreamUrl(path)) return;
    // 详情页只有一个文件，值得直接 resolve（而不是排队）——用户就是为看它才点进来。
    ref.read(videoSpecsProvider).resolve(path);
  }

  @override
  Widget build(BuildContext context) {
    final String? path = widget.filePath;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    final VideoProbeFacts? facts = ref.watch(videoSpecsProvider).specsFor(path);
    if (facts == null) return const SizedBox.shrink();

    final t = Translations.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    final List<(String, String)> rows = <(String, String)>[
      for (final (VideoSpecField field, String value) in videoSpecsFields(facts))
        (
          switch (field) {
            VideoSpecField.resolution => t.video_specs_resolution,
            VideoSpecField.dynamicRange => t.video_specs_dynamic_range,
            VideoSpecField.videoCodec => t.video_specs_video_codec,
            VideoSpecField.bitDepth => t.video_specs_bit_depth,
            VideoSpecField.frameRate => t.video_specs_frame_rate,
            VideoSpecField.bitrate => t.video_specs_bitrate,
            VideoSpecField.audioTracks => t.video_specs_audio_tracks,
            VideoSpecField.subtitleTracks => t.video_specs_subtitle_tracks,
          },
          value,
        ),
    ];

    final List<TrackDisplay> audio =
        facts.audioTracks.map(audioTrackDisplay).toList();
    final List<TrackDisplay> subtitles =
        facts.subtitleTracks.map(subtitleTrackDisplay).toList();

    if (rows.isEmpty && audio.isEmpty && subtitles.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (widget.showTitle) ...<Widget>[
          Text(
            t.video_specs_title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        for (final (String label, String value) in rows)
          _SpecRow(label: label, value: value),
        if (audio.isNotEmpty)
          _TrackRow(label: t.video_specs_audio_tracks, tracks: audio),
        if (subtitles.isNotEmpty)
          _TrackRow(label: t.video_specs_subtitle_tracks, tracks: subtitles),
      ],
    );
  }
}

/// 一行 label / value，与合集详情页既有事实行同款排布（116px label 列）。
class _SpecRow extends StatelessWidget {
  const _SpecRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(child: SelectableText(value, style: text.bodySmall)),
        ],
      ),
    );
  }
}

/// 音轨 / 字幕轨行：一条轨道一行，标志位跟在名字后面。
class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.label, required this.tracks});

  final String label;
  final List<TrackDisplay> tracks;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;

    String line(TrackDisplay track) {
      final List<String> flags = <String>[
        if (track.isDefault) t.video_specs_track_default,
        if (track.isCommentary) t.video_specs_track_commentary,
        if (track.isForced) t.video_specs_track_forced,
      ];
      return flags.isEmpty
          ? track.headline
          : '${track.headline}（${flags.join('、')}）';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final TrackDisplay track in tracks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child:
                        SelectableText(line(track), style: text.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行紧凑规格，给集卡状态行用：`1080p · HDR10 · HEVC`。
class VideoSpecsInlineLine extends ConsumerStatefulWidget {
  const VideoSpecsInlineLine({required this.filePath, this.style, super.key});

  final String? filePath;
  final TextStyle? style;

  @override
  ConsumerState<VideoSpecsInlineLine> createState() =>
      _VideoSpecsInlineLineState();
}

class _VideoSpecsInlineLineState extends ConsumerState<VideoSpecsInlineLine> {
  @override
  void initState() {
    super.initState();
    _prime();
  }

  @override
  void didUpdateWidget(VideoSpecsInlineLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) _prime();
  }

  void _prime() {
    final String? path = widget.filePath;
    if (path == null || path.isEmpty || isProbableStreamUrl(path)) return;
    ref.read(videoSpecsProvider).prime(<String>[path]);
  }

  @override
  Widget build(BuildContext context) {
    final String? path = widget.filePath;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    final VideoProbeFacts? facts = ref.watch(videoSpecsProvider).specsFor(path);
    final String? summary = videoSpecsInlineSummary(facts);
    // 未探到时不占位：集卡高度是钳死的，多一行会把简介挤掉。
    if (summary == null) return const SizedBox.shrink();
    return Text(
      summary,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style ??
          Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
    );
  }
}

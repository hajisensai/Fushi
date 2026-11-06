/// 音乐库「生成日语字幕」的产物落点（[AppSubtitleOutputSink] 的音乐实现）。
///
/// - 导出目录：应用自有的 `<数据根>/asr_jobs/music_subtitles/out/<videoSubtitleJobId(音频)>/`，
///   **不写到音频旁**：音乐目录常是只读盘 / 别的播放器的库，写成 `<主名>.ja.srt` 还会被
///   歌词 sidecar 规则认成 `ja` 翻译文件。目录名与任务目录同一个键（文件名 + 字节数），
///   CUE 整轨多曲共用一个文件时只转写、只导出一次；同名 `01.flac` 各进各的目录。
/// - 登记：读导出的 SRT（样式参考不用：音乐只要 SRT），按这个文件下的每首曲目切片——
///   CUE 虚拟曲目按 `[cueStartMs, cueEndMs)` 截取并平移成曲内时间（Rust
///   `ffm_lyrics_slice`），普通文件整份——写成该曲的 `asr` 歌词行（[MusicLyricsService.
///   saveGenerated]）。`music_lyrics` 一变，「我库里的例句」/ 曲库歌词搜索的语料自动对账，
///   正在播放的歌词页与桌面歌词经 [MusicLyricsService.generatedUpdates] 重载。
/// - 远控镜像单独一种（[VideoRemoteJobKind.musicSubtitleGenerate]），主体是目标键，视频
///   遥控不会把它当成哪个视频的任务。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart';

/// 一个音频文件下要写字幕的一首曲目（CUE 虚拟曲目带区间）。
class MusicAsrTrackSlot {
  const MusicAsrTrackSlot({
    required this.trackUid,
    this.cueStartMs,
    this.cueEndMs,
  });

  final String trackUid;

  /// CUE 虚拟曲目在整轨里的区间（毫秒，`[start, end)`；end 为 null = 到文件结尾）。
  /// 普通曲目两者都为 null。
  final int? cueStartMs;
  final int? cueEndMs;
}

/// `<数据根>/asr_jobs/music_subtitles/out`：与视频任务目录（`asr_jobs/video_subtitles`）
/// 同级。布局只在这里写一次。
Directory musicSubtitleOutRootUnder(Directory supportRoot) =>
    Directory(p.join(supportRoot.path, 'asr_jobs', 'music_subtitles', 'out'));

/// 解析 SRT 的入口（生产 [FushiLyricsAsync.parse]：后台 isolate 跑 Rust 解析）。
typedef MusicAsrSubtitleParse =
    Future<LyricTimeline> Function(Uint8List bytes, String hint, int? d);

class MusicAsrSubtitleSink implements AppSubtitleOutputSink {
  MusicAsrSubtitleSink({
    required this.outRoot,
    required this.lyrics,
    required Map<String, List<MusicAsrTrackSlot>> slotsByPath,
    MusicAsrSubtitleParse? parse,
  }) : _slots = slotsByPath,
       _parse = parse ?? _defaultParse;

  final Directory outRoot;
  final MusicLyricsService lyrics;

  /// 音频路径 → 该文件下要写字幕的曲目（解析目标时按文件去重得到）。
  final Map<String, List<MusicAsrTrackSlot>> _slots;
  final MusicAsrSubtitleParse _parse;

  /// 这个文件下要写字幕的曲目（测试 / 面板用）。
  List<MusicAsrTrackSlot> slotsOf(String path) =>
      _slots[path] ?? const <MusicAsrTrackSlot>[];

  @override
  AppSubtitleTargetDomain get domain => AppSubtitleTargetDomain.music;

  @override
  Directory exportDirFor(String mediaPath) =>
      Directory(p.join(outRoot.path, videoSubtitleJobId(mediaPath)));

  @override
  bool get registersSkippedExisting => true;

  @override
  bool get usesStyleReference => false;

  @override
  VideoRemoteJobKind get mirrorKind => VideoRemoteJobKind.musicSubtitleGenerate;

  @override
  String mirrorSubject(AppVideoSubtitleTarget target) => target.key;

  /// 音乐库没有「登记在库里的导入字幕」：证据只用音频旁 / 内嵌的（管线默认收集）。
  @override
  Future<List<String>> extraEvidenceFiles(
    AppVideoSubtitleEpisode episode,
  ) async => const <String>[];

  @override
  Future<List<String>> register(
    AppVideoSubtitleEpisode episode,
    VideoSubtitleEpisodeResult result,
  ) async {
    // 只取 SRT：样式参考对音乐关闭，即便有 ASS 也与歌词无关。
    final String? output = result.outputPath;
    final List<MusicAsrTrackSlot> slots = slotsOf(episode.videoPath);
    if (output == null || slots.isEmpty) return const <String>[];
    return saveGeneratedSubtitleForTracks(
      lyrics,
      await File(output).readAsBytes(),
      slots,
      parse: _parse,
    );
  }
}

/// 一份整文件的生成字幕（SRT）→ 这个文件下各曲目的 `asr` 歌词行：CUE 虚拟曲目按
/// `[cueStartMs, cueEndMs)` 截取并平移（Rust `ffm_lyrics_slice`，原文存 TTML），普通曲目
/// 整份照存 SRT。生成任务的落点与存量迁移（带走旧视频管线的产物）共用这一处。返回写了
/// 的曲目。
Future<List<String>> saveGeneratedSubtitleForTracks(
  MusicLyricsService lyrics,
  Uint8List srt,
  List<MusicAsrTrackSlot> slots, {
  MusicAsrSubtitleParse? parse,
}) async {
  if (slots.isEmpty) return const <String>[];
  final LyricTimeline whole = await (parse ?? _defaultParse)(srt, 'srt', null);
  // CUE 各曲的切片 + TTML 导出整批放后台 isolate（整轨字幕上千行、曲目十几首，逐首在
  // UI isolate 上跨 FFI 会卡帧）。
  final List<MusicAsrTrackSlot> cue = <MusicAsrTrackSlot>[
    for (final MusicAsrTrackSlot slot in slots)
      if (slot.cueStartMs != null) slot,
  ];
  final List<({LyricTimeline timeline, Uint8List ttml})> cuts = cue.isEmpty
      ? const <({LyricTimeline timeline, Uint8List ttml})>[]
      : await FushiLyricsAsync.sliceAll(whole, <({int startMs, int? endMs})>[
          for (final MusicAsrTrackSlot slot in cue)
            (startMs: slot.cueStartMs!, endMs: slot.cueEndMs),
        ]);
  final List<String> wrote = <String>[];
  int at = 0;
  for (final MusicAsrTrackSlot slot in slots) {
    if (slot.cueStartMs == null) {
      await lyrics.saveGenerated(
        slot.trackUid,
        format: 'srt',
        raw: srt,
        timeline: whole,
      );
    } else {
      final ({LyricTimeline timeline, Uint8List ttml}) cut = cuts[at++];
      // 切片后的原文存 TTML（无损交换格式；导出不补注音）。
      await lyrics.saveGenerated(
        slot.trackUid,
        format: 'ttml',
        raw: cut.ttml,
        timeline: cut.timeline,
      );
    }
    wrote.add(slot.trackUid);
  }
  return wrote;
}

Future<LyricTimeline> _defaultParse(Uint8List b, String h, int? d) =>
    FushiLyricsAsync.parse(b, hint: h, durationMs: d);

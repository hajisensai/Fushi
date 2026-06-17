import 'dart:io';

import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 在**主页视频卡**上拖入外挂字幕、把它挂到那张卡所代表视频书的结果分类。
enum SubtitleAttachOutcome {
  /// 已成功挂上字幕（解析出 cue 并原子落库）。
  attached,

  /// 命中的是播放列表（多集）卡：整本播放列表没有「单一字幕」语义（各集字幕按
  /// 磁盘动态解析），拖单个字幕文件无法确定挂哪一集 → 不落库，提示进播放页按集挂。
  playlistNeedsPlayer,

  /// 字幕扩展名不受支持（非 srt/ass/ssa/vtt）。
  unsupported,

  /// 拷贝字幕到持久目录失败（IO 错误）。
  copyFailed,

  /// 字幕解析出 0 条 cue（坏字幕 / 图形轨）：不落库、不覆盖现有字幕。
  emptyCues,
}

/// 把字幕挂到现有视频书的结果。[cueCount] 仅 [SubtitleAttachOutcome.attached]
/// 时有意义（解析出的句数）；[label] 是用于 UI 反馈的字幕文件名。
class SubtitleAttachResult {
  const SubtitleAttachResult({
    required this.outcome,
    this.cueCount = 0,
    this.label = '',
  });

  final SubtitleAttachOutcome outcome;
  final int cueCount;
  final String label;
}

/// 解析字幕文本内容并把它原子挂到 [book] 代表的视频书（纯落库，无 UI/controller）。
///
/// 这是**主页拖字幕到视频卡**的核心，复刻播放页 `_importExternalSubtitle` 的
/// 「拷盘 -> 解析 -> [VideoBookRepository.saveSubtitleSelection] 原子写源指针+cue」链路，
/// 但不进播放页（拖卡时没有 VideoPlayerController）。与播放页共用：
/// - [subtitleFormatForPath] / [parseSubtitleContentAsync]（同一套格式路由 + parser）；
/// - 持久目录 `<appDocs>/video_subtitles/<basename>`（与导入/Jimaku 下载同处，BUG-132
///   恢复捷径据此按路径直接加载）；
/// - [SubtitleSource.external] 的持久化值（绝对路径）= `subtitleSource` 列。
///
/// **不重新导入**——直接对命中卡的既有 `book.bookUid` 写，避免旧实现走
/// `VideoImportDialog._doImport` 对已存在视频重算 `singleVideoBookUid` 触发同名去重、
/// 创建 `video/<name> (2)` 重复条目而字幕没挂到原视频（TODO-079 根因）。
///
/// [book] 是命中的视频卡数据；播放列表（[playlistEpisodeCount] >= 2）整本无单一字幕
/// 语义，返回 [SubtitleAttachOutcome.playlistNeedsPlayer]，不落库。
///
/// [destDirOverride] / [contentReader] 仅供测试注入（默认走真实 appDocs 与
/// [readTextWithEncoding]）。
Future<SubtitleAttachResult> attachSubtitleToVideoBook({
  required VideoBookRepository repo,
  required VideoBookRow book,
  required String subtitlePath,
  String? destDirOverride,
  Future<String> Function(File file)? contentReader,
}) async {
  // 播放列表：各集字幕动态解析，拖单文件挂哪集无定义 -> 提示进播放页按集挂。
  if (playlistEpisodeCount(book.playlistJson) >= 2) {
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.playlistNeedsPlayer,
      label: p.basename(subtitlePath),
    );
  }

  final SubtitleFormat? format = subtitleFormatForPath(subtitlePath);
  if (format == null) {
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.unsupported,
      label: p.basename(subtitlePath),
    );
  }

  // 拷到持久目录 `<appDocs>/video_subtitles/<basename>`（与播放页导入同处），
  // 持久化值为该副本的绝对路径——源文件被移走/换机也能恢复（BUG-132）。
  final String destDir = destDirOverride ?? await _defaultSubtitleDir();
  await Directory(destDir).create(recursive: true);
  final String dest = p.join(destDir, p.basename(subtitlePath));
  if (!p.equals(subtitlePath, dest)) {
    try {
      await File(subtitlePath).copy(dest);
    } catch (_) {
      return SubtitleAttachResult(
        outcome: SubtitleAttachOutcome.copyFailed,
        label: p.basename(subtitlePath),
      );
    }
  }

  final Future<String> Function(File) read =
      contentReader ?? readTextWithEncoding;
  final String content = await read(File(dest));
  final List<AudioCue> cues = await parseSubtitleContentAsync(
    format,
    content: content,
    bookUid: book.bookUid,
  );
  if (cues.isEmpty) {
    // 解析空（坏字幕 / 图形轨）：不落库、不覆盖现有可用字幕（与播放页同语义）。
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.emptyCues,
      label: p.basename(dest),
    );
  }

  // 单视频：源指针 + cue 原子写入（BUG-081），下次进播放页 `loadCues` 直接命中。
  await repo.saveSubtitleSelection(
    bookUid: book.bookUid,
    subtitleSource: dest,
    cues: cues,
  );
  return SubtitleAttachResult(
    outcome: SubtitleAttachOutcome.attached,
    cueCount: cues.length,
    label: p.basename(dest),
  );
}

Future<String> _defaultSubtitleDir() async {
  final Directory docs = await getApplicationDocumentsDirectory();
  return p.join(docs.path, 'video_subtitles');
}

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:path/path.dart' as p;

/// 在**主页视频卡**上拖入外挂字幕、把它挂到那张卡所代表视频书的结果分类。
///
/// 只有三种「非成功」形态，且**字幕本身读不出/解不出的原因不在这里再造一套**——
/// 直接带出播放页那份 [SubtitleCueLoadFailure]（BUG-1490 定的四态），
/// 见 [SubtitleAttachResult.cueFailure]（BUG-1504）。
enum SubtitleAttachOutcome {
  /// 已成功挂上字幕（解析出 cue 并原子落库）。
  attached,

  /// 命中的是播放列表（多集）卡：整本播放列表没有「单一字幕」语义（各集字幕按
  /// 磁盘动态解析），拖单个字幕文件无法确定挂哪一集 → 不落库，提示进播放页按集挂。
  playlistNeedsPlayer,

  /// 落地失败：拷字幕到持久目录、或原子写源指针+cue 时抛异常（IO / DB 写入）。
  /// 用户视角同为「保存字幕失败」，真实异常进 debugPrint。
  persistFailed,

  /// 字幕 cue 读不出/解不出：具体原因见 [SubtitleAttachResult.cueFailure]。
  /// 不落库、不覆盖现有可用字幕。
  cueLoadFailed,
}

/// 把字幕挂到现有视频书的结果。[cueCount] 仅 [SubtitleAttachOutcome.attached]
/// 时有意义（解析出的句数）；[label] 是用于 UI 反馈的字幕文件名；
/// [cueFailure] 仅 [SubtitleAttachOutcome.cueLoadFailed] 时非空。
class SubtitleAttachResult {
  const SubtitleAttachResult({
    required this.outcome,
    this.cueCount = 0,
    this.label = '',
    this.cueFailure,
  }) : assert(
          (outcome == SubtitleAttachOutcome.cueLoadFailed) ==
              (cueFailure != null),
          'cueFailure ⇔ cueLoadFailed',
        );

  final SubtitleAttachOutcome outcome;
  final int cueCount;
  final String label;

  /// cue 加载失败的原因（复用播放页分类），仅 [SubtitleAttachOutcome.cueLoadFailed]。
  final SubtitleCueLoadFailure? cueFailure;
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
/// **本函数是全函数（total）：任何失败都进返回值，绝不抛**（BUG-1504）。调用方
/// 是 fire-and-forget 的拖放事件处理器，一旦异常从这里逃出去就没有任何调用栈能
/// 承接它——用户看到的是「拖了一下，什么都没发生」。
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

  // 扩展名先过一遍：不受支持的文件连拷都不拷进持久目录。判据与播放页同一个
  // [subtitleFormatForPath]，失败原因也用同一个枚举值。
  if (subtitleFormatForPath(subtitlePath) == null) {
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.cueLoadFailed,
      cueFailure: SubtitleCueLoadFailure.unsupportedFormat,
      label: p.basename(subtitlePath),
    );
  }

  // 拷到持久目录 `<appDocs>/video_subtitles/<basename>`（与播放页导入同处），
  // 持久化值为该副本的绝对路径——源文件被移走/换机也能恢复（BUG-132）。
  // 建目录和拷贝都可能抛（无权限 / 磁盘满 / 路径非法），一起收进 persistFailed。
  final String dest;
  try {
    final String destDir = destDirOverride ?? await _defaultSubtitleDir();
    await Directory(destDir).create(recursive: true);
    dest = p.join(destDir, p.basename(subtitlePath));
    if (!p.equals(subtitlePath, dest)) {
      await File(subtitlePath).copy(dest);
    }
  } catch (e) {
    debugPrint('[subtitle-attach] copy failed: $subtitlePath: $e');
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.persistFailed,
      label: p.basename(subtitlePath),
    );
  }

  // 读 + 解析走播放页同一入口：读不出 / 解不出分别是 fileUnreadable / parseFailed，
  // 不抛（BUG-1490 的分类，BUG-1504 起主页拖放复用它，不再自己 read+parse）。
  final SubtitleCueLoadResult loaded = await loadExternalSubtitleCueResult(
    dest,
    book.bookUid,
    contentReader: contentReader,
  );
  if (loaded.isFailure) {
    // 不落库、不覆盖现有可用字幕（与播放页同语义）。
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.cueLoadFailed,
      cueFailure: loaded.failure,
      label: p.basename(dest),
    );
  }

  // 单视频：源指针 + cue 原子写入（BUG-081），下次进播放页 `loadCues` 直接命中。
  try {
    await repo.saveSubtitleSelection(
      bookUid: book.bookUid,
      subtitleSource: dest,
      cues: loaded.cues,
    );
  } catch (e, stack) {
    debugPrint('[subtitle-attach] save failed: ${book.bookUid}: $e\n$stack');
    return SubtitleAttachResult(
      outcome: SubtitleAttachOutcome.persistFailed,
      label: p.basename(dest),
    );
  }
  return SubtitleAttachResult(
    outcome: SubtitleAttachOutcome.attached,
    cueCount: loaded.cues.length,
    label: p.basename(dest),
  );
}

Future<String> _defaultSubtitleDir() async {
  // TODO-935 E0：字幕副本目录经唯一入口 [AppPaths] 派生 `<documents>/video_subtitles`。
  final Directory dir = await AppPaths.videoSubtitlesDirectory();
  return dir.path;
}

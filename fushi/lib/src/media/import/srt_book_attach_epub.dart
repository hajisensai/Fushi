import 'dart:io';

import 'package:fushi_audio/fushi_audio_core.dart';

import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';

/// 给「没有用户 EPUB 正文」的字幕书补一本书籍文件时，书籍导入对话框需要的预填。
///
/// 背景（反馈 Q0kWQNkF2f / Ulw9gIyZGk）：在 Fushi 里下载有声书并自动转录字幕后，
/// 它落成一本**正文由 cue 生成**的字幕书。之后用户拿到了对应的 EPUB，却没有任何
/// 入口把 EPUB 配上去：书架菜单只有「重新导入」（只换音频 / 字幕两半），而书籍导入
/// 对话框虽然支持「EPUB + 字幕 + 音频」对齐导入，转录出的字幕和下载的音频都躺在
/// App 私有目录里，用户在文件选择器里根本找不到它们。
///
/// 这里把这本书已有的两半（音频文件、字幕文件）解析成真实存在的路径，交给
/// `BookImportDialog` 的 `initialAudioPaths` / `initialSubtitlePath`，用户只需再选
/// EPUB，走的就是唯一的对齐导入路径 `alignAndPersistAudiobook`（它会把音频与字幕
/// 复制进新书自己的持久目录，所以之后删掉原字幕书不会伤到新书）。
class SrtBookEpubAttachPrefill {
  const SrtBookEpubAttachPrefill({
    required this.audioPaths,
    required this.subtitlePath,
  });

  /// 按 `AudioCue.audioFileIndex` 口径排好序、磁盘上真实存在的音频文件。
  final List<String> audioPaths;

  /// 磁盘上真实存在的字幕文件；不存在（被清理 / 引用的原文件被挪走）时为 null，
  /// 用户在对话框里会看到字幕行为空、需要自己再选或转录。
  final String? subtitlePath;
}

/// 这本字幕书能否「添加书籍文件」：正文**不是**用户自己的 EPUB 时才能。
///
/// 判据与 `reimportSrtBook` 的负向闸门同源（uid 形态）：`srtbook_epub_<bookKey>`
/// 是 EPUB 有声书的配对行，它已经有用户的 EPUB 正文，再「添加」就是重复导入。
/// bookKey 为空的孤儿字幕书（首次导入没生成正文）同样可以补 EPUB。
bool srtBookCanAttachEpub(SrtBook book) =>
    book.uid != epubBackedSrtBookUid(book.bookKey);

/// 解析 [book] 现有音频与字幕的真实路径，供书籍导入对话框预填。
///
/// 音频读的是播放侧同一口径 [resolveAudiobookPlaybackFiles]（`audioPaths` 优先，
/// 否则枚举 `audioRoot`），顺序就是 cue 的 `audioFileIndex` 含义——对齐导入会按
/// 这个顺序重新落库，顺序错了跳播全偏。
Future<SrtBookEpubAttachPrefill> resolveSrtBookEpubAttachPrefill(
  SrtBook book,
) async {
  final List<File> audio = await resolveAudiobookPlaybackFiles(
    audioPaths: book.audioPaths,
    audioRoot: book.audioRoot,
  );
  final String srtPath = book.srtPath;
  final bool hasSubtitle =
      srtPath.trim().isNotEmpty && await File(srtPath).exists();
  return SrtBookEpubAttachPrefill(
    audioPaths: <String>[for (final File f in audio) f.path],
    subtitlePath: hasSubtitle ? srtPath : null,
  );
}

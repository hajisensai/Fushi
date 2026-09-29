import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart'
    show DiscoveryImportBlocker;

/// 任务行要显示的失败原因（BUG-2775）：自动入库被挡下的原因码翻译成用户能照着
/// 做的文案；其余（旧任务、下载/网络诊断文本）原样返回。
String describeAnimeDownloadFailReason(String reason) {
  final DiscoveryImportBlocker? blocker =
      parseAnimeDownloadBlockedFailReason(reason);
  if (blocker == null) return reason;
  switch (blocker) {
    case DiscoveryImportBlocker.unknownFileType:
      return t.download_task_import_blocked_unknown_type;
    case DiscoveryImportBlocker.audiobookMissingText:
      return t.download_task_import_blocked_audiobook_no_text;
    case DiscoveryImportBlocker.audiobookMissingSubtitle:
      return t.download_task_import_blocked_audiobook_no_subtitle;
    case DiscoveryImportBlocker.audiobookMissingAudio:
      return t.download_task_import_blocked_audiobook_no_audio;
    case DiscoveryImportBlocker.audiobookBookAlreadyInLibrary:
      return t.download_task_import_blocked_audiobook_book_exists;
    case DiscoveryImportBlocker.gameNoExecutable:
      return t.download_task_import_blocked_game_no_exe;
    case DiscoveryImportBlocker.archiveToolMissing:
      return t.download_task_import_blocked_archive_tool_missing;
    case DiscoveryImportBlocker.archiveExtractionFailed:
      return t.download_task_import_blocked_archive_failed;
  }
}

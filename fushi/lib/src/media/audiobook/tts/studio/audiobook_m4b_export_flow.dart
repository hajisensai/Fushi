/// 「导出有声书（M4B）」的交互流程：选保存位置 / 移动端分享、进度回调、成败提示。
///
/// 制作页与「已附加有声书」对话框共用这一份——导出能力对任何已入库的有声书都成立
/// （TTS 制作的或用户导入的），不能只挂在制作页上，否则离开制作页就没有出口。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/src/media/audiobook/tts/studio/tts_audiobook_export.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/utils.dart';

/// 导出 [bookKey] 的有声书为 M4B：桌面选保存位置直接写；移动端写进 app 自管的
/// 暂存目录再走系统分享（暂存目录每次导出前清空，见
/// [prepareTtsAudiobookShareStagingDir]）。
///
/// [title] 为空时取库里的书名。用户取消保存框时不调 [onStart] 直接返回；否则先调
/// [onStart]，导出期间经 [onProgress] 报 0..1。失败只弹提示、不抛。
Future<void> runAudiobookM4bExport({
  required FushiDatabase database,
  required String bookKey,
  String? title,
  required void Function() onStart,
  required void Function(double progress) onProgress,
}) async {
  final String bookTitle =
      title ?? (await database.getEpubBook(bookKey))?.title ?? '';
  final String fileName = ttsAudiobookExportFileName(bookTitle);
  final bool desktop = isDesktopPlatform;
  String? pickedPath;
  if (desktop) {
    // 只在桌面弹保存框（移动端走分享），默认文件名已带 .m4b；不传
    // FileType.custom 扩展名过滤（BUG-2099 的选择器纪律，同 collection_exporter）。
    final String? picked = await FilePicker.platform.saveFile(
      dialogTitle: t.audiobook_studio_export,
      fileName: fileName,
    );
    if (picked == null || picked.trim().isEmpty) return;
    pickedPath = picked;
  }
  onStart();
  try {
    final String outputPath = pickedPath ?? await _shareStagingPath(fileName);
    final String written = await exportTtsAudiobookM4b(
      database: database,
      bookKey: bookKey,
      outputPath: outputPath,
      onProgress: onProgress,
    );
    if (desktop) {
      FushiToast.show(msg: t.audiobook_studio_export_done(path: written));
    } else {
      final String srt = p.setExtension(written, '.srt');
      await FushiShare.shareFiles(<XFile>[
        XFile(written, mimeType: 'audio/mp4', name: p.basename(written)),
        if (File(srt).existsSync())
          XFile(srt, mimeType: 'application/x-subrip', name: p.basename(srt)),
      ], subject: p.basename(written));
    }
  } on AudiobookExportFailure catch (failure) {
    FushiToast.show(
      msg: ttsAudiobookExportFailureText(failure.code, failure.message),
    );
  } catch (e, stack) {
    ErrorLogService.instance.log('AudiobookExport', e, stack);
    FushiToast.show(
      msg: ttsAudiobookExportFailureText(
        'export_failed',
        t.audiobook_studio_failure_internal,
      ),
    );
  }
}

/// 移动端分享导出的输出路径：清掉上一次导出留下的暂存，再落在空的暂存目录里。
Future<String> _shareStagingPath(String fileName) async {
  final Directory staging = await prepareTtsAudiobookShareStagingDir(
    Directory(
      p.join(Directory.systemTemp.path, kTtsAudiobookShareStagingDirName),
    ),
  );
  return p.join(staging.path, fileName);
}

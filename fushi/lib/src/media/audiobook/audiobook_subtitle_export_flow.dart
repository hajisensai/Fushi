/// 有声书播放页（歌词模式）的「导出当前字幕」（反馈 iUtGmIlZiD）：把播放器正在用的
/// 整本 cue 写成一份单时间轴 SRT——桌面选保存位置直接写，移动端写进 app 自管的暂存
/// 目录再走系统分享。
///
/// 以前只有转录弹层里有「导出字幕文件」，转录完直接去听就再找不到出口。这里导出的
/// 是播放器手上的 cue（转录 / 导入字幕 / 重新匹配后的都一样），时间轴与 M4B 里封的
/// 字幕同一套（[buildAudiobookSubtitleSrt]）。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart'
    show suggestedTranscriptFileName;
import 'package:fushi/src/media/audiobook/tts/studio/tts_audiobook_export.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_text.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 移动端分享字幕的暂存目录名（系统临时目录下，app 自管；与 M4B 分享的暂存目录
/// 分开，两种导出互不清掉对方正在分享的文件）。
const String kAudiobookSubtitleShareStagingDirName = 'fushi_srt_share';

/// 导出用的默认文件名：有本地音频时与转录弹层的「导出字幕文件」同名（首个音频去
/// 扩展名 + `.srt`）；没有（远程串流）时取书名。
String audiobookSubtitleExportFileName({
  required List<String> audioPaths,
  required String title,
}) {
  if (audioPaths.isNotEmpty) return suggestedTranscriptFileName(audioPaths);
  return p.setExtension(ttsAudiobookExportFileName(title), '.srt');
}

/// 导出 [cues] 为 SRT。返回是否真的导出了（用户取消保存框 / 失败返回 false）；失败
/// 只弹提示、不抛。[saveFilePicker] / [desktop] / [probeDurations] 可注入，测试里替换
/// 平台对话框与 ffmpeg 探测。
Future<bool> runAudiobookSubtitleExport({
  required List<AudioCue> cues,
  required List<String> audioPaths,
  required String title,
  Future<String?> Function({
    required String fileName,
    required String? initialDirectory,
  })?
  saveFilePicker,
  bool? desktop,
  Future<List<int>> Function(List<String> files)? probeDurations,
}) async {
  try {
    // 先生成正文：没有字幕 / 文件不在本地这类失败在弹保存框之前就报出来。
    final String srt = await buildAudiobookSubtitleSrt(
      cues: cues,
      audioPaths: audioPaths,
      probeDurations: probeDurations,
    );
    final String fileName = audiobookSubtitleExportFileName(
      audioPaths: audioPaths,
      title: title,
    );
    if (desktop ?? isDesktopPlatform) {
      final Future<String?> Function({
        required String fileName,
        required String? initialDirectory,
      })
      pick =
          saveFilePicker ??
          // 默认文件名已带 .srt；不传 FileType.custom 扩展名过滤（BUG-2099 的
          // 选择器纪律，豁免清单只减不增，同 M4B 导出）。
          ({required String fileName, required String? initialDirectory}) =>
              FilePicker.platform.saveFile(
                dialogTitle: t.audiobook_transcribe_export,
                fileName: fileName,
                initialDirectory: initialDirectory,
              );
      final String? savePath = await pick(
        fileName: fileName,
        initialDirectory: audioPaths.isEmpty
            ? null
            : File(audioPaths.first).parent.path,
      );
      if (savePath == null || savePath.trim().isEmpty) return false;
      await File(savePath).writeAsString(srt, flush: true);
      FushiToast.show(msg: t.audiobook_transcribe_export_saved);
      return true;
    }
    final Directory staging = await prepareTtsAudiobookShareStagingDir(
      Directory(
        p.join(
          Directory.systemTemp.path,
          kAudiobookSubtitleShareStagingDirName,
        ),
      ),
    );
    final String path = p.join(staging.path, fileName);
    await File(path).writeAsString(srt, flush: true);
    await FushiShare.shareFiles(<XFile>[
      XFile(path, mimeType: 'application/x-subrip', name: fileName),
    ], subject: fileName);
    return true;
  } on AudiobookExportFailure catch (failure) {
    FushiToast.show(
      msg: ttsAudiobookExportFailureText(failure.code, failure.message),
    );
    return false;
  } catch (e, stack) {
    ErrorLogService.instance.log('AudiobookSubtitleExport', e, stack);
    FushiToast.show(
      msg: ttsAudiobookExportFailureText(
        'export_failed',
        t.audiobook_studio_failure_internal,
      ),
    );
    return false;
  }
}

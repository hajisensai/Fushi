/// 「先把整集音频拉到本机」的进度对话框（在线流 / 网页档生成字幕的前置步骤）：原生播放器页
/// 与内置网页播放器页共用，只有出错时怎么告诉用户由调用方决定（OSD / toast）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart'
    show
        VideoStreamSubtitleAudioCancelled,
        VideoStreamSubtitleAudioStaging,
        VideoStreamSubtitleAudioUnavailable,
        appVideoStreamSubtitleAudioStager;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiProgressDialogHandle, showFushiProgressDialog;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 已有本机副本就直接返回；否则 [start] 开拉（返回 null = 此刻不该拉，比如已换集），拉取
/// 期间显示有进度、可取消的对话框。取消 / 不该拉时返回 null；拿不到媒体时记错误日志并把
/// 给用户看的完整一句交给 [onUnavailable]，返回 null。
Future<File?> stageVideoStreamSubtitleAudioWithDialog(
  BuildContext context, {
  required String key,
  required String title,
  required VideoStreamSubtitleAudioStaging? Function() start,
  required String logTag,
  required void Function(String message) onUnavailable,
}) async {
  final File? existing = await appVideoStreamSubtitleAudioStager.existing(
    key: key,
    title: title,
  );
  if (existing != null) return existing;
  if (!context.mounted) return null;
  final VideoStreamSubtitleAudioStaging? staging = start();
  if (staging == null) return null;
  final FushiProgressDialogHandle dialog = showFushiProgressDialog(
    context: context,
    title: t.video_subtitle_stream_audio_title,
    message: t.video_subtitle_stream_audio_hint,
    initialProgress: staging.progress.value,
    onCancel: staging.cancel,
  );
  void sync() => dialog.progress.value = staging.progress.value;
  staging.progress.addListener(sync);
  try {
    final File audio = await staging.done;
    dialog.close();
    // 等进度对话框真正出栈再推面板，免得面板被压在正在退场的对话框下面。
    await dialog.done;
    return audio;
  } on VideoStreamSubtitleAudioCancelled {
    return null;
  } on VideoStreamSubtitleAudioUnavailable catch (error, stack) {
    ErrorLogService.instance.log(logTag, error, stack);
    onUnavailable(t.video_subtitle_stream_audio_failed(reason: error.message));
    return null;
  } finally {
    staging.progress.removeListener(sync);
    dialog.close();
  }
}

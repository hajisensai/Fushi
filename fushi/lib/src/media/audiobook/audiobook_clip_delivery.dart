/// 「导出片段视频」的交付步（M5）：合成好的 .mp4 → 桌面另存 / 移动系统分享，并给出
/// 结果提示。小说有声书（`reader_fushi/audiobook.part.dart`）与漫画有声书
/// （`manga_audio_clip_export.dart`）共用这一份，两边的存盘 / 分享 / 诚实文案不会分叉。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart' show XFile;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 交付结果。
enum AudiobookClipDeliveryOutcome {
  /// 桌面已另存 / 移动分享面板已呈现。
  saved,

  /// 桌面另存对话框被取消（不提示）。
  cancelled,

  /// 移动分享面板没呈现（防重入门丢弃 / 平台不回包）。
  shareUnavailable,
}

/// 把 [videoPath] 交给用户：桌面（含 Linux）走 FilePicker 另存（默认文件名
/// [fileName]），移动走系统分享（[subject] 作分享标题）。
///
/// 临时视频文件归调用方清理：桌面已拷到用户选定路径，可删；移动端系统分享异步读取
/// 原文件，必须保留。
Future<AudiobookClipDeliveryOutcome> deliverAudiobookClipVideo({
  required String videoPath,
  required String fileName,
  required String subject,
  required bool isDesktop,
}) async {
  if (isDesktop) {
    final String? savePath = await FilePicker.platform.saveFile(
      dialogTitle: t.audiobook_export_clip,
      // BUG-809：桌面导出 .mp4（H.264，通用可直接播放）。
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const <String>['mp4'],
    );
    if (savePath == null) return AudiobookClipDeliveryOutcome.cancelled;
    await File(videoPath).copy(savePath);
    return AudiobookClipDeliveryOutcome.saved;
  }
  final List<XFile> sharedFiles =
      audiobookClipMobileShareAttachments(videoPath: videoPath)
          .map(
            (AudiobookClipShareAttachment attachment) =>
                XFile(attachment.path, mimeType: attachment.mimeType),
          )
          .toList(growable: false);
  // BUG-1243：产物契约是单个带声视频，不再把中间 .aac 当第二个附件泄漏出去。
  //
  // BUG-2542：移动端产物落 app 私有目录（不进相册），这次分享面板是用户取回它的
  // 唯一通道。面板没呈现时不能再报「已保存」——那是个用户拿不到文件的假成功。
  final bool shared = await FushiShare.shareFiles(
    sharedFiles,
    subject: subject,
  );
  return shared
      ? AudiobookClipDeliveryOutcome.saved
      : AudiobookClipDeliveryOutcome.shareUnavailable;
}

/// 按交付结果提示（取消不提示）。
void toastAudiobookClipDelivery(AudiobookClipDeliveryOutcome outcome) {
  switch (outcome) {
    case AudiobookClipDeliveryOutcome.saved:
      FushiToast.show(
        msg: t.audiobook_export_clip_saved,
        severity: ToastSeverity.success,
      );
    case AudiobookClipDeliveryOutcome.shareUnavailable:
      FushiToast.show(
        msg: t.audiobook_export_clip_share_unavailable,
        severity: ToastSeverity.warning,
      );
    case AudiobookClipDeliveryOutcome.cancelled:
      break;
  }
}

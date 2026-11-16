// 反馈「样本文件」附件（拍板台 PLFh2VXDcN / ZbLcRNOvKU）：字幕、书、有声书 / 音乐、视频原件、
// 漫画包、词典、Markdown / 纯文本——开发者拿到原文件才能复现导入 / 解析 / 播放类问题。
//
// 服务端（services/leaderboard/src/feedback_files.js，槽位 f0..f2）按扩展名白名单
// [FeedbackLimits.fileExtensions] 收、再按扩展名核对文件头魔数，每个 ≤ [FeedbackLimits.fileMaxBytes]，
// 一律当不可信文件存、只给开发者作附件下载。这里在本机先拦住服务端必然拒收的（扩展名 / 空文件 /
// 超限），提交时原样复制进待传区再流式上传（不转码、不改内容）。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:path/path.dart' as p;

/// 本机就能判定的「传不上去」原因。
enum FeedbackFileProblem { unsupportedType, empty, tooLarge }

/// 样本文件扩展名（小写、不带点；没有扩展名返回空串）。
String feedbackFileExtension(String path) {
  final String ext = p.extension(path);
  return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
}

/// 这个文件能不能作样本文件附上：扩展名在白名单里、非空、不超过上限时返回 null。
FeedbackFileProblem? feedbackFileProblem(String path, int bytes) {
  if (!FeedbackLimits.fileExtensions.contains(feedbackFileExtension(path))) {
    return FeedbackFileProblem.unsupportedType;
  }
  if (bytes <= 0) return FeedbackFileProblem.empty;
  if (bytes > FeedbackLimits.fileMaxBytes) return FeedbackFileProblem.tooLarge;
  return null;
}

/// 选样本文件（可多选）。桌面对话框按白名单过滤；手机上系统选择器不认识 mdx / ass 这类
/// 扩展名对应的 MIME（过滤会把它们藏掉），所以不过滤、选完由 [feedbackFileProblem] 把关。
/// 取消返回空列表。
Future<List<File>> pickFeedbackFiles() async {
  final bool desktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: desktop ? FileType.custom : FileType.any,
    allowedExtensions: desktop
        ? (FeedbackLimits.fileExtensions.toList()..sort())
        : null,
    allowMultiple: true,
  );
  if (result == null) return const <File>[];
  return <File>[
    for (final PlatformFile f in result.files)
      if (f.path case final String path) File(path),
  ];
}

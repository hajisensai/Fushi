import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:path_provider/path_provider.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// 是否在日志页工具栏给当前平台展示「另存为」按钮。
///
/// 仅桌面端展示：移动端的系统「分享」按钮已经能把日志文件发到任意 app，
/// 真正缺真实保存对话框的只有桌面端。
bool get showSaveLogAction => _isDesktop;

/// 把日志保存成文件。
///
/// 复用 [sync_settings_schema] 的平台分流模式：桌面端用
/// `FilePicker.saveFile` 弹真实保存对话框，移动端回退系统分享
/// （移动端无文件对话框，分享即导出）。
Future<void> saveLogToFile({
  required BuildContext context,
  required String log,
  required String fileName,
  required String subject,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  File? tmp;
  try {
    final Directory tmpDir = await getTemporaryDirectory();
    final String tmpPath = '${tmpDir.path}/$fileName';
    tmp = File(tmpPath);
    await tmp.writeAsString(log);

    if (_isDesktop) {
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: t.log_export_file,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: <String>['txt'],
      );
      if (savePath != null) {
        await tmp.copy(savePath);
        messenger.showSnackBar(SnackBar(content: Text(t.log_export_saved)));
      }
    } else {
      await Share.shareXFiles(
        <XFile>[XFile(tmpPath, mimeType: 'text/plain')],
        subject: subject,
      );
    }
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(t.log_export_failed)));
  } finally {
    // 桌面端导出完（含取消保存）清理临时文件；移动端分享需保留文件供
    // 系统分享面板异步读取，不在此删。
    if (_isDesktop && tmp != null) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }
}

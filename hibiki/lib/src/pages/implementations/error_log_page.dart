import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/src/utils/misc/log_exporter.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';
import 'package:hibiki/src/utils/misc/log_uploader.dart';
import 'package:hibiki/utils.dart';

class ErrorLogPage extends StatelessWidget {
  const ErrorLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final log = ErrorLogService.instance.getFullLog();
    final count = ErrorLogService.instance.entries.length;

    return HibikiPageScaffold(
      title: t.error_log_label(n: count),
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.copy_outlined,
          tooltip: t.copy,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: log));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(t.copied_to_clipboard)),
              );
            }
          },
        ),
        HibikiIconButton(
          icon: Icons.share_outlined,
          tooltip: t.share,
          onTap: () {
            final bytes = Uint8List.fromList(utf8.encode(log));
            final xFile = XFile.fromData(
              bytes,
              name: 'hibiki_error_log.txt',
              mimeType: 'text/plain',
            );
            Share.shareXFiles([xFile], subject: t.error_log_share_subject);
          },
        ),
        if (showUploadLogAction)
          HibikiIconButton(
            icon: Icons.cloud_upload_outlined,
            tooltip: t.log_upload_action,
            onTap: () => uploadLogToServer(
              context: context,
              log: log,
              kind: 'error',
            ),
          ),
        if (showSaveLogAction)
          HibikiIconButton(
            icon: Icons.save_alt_outlined,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: log,
              fileName: 'hibiki_error_log.txt',
              subject: t.error_log_share_subject,
            ),
          ),
        HibikiIconButton(
          icon: Icons.delete_outline,
          tooltip: t.clear,
          onTap: () {
            ErrorLogService.instance.clear();
            Navigator.pop(context);
          },
        ),
      ],
      body: HibikiLogPanel(
        log: log,
        shareAction: (text) => Share.share(text),
      ),
    );
  }
}

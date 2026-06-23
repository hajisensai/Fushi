import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/src/utils/misc/log_exporter.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';
import 'package:hibiki/src/utils/misc/log_uploader.dart';
import 'package:hibiki/utils.dart';

class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key});

  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  // TODO-762：把 getFullLog() 的全量拼接移出 build。旧实现是 StatelessWidget，每次
  // rebuild 都在 build() 里同步重拼最大 ~512KB 日志字符串（O(条目数) StringBuffer）。
  // 改 StatefulWidget：initState 拼一次缓存进 _log，并监听 ErrorLogService（新错误
  // 进来时只在该回调内重拼一次）——build 只读缓存，不再每帧重算。
  String _log = '';

  @override
  void initState() {
    super.initState();
    _log = ErrorLogService.instance.getFullLog();
    ErrorLogService.instance.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    ErrorLogService.instance.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onLogChanged() {
    if (!mounted) return;
    setState(() {
      _log = ErrorLogService.instance.getFullLog();
    });
  }

  @override
  Widget build(BuildContext context) {
    final int count = ErrorLogService.instance.entries.length;

    return HibikiPageScaffold(
      title: t.error_log_label(n: count),
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.copy_outlined,
          tooltip: t.copy,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: _log));
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
            final bytes = Uint8List.fromList(utf8.encode(_log));
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
              log: _log,
              kind: 'error',
            ),
          ),
        if (showSaveLogAction)
          HibikiIconButton(
            icon: Icons.save_alt_outlined,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: _log,
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
        log: _log,
        shareAction: (text) => Share.share(text),
      ),
    );
  }
}

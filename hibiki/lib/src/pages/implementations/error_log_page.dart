import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/components/Hibiki_text_selection_controls.dart';

class ErrorLogPage extends StatelessWidget {
  const ErrorLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final log = ErrorLogService.instance.getFullLog();
    final count = ErrorLogService.instance.entries.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.error_log_label(n: count)),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: t.copy,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t.copied_to_clipboard)),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: t.share,
            onPressed: () {
              final bytes = Uint8List.fromList(utf8.encode(log));
              final xFile = XFile.fromData(
                bytes,
                name: 'hibiki_error_log.txt',
                mimeType: 'text/plain',
              );
              Share.shareXFiles([xFile], subject: t.error_log_share_subject);
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: t.clear,
            onPressed: () {
              ErrorLogService.instance.clear();
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          12,
          12,
          12,
          12 + MediaQuery.of(context).padding.bottom,
        ),
        child: SelectableText(
          log,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          selectionControls: HibikiTextSelectionControls(
            shareAction: (text) => Share.share(text),
            allowCopy: true,
            allowCut: false,
            allowPaste: false,
            allowSelectAll: true,
          ),
        ),
      ),
    );
  }
}

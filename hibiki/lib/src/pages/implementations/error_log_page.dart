import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/utils.dart';

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
              Share.share(log, subject: t.error_log_share_subject);
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
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          log,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

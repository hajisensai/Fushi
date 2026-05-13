import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/components/jidoujisho_text_selection_controls.dart';

class DebugLogPage extends StatefulWidget {
  const DebugLogPage({super.key});

  @override
  State<DebugLogPage> createState() => _DebugLogPageState();
}

class _DebugLogPageState extends State<DebugLogPage> {
  String _log = '';

  @override
  void initState() {
    super.initState();
    _log = DebugLogService.instance.getFullLog();
  }

  @override
  Widget build(BuildContext context) {
    final int count = DebugLogService.instance.entries.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.debug_log_title(count: count)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: t.stat_refresh,
            onPressed: () => setState(() {
              _log = DebugLogService.instance.getFullLog();
            }),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: t.copy,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _log));
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
              final Uint8List bytes = Uint8List.fromList(utf8.encode(_log));
              final XFile xFile = XFile.fromData(
                bytes,
                name: 'hibiki_debug_log.txt',
                mimeType: 'text/plain',
              );
              Share.shareXFiles([xFile], subject: 'hibiki Debug Log');
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: t.clear,
            onPressed: () {
              DebugLogService.instance.clear();
              setState(() {
                _log = DebugLogService.instance.getFullLog();
              });
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          12, 12, 12, 12 + MediaQuery.of(context).padding.bottom,
        ),
        child: SelectableText(
          _log,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          selectionControls: JidoujishoTextSelectionControls(
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

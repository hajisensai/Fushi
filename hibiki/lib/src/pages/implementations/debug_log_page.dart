import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:hibiki/src/utils/misc/log_exporter.dart';
import 'package:hibiki/utils.dart';

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

    return HibikiPageScaffold(
      title: t.debug_log_title(count: count),
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.refresh,
          tooltip: t.stat_refresh,
          onTap: () => setState(() {
            _log = DebugLogService.instance.getFullLog();
          }),
        ),
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
            final Uint8List bytes = Uint8List.fromList(utf8.encode(_log));
            final XFile xFile = XFile.fromData(
              bytes,
              name: 'hibiki_debug_log.txt',
              mimeType: 'text/plain',
            );
            Share.shareXFiles([xFile], subject: t.debug_log_share_subject);
          },
        ),
        if (showSaveLogAction)
          HibikiIconButton(
            icon: Icons.save_alt_outlined,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: _log,
              fileName: 'hibiki_debug_log.txt',
              subject: t.debug_log_share_subject,
            ),
          ),
        HibikiIconButton(
          icon: Icons.delete_outline,
          tooltip: t.clear,
          onTap: () {
            DebugLogService.instance.clear();
            setState(() {
              _log = DebugLogService.instance.getFullLog();
            });
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

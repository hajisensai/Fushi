import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi/src/utils/misc/log_exporter.dart';
import 'package:fushi/src/utils/misc/log_upload_config.dart';
import 'package:fushi/src/utils/misc/log_uploader.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/settings/settings_kit.dart';

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

    // 设置子页统一壳（settings kit）：浮动页头 + 动作组胶囊，与 schema 详情页一致。
    return SettingsKitScaffold(
      leadingIcon: FushiIcons.file,
      leadingTone: SettingsIconTone.gray,
      title: t.debug_log_title(count: count),
      actions: <Widget>[
        FushiIconButton(
          icon: Icons.refresh,
          tooltip: t.stat_refresh,
          onTap: () => setState(() {
            _log = DebugLogService.instance.getFullLog();
          }),
        ),
        FushiIconButton(
          icon: Icons.copy_outlined,
          tooltip: t.copy,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: _log));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                FushiSnackBar(content: Text(t.copied_to_clipboard)),
              );
            }
          },
        ),
        FushiIconButton(
          icon: Icons.share_outlined,
          tooltip: t.share,
          onTap: () {
            final Uint8List bytes = Uint8List.fromList(utf8.encode(_log));
            final XFile xFile = XFile.fromData(
              bytes,
              name: 'fushi_debug_log.txt',
              mimeType: 'text/plain',
            );
            FushiShare.shareFiles([xFile], subject: t.debug_log_share_subject);
          },
        ),
        if (showUploadLogAction)
          FushiIconButton(
            icon: Icons.cloud_upload_outlined,
            tooltip: t.log_upload_action,
            onTap: () => uploadLogToServer(
              context: context,
              log: _log,
              kind: 'debug',
            ),
          ),
        if (showSaveLogAction)
          FushiIconButton(
            icon: Icons.save_alt_outlined,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: _log,
              fileName: 'fushi_debug_log.txt',
              subject: t.debug_log_share_subject,
            ),
          ),
        FushiIconButton(
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
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiLogPanel(
        log: _log,
        shareAction: (text) => FushiShare.shareText(text),
      ),
    );
  }
}

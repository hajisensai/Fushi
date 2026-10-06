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

    // 设置子页统一壳（settings kit）：浮动页头 + 动作组胶囊，与 schema 详情页一致。
    return SettingsKitScaffold(
      leadingIcon: FushiIcons.error,
      leadingTone: SettingsIconTone.gray,
      title: t.error_log_label(n: count),
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.copy,
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
          icon: FushiIcons.share,
          tooltip: t.share,
          onTap: () {
            final bytes = Uint8List.fromList(utf8.encode(_log));
            final xFile = XFile.fromData(
              bytes,
              name: 'fushi_error_log.txt',
              mimeType: 'text/plain',
            );
            FushiShare.shareFiles([xFile], subject: t.error_log_share_subject);
          },
        ),
        if (showUploadLogAction)
          FushiIconButton(
            icon: FushiIcons.cloudUpload,
            tooltip: t.log_upload_action,
            onTap: () => uploadLogToServer(
              context: context,
              log: _log,
              kind: 'error',
            ),
          ),
        if (showSaveLogAction)
          FushiIconButton(
            icon: FushiIcons.save,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: _log,
              fileName: 'fushi_error_log.txt',
              subject: t.error_log_share_subject,
            ),
          ),
        FushiIconButton(
          icon: FushiIcons.delete,
          tooltip: t.clear,
          onTap: () {
            ErrorLogService.instance.clear();
            Navigator.pop(context);
          },
        ),
      ],
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => count == 0
          // 空状态：settings kit 统一空态（M3E 形状图标 + 标题），不是一块只写着
          // 「暂无日志」的空日志面板。
          ? SettingsEmptyState(icon: FushiIcons.success, title: t.error_log_empty)
          : FushiLogPanel(
              log: _log,
              shareAction: (text) => FushiShare.shareText(text),
            ),
    );
  }
}

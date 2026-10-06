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
          icon: FushiIcons.refresh,
          tooltip: t.stat_refresh,
          onTap: () => setState(() {
            _log = DebugLogService.instance.getFullLog();
          }),
        ),
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
            icon: FushiIcons.cloudUpload,
            tooltip: t.log_upload_action,
            onTap: () => uploadLogToServer(
              context: context,
              log: _log,
              kind: 'debug',
            ),
          ),
        if (showSaveLogAction)
          FushiIconButton(
            icon: FushiIcons.save,
            tooltip: t.log_export_file,
            onTap: () => saveLogToFile(
              context: context,
              log: _log,
              fileName: 'fushi_debug_log.txt',
              subject: t.debug_log_share_subject,
            ),
          ),
        FushiIconButton(
          icon: FushiIcons.delete,
          tooltip: t.clear,
          onTap: () {
            DebugLogService.instance.clear();
            setState(() {
              _log = DebugLogService.instance.getFullLog();
            });
          },
        ),
      ],
      // 保留 false（壳替正文整体让开页头）：日志正文是 FushiLogPanel——定高圆角卡
      // 内自带滚动的 ListView（自持选区滚动控制器，BUG-119 / BUG-1582 防线），
      // 不接壳的滚动控制器；卡片外框是固定版面，内容滚不到页头底下，强行顶到
      // 页头下只会让卡片上沿被浮动页头盖住。
      bodyConsumesTopPadding: false,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => count == 0
          // 空状态：settings kit 统一空态（M3E 形状图标 + 标题），不是一块只写着
          // 「暂无日志」的空日志面板。
          ? SettingsEmptyState(icon: FushiIcons.file, title: t.no_debug_logs)
          : FushiLogPanel(
              log: _log,
              shareAction: (text) => FushiShare.shareText(text),
            ),
    );
  }
}

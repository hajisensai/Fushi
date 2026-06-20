import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'package:hibiki/src/utils/spacing.dart';
import 'package:hibiki/src/utils/misc/crash_dump_locator.dart';
import 'package:hibiki/utils.dart';

/// TODO-607 P0-3：「诊断区 → 崩溃转储」页（Windows-only）。
///
/// 列出 native runner 写在 `%LOCALAPPDATA%\Hibiki\crashdumps\` 的 minidump
/// （[CrashDumpLocator]），让用户一键**打开文件夹**（资源管理器）或**分享 .dmp**
/// 给开发者。纯 native 闪退（嵌套查词把进程带崩等）不会进 Dart 错误日志，这些
/// `.dmp` 是定位它的唯一二进制证据；过去散落在 `%LOCALAPPDATA%` 用户找不到。
///
/// 顶部常驻**隐私提示**：`.dmp` 含进程内存快照，可能带用户阅读/查词文本，提醒
/// 只分享给信任的开发者。
///
/// 视觉 chrome 全部走共享 MD3 组件（[HibikiPageScaffold] / [HibikiCard] /
/// [HibikiListTile] / [HibikiIconButton] + [HibikiDesignTokens] 字体 token），不
/// 重新打开本地 MD3 决策（受 md3_design_system_static_test 守卫）。
class CrashDumpPage extends StatefulWidget {
  const CrashDumpPage({super.key});

  @override
  State<CrashDumpPage> createState() => _CrashDumpPageState();
}

class _CrashDumpPageState extends State<CrashDumpPage> {
  List<File> _dumps = <File>[];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _dumps = CrashDumpLocator.listCurrentPlatformDumps();
    });
  }

  /// 在系统资源管理器里打开 crashdumps 目录（Windows）。目录解析失败静默返回。
  Future<void> _openFolder() async {
    final Directory? dir = CrashDumpLocator.resolveDumpDirectory(
      isWindows: Platform.isWindows,
      localAppData: Platform.environment['LOCALAPPDATA'],
    );
    if (dir == null) return;
    try {
      // 目录可能尚未创建（从未崩过）：先建再打开，避免 explorer 报路径不存在。
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await Process.run('explorer', <String>[dir.path]);
    } catch (e) {
      debugPrint('[CrashDumpPage] open folder failed: $e');
    }
  }

  /// 分享单个 `.dmp`（系统分享面板）。
  Future<void> _shareDump(File dump) async {
    try {
      await Share.shareXFiles(
        <XFile>[XFile(dump.path, mimeType: 'application/octet-stream')],
        subject: t.crash_dump_share_subject,
      );
    } catch (e) {
      debugPrint('[CrashDumpPage] share dump failed: $e');
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return HibikiPageScaffold(
      title: t.crash_dump_label(n: _dumps.length),
      actions: <Widget>[
        HibikiIconButton(
          icon: Icons.folder_open_outlined,
          tooltip: t.crash_dump_open_folder,
          onTap: _openFolder,
        ),
        HibikiIconButton(
          icon: Icons.refresh,
          tooltip: t.refresh,
          onTap: _refresh,
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 隐私提示（常驻）：.dmp 含进程内存快照。
          Padding(
            padding: const EdgeInsets.all(12),
            child: HibikiCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.privacy_tip_outlined,
                      size: 20, color: cs.onSurfaceVariant),
                  const Space.small(),
                  Expanded(
                    child: Text(
                      t.crash_dump_privacy_notice,
                      style: tokens.type.metadata,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _dumps.isEmpty
                ? Center(
                    child: Text(
                      t.crash_dump_empty,
                      style: tokens.type.listSubtitle,
                    ),
                  )
                : ListView.builder(
                    itemCount: _dumps.length,
                    itemBuilder: (BuildContext context, int index) {
                      final File dump = _dumps[index];
                      final String name = dump.uri.pathSegments.isNotEmpty
                          ? dump.uri.pathSegments.last
                          : dump.path;
                      FileStat? stat;
                      try {
                        stat = dump.statSync();
                      } catch (_) {
                        stat = null;
                      }
                      final String subtitle = stat == null
                          ? ''
                          : '${_formatSize(stat.size)}  ·  ${stat.modified}';
                      return HibikiListTile(
                        selected: true,
                        icon: Icons.bug_report_outlined,
                        title: name,
                        subtitle: subtitle,
                        trailing: HibikiIconButton(
                          icon: Icons.share_outlined,
                          tooltip: t.crash_dump_share,
                          onTap: () => _shareDump(dump),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

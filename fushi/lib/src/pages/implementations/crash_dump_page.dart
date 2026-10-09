import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';

import 'package:fushi/src/utils/misc/crash_dump_locator.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/settings/settings_kit.dart';

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
/// 视觉 chrome 全部走共享 MD3 组件（[FushiPageScaffold] / [FushiCard] /
/// [FushiListTile] / [FushiIconButton] + [FushiDesignTokens] 字体 token），不
/// 重新打开本地 MD3 决策（受 m3e_design_system_static_test 守卫）。
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
      await FushiShare.shareFiles(
        <XFile>[XFile(dump.path, mimeType: 'application/octet-stream')],
        subject: t.crash_dump_share_subject,
      );
    } catch (e) {
      debugPrint('[CrashDumpPage] share dump failed: $e');
    }
  }

  String _formatSize(int bytes) => FushiByteFormat.bytes(bytes);

  @override
  Widget build(BuildContext context) {
    // 设置子页统一壳（settings kit）：浮动页头 + 动作组胶囊，与 schema 详情页一致。
    return SettingsKitScaffold(
      leadingIcon: FushiIcons.warning,
      leadingTone: SettingsIconTone.gray,
      title: t.crash_dump_label(n: _dumps.length),
      actions: <Widget>[
        FushiIconButton(
          icon: FushiIcons.folderOpen,
          tooltip: t.crash_dump_open_folder,
          onTap: _openFolder,
        ),
        FushiIconButton(
          icon: FushiIcons.refresh,
          tooltip: t.refresh,
          onTap: _refresh,
        ),
      ],
      // 正文（隐私提示 + 转储列表）同在一个 ListView 里，顶部内边距吃壳的页头
      // 让位，往下滚时滚到叠放的页头底下。
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            // 隐私提示（常驻）：.dmp 含进程内存快照。作为列表首项随正文滚动，
            // 不再钉在正文顶部（会与浮动页头重叠）。
            // 统一提示块：MD3 中性填充 r12 / Apple tertiaryFill r10，图标单色，
            // 不再拿整张卡片装一行提示（卡片在 Apple 下是内容底板语义）。
            final Widget notice = Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: FushiInlineNotice(
                icon: FushiIcons.shield,
                message: t.crash_dump_privacy_notice,
              ),
            );
            final double top = MediaQuery.paddingOf(context).top;
            if (_dumps.isEmpty) {
              // 空状态走 settings kit 统一空态（M3E 形状图标 + 标题）。
              return ListView(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, top, 12, 12),
                children: <Widget>[
                  notice,
                  SettingsEmptyState(
                    icon: FushiIcons.success,
                    title: t.crash_dump_empty,
                  ),
                ],
              );
            }
            // M3E 分段卡片列表：行首 error 色块形状，行尾分享；首屏错峰进场。
            return FushiEntranceScope(
              child: ListView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, top, 12, 12),
                itemCount: _dumps.length + 1,
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext context,
                  int position,
                ) {
                  if (position == 0) return notice;
                  final int index = position - 1;
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
                  return FushiGroupedListItem(
                    index: index,
                    count: _dumps.length,
                    child: FushiListItem(
                      leading: const FushiListLeadingIcon(
                        FushiIcons.file,
                        shape: FushiLeadingShape.square,
                        tone: FushiCardTone.error,
                      ),
                      title: Text(name),
                      subtitle: subtitle.isEmpty ? null : Text(subtitle),
                      trailing: FushiIconButton(
                        icon: FushiIcons.share,
                        tooltip: t.crash_dump_share,
                        onTap: () => _shareDump(dump),
                      ),
                    ),
                  );
                }),
              ),
            );
          },
    );
  }
}

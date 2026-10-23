/// 「互联下载」独立管理页：只列从已配对设备拉到本机的任务
/// （[InterconnectDownloadManager]），给暂停 / 继续 / 取消（删半成品）/ 清记录。
///
/// 为什么要独立成页（反馈 _sZllpFQWm / BUG-3698）：这些任务此前只出现在「浏览 →
/// 下载」的统一任务列表里，而「浏览」整模块在 iOS 上因商店合规缺席
/// （`StoreRestrictedCapability.downloads` 管的是 torrent / 磁力 / 直链下载中心）。
/// 互联下载不属于受限能力——它只是把用户自己另一台设备上的内容拷到本机——却跟着
/// 下载中心一起没了入口：iPad 上点了「下载远端集」就再也停不下来，重开 app 还会
/// 自动续传。本页**不依赖**浏览模块，也不问任何合规门；入口挂在设置 › 互联、
/// 合集详情页「管理」菜单与远端视频卡的动作面板上，五端一致。
///
/// 列表本体复用下载中心同一个 [DownloadTaskBrowser] 与同一条任务映射
/// （[InterconnectDownloadTasksSection]），动效、按钮、确认框与下载中心一字不差。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/downloads/download_task_browser.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_section.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset;
import 'package:fushi/utils.dart';

class InterconnectDownloadTasksPage extends StatelessWidget {
  const InterconnectDownloadTasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 页头浮在正文上（M3E 悬浮胶囊），[DownloadTaskBrowser] 按库页浮动工具区的约定
    // 经 [FushiFloatingChromeInset] 让位：把脚手架下发的顶部让位转成同一个 inset
    // （与浏览页二级页 `BrowseSubPage` 同一接法）。
    return FushiPageScaffold(
      title: t.interconnect_download_tasks_title,
      body: Builder(
        builder: (BuildContext context) => FushiFloatingChromeInset(
          top: MediaQuery.paddingOf(context).top,
          child: InterconnectDownloadTasksSection(
            tasksBuilder:
                (BuildContext context, List<DownloadTaskEntry> tasks) =>
                    DownloadTaskBrowser(tasks: tasks),
          ),
        ),
      ),
    );
  }
}

/// 打开 [InterconnectDownloadTasksPage]（各入口共用）。
Future<void> openInterconnectDownloadTasksPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            const InterconnectDownloadTasksPage(),
      ),
    );

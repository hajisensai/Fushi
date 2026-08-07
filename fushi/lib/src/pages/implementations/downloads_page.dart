import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_tasks_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/airing_calendar_page.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/download_subscriptions_panel.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/utils.dart';

/// 独立「下载」页（顶层底栏 tab）＝统一下载中心：番剧下载流程 **直接内联**
/// 铺在页面上（搜番 → 选种 → 配字幕 → 推送 + 通用磁力 + 下载任务），任务 tab
/// 同时列出漫画「在线目录」（mokuro.moe）的卷下载队列；页头另有在线目录入口。
/// 第四个顶部页签是「下载设置」（后端/限速/上传/做种/内存）。完成后按内容类型
/// 自动入库（视频→视频库、epub→阅读库，见 AnimeDownloadService；漫画卷→
/// 书架，见 MokuroMoeDownloadQueue）。
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key, this.initialShowSettings = false});

  /// 初始即显示设置面板（「后端未配置」横幅的「去设置」从对话框入口 push
  /// 本页直落配置用）。默认 false = 正常下载流程。
  final bool initialShowSettings;

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  /// 漫画「在线目录」入口（统一下载中心：书/漫画获取入口与 torrent 并列）。
  ///
  /// 书架页与书籍导入框的旧入口已收敛到这里，故本页是
  /// [MangaModule.openOnlineCatalog] 的唯一消费方——目录弹窗的构造统一收在
  /// 漫画模块里，不在页面层直接 new 它。
  Future<void> _openMangaCatalog() async {
    await MangaModule.openOnlineCatalog(
      context: context,
      db: ref.read(appProvider).database,
    );
  }

  /// 放送日历整页入口（TODO-2487）。[tabContext] 必须来自 DefaultTabController
  /// 之下（AppBar actions 里的 Builder），日历页点「订阅中」条目 pop 回来后
  /// 用它把本页 tab 切到订阅。
  void _openAiringCalendar(BuildContext tabContext) {
    final TabController tabController = DefaultTabController.of(tabContext);
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => AiringCalendarPage(
          onOpenSubscriptions: () {
            if (!mounted) return;
            tabController.animateTo(2);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
        length: 4,
        initialIndex: widget.initialShowSettings ? 3 : 0,
        child: Builder(
          builder: (BuildContext tabContext) => Scaffold(
            // BUG-1003：内联下载流程把 apikey/搜番等输入框全放在页面上半部，下载任务折叠区
            // 贴底、中段结果列表是唯一的 Expanded。默认 resizeToAvoidBottomInset:true 时，
            // 手机软键盘弹出会压掉 body 高度、顶掉贴底任务区，使其爬到顶部输入框边上（看似
            // 「下载任务被输入框挤上去」）。关掉 inset 让键盘只覆盖下半部结果/任务区（打字时
            // 本就不看），顶部输入框保持可见、布局不反流。
            resizeToAvoidBottomInset: false,
            appBar: AppBar(
              title: Text(t.nav_downloads),
              bottom: TabBar(
                // BUG-1184：三个 tab 均分宽度时，窄屏 + 大字号下较长的 tab 名
                // （英文 Subscriptions）会被裁。可滚动 tab 条按内容取宽，装不下
                // 就横向滚动而不是裁字。
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: <Widget>[
                  Tab(text: t.download_discover_tab),
                  Tab(text: t.download_tasks_tab),
                  Tab(text: t.download_subscriptions_tab),
                  Tab(text: t.settings),
                ],
              ),
              actions: <Widget>[
                IconButton(
                  tooltip: t.download_airing_calendar_title,
                  icon: const Icon(Icons.calendar_month_outlined),
                  onPressed: () => _openAiringCalendar(tabContext),
                ),
                IconButton(
                  tooltip: t.manga_online_catalog_title,
                  icon: const Icon(Icons.menu_book_outlined),
                  onPressed: _openMangaCatalog,
                ),
              ],
            ),
            // 设置与发现/任务/订阅同属顶部平级页签；不再用右上角齿轮把整页切成
            // 另一种模式，避免页签导航与正文状态互相覆盖。
            body: TabBarView(
              children: <Widget>[
                AnimeDownloadDialog(
                  embedded: true,
                  showTasks: false,
                  onOpenSettings: () =>
                      DefaultTabController.of(tabContext).animateTo(3),
                ),
                // 任务 tab：漫画目录卷下载队列（有任务才占位）+ torrent 任务，
                // 统一下载中心的同屏任务视图。
                Column(
                  children: <Widget>[
                    const MokuroMoeTasksSection(),
                    Expanded(
                      child: AnimeDownloadDialog(
                        embedded: true,
                        tasksOnly: true,
                        showTasks: false,
                        onOpenSettings: () =>
                            DefaultTabController.of(tabContext).animateTo(3),
                      ),
                    ),
                  ],
                ),
                const DownloadSubscriptionsPanel(),
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    // 桌面宽屏限宽 560 居中（对齐全 app 设置面板口径），不再全宽铺开。
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: kTorrentSettingsContentMaxWidth,
                        ),
                        child: const TorrentSettingsSection(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ));
  }
}

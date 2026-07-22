import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';
import 'package:hibiki/src/pages/implementations/torrent_settings_section.dart';
import 'package:hibiki/utils.dart';

/// 独立「下载」页（顶层底栏 tab）：番剧下载流程 **直接内联** 铺在页面上（搜番 →
/// 选种 → 配字幕 → 推送 + 通用磁力 + 下载任务），不再走弹窗按钮。右上角齿轮
/// 切到「下载设置」（后端/限速/上传/做种/内存）。完成后按内容类型自动入库
/// （视频→视频库、epub→阅读库，见 AnimeDownloadService）。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, this.initialShowSettings = false});

  /// 初始即显示设置面板（「后端未配置」横幅的「去设置」从对话框入口 push
  /// 本页直落配置用）。默认 false = 正常下载流程。
  final bool initialShowSettings;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late bool _showSettings = widget.initialShowSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // BUG-1003：内联下载流程把 apikey/搜番等输入框全放在页面上半部，下载任务折叠区
      // 贴底、中段结果列表是唯一的 Expanded。默认 resizeToAvoidBottomInset:true 时，
      // 手机软键盘弹出会压掉 body 高度、顶掉贴底任务区，使其爬到顶部输入框边上（看似
      // 「下载任务被输入框挤上去」）。关掉 inset 让键盘只覆盖下半部结果/任务区（打字时
      // 本就不看），顶部输入框保持可见、布局不反流。
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(_showSettings ? t.download_settings : t.nav_downloads),
        actions: <Widget>[
          IconButton(
            // 齿轮已变 ✕ 时语义是「关闭设置」，tooltip 跟着换，不再答非所问。
            tooltip: _showSettings ? t.dialog_close : t.download_settings,
            icon: Icon(_showSettings ? Icons.close : Icons.settings_outlined),
            onPressed: () => setState(() => _showSettings = !_showSettings),
          ),
        ],
      ),
      // 齿轮切换：设置面板 vs 番剧下载内联流程（后者自带通用磁力 + 任务列表）。
      body: _showSettings
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                // 桌面宽屏限宽 560 居中（对齐全 app 设置面板口径），不再全宽铺开。
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: const TorrentSettingsSection(),
                  ),
                ),
              ],
            )
          : AnimeDownloadDialog(
              embedded: true,
              onOpenSettings: () => setState(() => _showSettings = true),
            ),
    );
  }
}

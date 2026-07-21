import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';
import 'package:hibiki/src/pages/implementations/torrent_settings_section.dart';
import 'package:hibiki/utils.dart';

/// 独立「下载」页（顶层底栏 tab）：番剧下载流程 **直接内联** 铺在页面上（搜番 →
/// 选种 → 配字幕 → 推送 + 通用磁力 + 下载任务），不再走弹窗按钮。右上角齿轮
/// 切到「下载设置」（后端/限速/上传/做种/内存）。完成后按内容类型自动入库
/// （视频→视频库、epub→阅读库，见 AnimeDownloadService）。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  bool _showSettings = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showSettings ? t.download_settings : t.nav_downloads),
        actions: <Widget>[
          IconButton(
            tooltip: t.download_settings,
            icon: Icon(_showSettings ? Icons.close : Icons.settings_outlined),
            onPressed: () => setState(() => _showSettings = !_showSettings),
          ),
        ],
      ),
      // 齿轮切换：设置面板 vs 番剧下载内联流程（后者自带通用磁力 + 任务列表）。
      body: _showSettings
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: const <Widget>[TorrentSettingsSection()],
            )
          : const AnimeDownloadDialog(embedded: true),
    );
  }
}

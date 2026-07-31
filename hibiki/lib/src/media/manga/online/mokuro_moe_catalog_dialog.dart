import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/import/import_dialog_frame.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_catalog_view.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_client.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_download_queue.dart';
import 'package:hibiki/utils.dart';

/// mokuro.moe「在线目录」对话框（O1）：薄壳——外框 chrome 与 footer 动作按钮
/// 在此，浏览/搜索/选卷/入队的全部状态与内容体在 [MokuroMoeCatalogView]
/// （同一内容体也能 embedded 嵌入页面）。
///
/// 对话框只负责浏览与 enqueue：下载在共享队列里后台执行，**关闭对话框不
/// 中断**；进度既在对话框内联面板显示，也与「下载」页任务 tab 同源可见。
/// 书架刷新不依赖关闭回传——书架页直接监听队列的 importedCount 增量。
class MokuroMoeCatalogDialog extends StatefulWidget {
  const MokuroMoeCatalogDialog({
    required this.db,
    this.clientOverride,
    this.queueOverride,
    this.enabledOverride,
    super.key,
  });

  /// 目标数据库（查已在库书目用；下载落库由队列持有的 db 完成）。
  final HibikiDatabase db;

  /// 测试用 client（null = 按偏好 base URL 构造真实 client）。
  final MokuroMoeClient? clientOverride;

  /// 测试用队列（null = 取 AppModel.mokuroMoeDownloadQueue 共享实例）。
  final MokuroMoeDownloadQueue? queueOverride;

  /// Test/embedding source gate. Null reads the live AppModel preference.
  final bool? enabledOverride;

  @override
  State<MokuroMoeCatalogDialog> createState() => _MokuroMoeCatalogDialogState();
}

class _MokuroMoeCatalogDialogState extends State<MokuroMoeCatalogDialog> {
  /// 触达内容体 State（footer 的返回/下载动作经它调用）。
  final GlobalKey<MokuroMoeCatalogViewState> _viewKey =
      GlobalKey<MokuroMoeCatalogViewState>();

  /// 内容体回写的标题/动作快照（初值与 View 初始 browse 阶段一致，首帧即
  /// 可渲出关闭按钮，无需等 View 挂载）。
  final ValueNotifier<MokuroMoeCatalogSnapshot> _snapshot =
      ValueNotifier<MokuroMoeCatalogSnapshot>(const MokuroMoeCatalogSnapshot());

  @override
  void dispose() {
    _snapshot.dispose();
    super.dispose();
  }

  void _close() => Navigator.pop(context);

  @override
  Widget build(BuildContext context) {
    // 外框走统一 ImportDialogFrame（审计 §1-K：与书/有声书/视频导入同一 chrome）；
    // 标题与动作按钮由 View 的快照驱动（阶段/选卷变化时刷新），内容体挂在
    // ValueListenableBuilder 的 child 槽上，不随快照重建。
    return ValueListenableBuilder<MokuroMoeCatalogSnapshot>(
      valueListenable: _snapshot,
      child: MokuroMoeCatalogView(
        key: _viewKey,
        db: widget.db,
        clientOverride: widget.clientOverride,
        queueOverride: widget.queueOverride,
        enabledOverride: widget.enabledOverride,
        embedded: false,
        onClose: _close,
        snapshotNotifier: _snapshot,
      ),
      builder: (BuildContext context, MokuroMoeCatalogSnapshot snapshot,
          Widget? body) {
        return ImportDialogFrame(
          leadingIcon: Icons.cloud_download_outlined,
          title: snapshot.seriesName ?? t.manga_online_catalog_title,
          // BUG-1184：正文原先是死的 560×440。宽度会被对话框约束钳住（无害），但**高度**
          // 440 是硬的——矮窗口 / 手机横屏下超出对话框可用高度就直接溢出。改为不超过屏高
          // 的六成，宽屏行为不变。
          body: SizedBox(
            width: 560,
            height: math.min(440.0, MediaQuery.sizeOf(context).height * 0.6),
            child: body,
          ),
          actions: _buildActions(context, snapshot),
        );
      },
    );
  }

  List<Widget> _buildActions(
      BuildContext context, MokuroMoeCatalogSnapshot snapshot) {
    if (!snapshot.inSeriesStage) {
      return <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: _close,
          child: Text(t.dialog_close),
        ),
      ];
    }
    return <Widget>[
      adaptiveDialogAction(
        context: context,
        onPressed: () => _viewKey.currentState?.backToBrowse(),
        child: Text(t.back),
      ),
      adaptiveDialogAction(
        context: context,
        onPressed: !snapshot.canDownload
            ? null
            : () => _viewKey.currentState?.enqueueSelected(),
        child: Text(t.manga_online_download_selected),
      ),
      adaptiveDialogAction(
        context: context,
        onPressed: _close,
        child: Text(t.dialog_close),
      ),
    ];
  }
}

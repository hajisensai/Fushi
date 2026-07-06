import 'package:flutter/material.dart';

/// TODO-1213：视频加载态覆盖层（有上下文的加载反馈，替代裸 `CircularProgressIndicator`）。
///
/// 用户报「点播放视频流后长时间裸转圈无反馈」，感知卡死。此覆盖层给加载态补上下文：
/// - [title]：正在加载哪个视频（空串则不显示标题）。
/// - 顶部返回入口：加载中随时可退出、不卡死（回调 [onBack]，由页面接到与正常退出
///   同一条路径）。
/// - [phaseText]：当前阶段文案（连接流 / 下载字幕 / 缓冲 / 准备）。
/// - [progress]：字幕下载阶段的确定性进度（0..1）→ 进度条 + 百分比；其它阶段传 null
///   → indeterminate 转圈 + 文案。
///
/// 纯展示、无状态、无副作用（不碰 `controller.load` 时序），便于 widget 测试。
class VideoLoadingOverlay extends StatelessWidget {
  const VideoLoadingOverlay({
    required this.title,
    required this.phaseText,
    required this.onBack,
    this.progress,
    super.key,
  });

  /// 正在加载的视频标题；空串时不渲染标题行。
  final String title;

  /// 当前加载阶段的本地化文案。
  final String phaseText;

  /// 顶部返回按钮回调（加载中退出，走页面正常退出路径）。
  final VoidCallback onBack;

  /// 字幕下载确定性进度（0..1）；null 表示当前阶段无确定性进度（indeterminate）。
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double? p = progress;
    return SafeArea(
      child: Stack(
        children: <Widget>[
          Align(
            alignment: AlignmentDirectional.topStart,
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              color: cs.onSurface,
              onPressed: onBack,
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (title.isNotEmpty) ...<Widget>[
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 20),
                  ],
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(value: p),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    p != null ? '$phaseText  ${(p * 100).round()}%' : phaseText,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

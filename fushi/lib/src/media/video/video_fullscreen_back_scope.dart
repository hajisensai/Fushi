import 'package:flutter/widgets.dart';

/// 视频全屏路由的「返回上一级」接管层（BUG-3449）。
///
/// 窗口模式下「返回上一级」有两条入口：页面键盘通道（焦点在本页子树里时由
/// `_handleVideoKeyboardShortcut` 直接接住）与 `Navigator.maybePop`（焦点不在本页
/// 子树里时 Esc 冒泡到全局导航、手柄 B 兜底、鼠标侧键 app 根兜底、media_kit 自己
/// 的退全屏）。后者靠视频页的 `PopScope` 走逐级退出层级表（BUG-1862）。
///
/// 全屏是推到根 navigator 的**独立路由**，栈顶是它，视频页那份 `PopScope` 根本
/// 轮不到——`maybePop` 直接把全屏路由 pop 掉（media_kit 随之退原生全屏）。于是
/// 只要焦点不在页面子树里，全屏下按 Esc 就**先退全屏**，底部剧集轨 / 字幕列表 /
/// 侧栏 / 查词浮层原样留着（反馈 _oQPV1HPqX）。本层把同一份层级表接到全屏路由上：
///
/// * 还有前台层开着：[dismissTopLayer] 关掉最上面一层，全屏保持；
/// * 一层都没开：[exitFullscreen] 退全屏（与键盘通道最后一级一致）。
///
/// `canPop` 恒为 false：凡经 `maybePop` 来的返回都先过层级表。**显式**退全屏
/// （F 键、全屏按钮、外部导航收尾）由调用方直接 `Navigator.pop` 全屏路由，
/// 不经本层——那是「切换全屏」的语义，不是「返回上一级」，不该被面板吞掉。
class VideoFullscreenBackScope extends StatelessWidget {
  const VideoFullscreenBackScope({
    required this.dismissTopLayer,
    required this.exitFullscreen,
    required this.child,
    super.key,
  });

  /// 关掉最前台的一层并返回 true；一层都没开返回 false。
  final bool Function() dismissTopLayer;

  /// 没有前台层可关时退出全屏（必须真正 pop 全屏路由，而非再 `maybePop`）。
  final VoidCallback exitFullscreen;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        if (dismissTopLayer()) return;
        exitFullscreen();
      },
      child: child,
    );
  }
}

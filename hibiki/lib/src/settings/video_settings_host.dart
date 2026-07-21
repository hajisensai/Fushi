import 'package:flutter/foundation.dart';

/// 视频播放上下文能力槽（阶段 A 骨架）：视频页打开设置时构造并挂到
/// `SettingsContext.video`；全局设置页恒为 null，控制器绑定行以
/// `visible: (ctx) => ctx.video != null` 门控自然隐藏。
///
/// 刻意不 import 具体播放器类型——`VideoPlayerController` 会把 media_kit 拖进
/// settings 依赖图。[controller] 以 [Listenable] 持有（视频页的
/// VideoPlayerController 就是 ChangeNotifier）；视频侧的 schema actions 文件在
/// 使用点还原具体类型。阶段 B 在此补齐控制器绑定行需要的页面状态回调
/// （A/V 延迟、实时倍速预览、着色器应用等）。
class VideoSettingsHost {
  const VideoSettingsHost({required this.controller});

  /// 活播放器控制器（视频页的 VideoPlayerController）；页面尚未完成初始化时可空。
  final Listenable? controller;
}

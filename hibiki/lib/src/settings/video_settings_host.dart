/// 视频播放上下文能力槽（阶段 A 骨架）：视频页打开设置时构造并挂到
/// `SettingsContext.video`；全局设置页恒为 null，控制器绑定行以
/// `visible: (ctx) => ctx.video != null` 门控自然隐藏。
///
/// 刻意不 import 具体播放器类型——`VideoPlayerController` 会把 media_kit 拖进
/// settings 依赖图。所有播放器交互都由子类（`VideoQuickSettingsHost`）以回调
/// 闭包承载（视频页在构造时捕获 controller），本基类只是类型化的存在标记。
class VideoSettingsHost {
  const VideoSettingsHost();
}

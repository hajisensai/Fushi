/// 是否应在启动后预热 WebView 引擎，把冷启动成本提前到用户翻书架时。
///
/// 移动端与桌面端都预热（桌面端调用时机另由调用方保证在首帧后），
/// 低内存模式一律跳过。纯逻辑，便于单测；真正的 HeadlessInAppWebView
/// 调用留在 main.dart（依赖平台无法单测）。
bool shouldPrewarmWebView({
  required bool isMobile,
  required bool isDesktop,
  required bool lowMemory,
}) {
  if (lowMemory) return false;
  return isMobile || isDesktop;
}

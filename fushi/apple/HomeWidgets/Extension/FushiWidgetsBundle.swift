import SwiftUI
import WidgetKit

/// Fushi 小组件扩展入口。组件清单与设计稿编号对应：
/// 1 今日复习 · 2 连续学习 · 3/4 继续 · 5 今日一词 · 6 学习热力图 · 7 接着听 · 8 查词
/// · 9 锁屏三件（复用 1/2/3 的 accessory 布局）· 10 控制中心控件 · A/B 播放 Live Activity
/// · C 转录进度 Live Activity（A/B/C 只在 iOS；macOS 的对应物是主 app 里的菜单栏播放条）。
@main
struct FushiWidgetsBundle: WidgetBundle {
  var body: some Widget {
    FushiSrsWidget()
    FushiStudyWidget()
    FushiContinueWidget()
    FushiWordWidget()
    FushiHeatmapWidget()
    FushiAudiobookWidget()
    FushiLookupWidget()
    #if os(iOS)
      FushiPlaybackLiveActivity()
      FushiTaskLiveActivity()
    #endif
    if #available(iOS 18.0, macOS 26.0, *) {
      FushiLookupControl()
      FushiCameraLookupControl()
      FushiReviewControl()
      FushiResumeListeningControl()
    }
  }
}

import Foundation

#if canImport(ActivityKit) && os(iOS)
  import ActivityKit
#endif

/// 播放活动（有声书 / 音乐）与长任务（设备端转录）的内容。iOS 上装进 ActivityKit 的
/// Live Activity（灵动岛 + 锁屏），macOS 上由菜单栏播放条（`FushiMenuBarActivities`）显示；
/// 两端吃同一份 Dart 推来的 JSON（`HomeWidgetLiveActivities`）。
///
/// 更新全部来自 app 进程本地（iOS `UIBackgroundModes` 已有 `audio`，播放期间进程常驻），
/// 不走推送。进度条用起止时刻由系统自走，Dart 只在「当前句 / 歌词行 / 状态」变化时推。
struct FushiPlaybackContent: Codable, Hashable {
  var title: String
  var subtitle: String
  /// 有声书：当前句原文（音频对齐 cue 的文本，不加任何读音）；音乐：当前歌词行。
  var line: String
  /// 音乐：下一行歌词；有声书为 nil。
  var nextLine: String?
  var isPlaying: Bool
  /// 播放中：本段起止的墙钟时刻（秒，timeIntervalSince1970，已按倍速换算）。
  var startedAt: Double?
  var endsAt: Double?
  /// 暂停时的静态进度 0…1。
  var progress: Double
  var elapsedLabel: String
  var remainingLabel: String
  /// 「第 214 / 560 句」之类的副信息。
  var detail: String?
  var canFavorite: Bool
  var favorited: Bool
  /// true：时间文字也按起止时刻自走（音乐）；false：只有进度条自走，文字用 Dart 的标签
  /// （有声书：进度条走本章、文字是整本，且倍速下墙钟 ≠ 音频时间）。
  var realtimeLabels: Bool?
}

struct FushiPlaybackInfo: Codable, Hashable {
  /// `audiobook` / `music`
  var kind: String
  /// App Group 里的封面相对路径（`covers/…`）；没有 App Group 时退化成符号图标。
  var cover: String?
  var accessibilityPlay: String
  var accessibilityPause: String
  var accessibilityPrevious: String
  var accessibilityNext: String
  var accessibilityFavorite: String
}

struct FushiTaskContent: Codable, Hashable {
  var title: String
  var detail: String
  /// 0…1
  var progress: Double
  var percentLabel: String
  /// 非 nil 时如实显示「已暂停 · 打开 Fushi 继续」之类的说明，进度条变灰。
  var pausedNote: String?
  var finished: Bool
}

struct FushiTaskInfo: Codable, Hashable {
  var kind: String
  var url: String
}

#if canImport(ActivityKit) && os(iOS)
  @available(iOS 16.2, *)
  struct FushiPlaybackAttributes: ActivityAttributes {
    typealias ContentState = FushiPlaybackContent

    var kind: String
    var cover: String?
    var accessibilityPlay: String
    var accessibilityPause: String
    var accessibilityPrevious: String
    var accessibilityNext: String
    var accessibilityFavorite: String

    init(_ info: FushiPlaybackInfo) {
      kind = info.kind
      cover = info.cover
      accessibilityPlay = info.accessibilityPlay
      accessibilityPause = info.accessibilityPause
      accessibilityPrevious = info.accessibilityPrevious
      accessibilityNext = info.accessibilityNext
      accessibilityFavorite = info.accessibilityFavorite
    }
  }

  @available(iOS 16.2, *)
  struct FushiTaskAttributes: ActivityAttributes {
    typealias ContentState = FushiTaskContent

    var kind: String
    var url: String

    init(_ info: FushiTaskInfo) {
      kind = info.kind
      url = info.url
    }
  }
#endif

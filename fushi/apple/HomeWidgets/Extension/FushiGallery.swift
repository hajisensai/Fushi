import Foundation

/// 小组件库 / 控制中心里显示的组件名与说明。它们由系统按**系统语言**渲染（app 还没运行、
/// 拿不到 Dart 的文案），所以走扩展自带的 `Localizable.xcstrings`（17 种语言与 app 对齐）；
/// 组件内的文字则来自快照里 Dart 预翻译的 `labels`，跟随 app 语言。
///
/// 用 `LocalizedStringResource` 而不是 `String`：控制中心控件的 `displayName` 只收它，
/// 而且它由系统在渲染进程里按当时的系统语言解析。
enum FushiGallery {
  static var srsName: LocalizedStringResource {
    LocalizedStringResource("widget.srs.name", defaultValue: "Reviews due")
  }
  static var srsDescription: LocalizedStringResource {
    LocalizedStringResource("widget.srs.description",
      defaultValue: "Cards due now, and how the count grows through the day.")
  }
  static var studyName: LocalizedStringResource {
    LocalizedStringResource("widget.study.name", defaultValue: "Study streak")
  }
  static var studyDescription: LocalizedStringResource {
    LocalizedStringResource("widget.study.description", defaultValue: "Your streak and the last seven days.")
  }
  static var continueName: LocalizedStringResource {
    LocalizedStringResource("widget.continue.name", defaultValue: "Continue")
  }
  static var continueDescription: LocalizedStringResource {
    LocalizedStringResource("widget.continue.description",
      defaultValue: "Pick up books, videos and games where you left off.")
  }
  static var wordName: LocalizedStringResource {
    LocalizedStringResource("widget.word.name", defaultValue: "Word of the day")
  }
  static var wordDescription: LocalizedStringResource {
    LocalizedStringResource("widget.word.description",
      defaultValue: "A card from your own deck, with the sentence you saved it from.")
  }
  static var heatmapName: LocalizedStringResource {
    LocalizedStringResource("widget.heatmap.name", defaultValue: "Study heatmap")
  }
  static var heatmapDescription: LocalizedStringResource {
    LocalizedStringResource("widget.heatmap.description", defaultValue: "Sixteen weeks of study time at a glance.")
  }
  static var audiobookName: LocalizedStringResource {
    LocalizedStringResource("widget.audiobook.name", defaultValue: "Resume listening")
  }
  static var audiobookDescription: LocalizedStringResource {
    LocalizedStringResource("widget.audiobook.description", defaultValue: "Resume your audiobook with one tap.")
  }
  static var lookupName: LocalizedStringResource {
    LocalizedStringResource("widget.lookup.name", defaultValue: "Look up")
  }
  static var lookupDescription: LocalizedStringResource {
    LocalizedStringResource("widget.lookup.description",
      defaultValue: "Look up a word by typing, with the camera, or from the clipboard.")
  }
  static var cameraLookupName: LocalizedStringResource {
    LocalizedStringResource("widget.camera_lookup.name", defaultValue: "Camera lookup")
  }
  /// 还没有快照（从没打开过 app / 没签 App Group）时的占位——此时也拿不到 Dart 的文案。
  static var empty: LocalizedStringResource {
    LocalizedStringResource("widget.empty", defaultValue: "Open Fushi once to fill this in")
  }
  static var reviewControlName: LocalizedStringResource {
    LocalizedStringResource("widget.review_control.name", defaultValue: "Start review")
  }
}

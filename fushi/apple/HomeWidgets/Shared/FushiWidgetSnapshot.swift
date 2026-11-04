import Foundation

#if os(macOS)
  import Security
#endif

/// 主 app 与 FushiWidgets 扩展共用（两个 target 都编译本文件）。
///
/// 数据流：Dart（`fushi/lib/src/platform/home_widgets/`）把快照写成
/// `<App Group>/home_widgets/snapshot.json`，封面缩略图写在同目录 `covers/`，
/// 然后经 `app.fushi/home_widgets` 通道让原生 `WidgetCenter.reloadAllTimelines()`。
/// 所有用户可见文字都由 Dart 按 **app 内语言** 预先排好（与图标快捷菜单同一原则），
/// 扩展这边只负责排版，不做任何文案、换算或推断。
enum FushiAppGroup {
  /// iOS：Info.plist `FushiAppGroup` = `$(FUSHI_APP_GROUP)`（xcconfig 里定义）。
  ///
  /// macOS：以**本进程签进去的** `com.apple.security.application-groups` 为准，Info.plist
  /// 只作兜底。macOS 的组名要带 Team ID 前缀（`<TEAM>.app.fushi.reader`），而 Team ID 只有
  /// CI 的 Developer ID 重签那一步才知道（Xcode 构建时是 ad-hoc），编进 Info.plist 的值会
  /// 与最终签名对不上；app 与扩展各自读自己的签名，两边天然一致。
  static let identifier: String? = {
    #if os(macOS)
      if let task = SecTaskCreateFromSelf(nil),
        let groups = SecTaskCopyValueForEntitlement(
          task, "com.apple.security.application-groups" as CFString, nil) as? [String],
        let first = groups.first(where: { !$0.isEmpty && !$0.contains("$(") })
      {
        return first
      }
    #endif
    let value = Bundle.main.object(forInfoDictionaryKey: "FushiAppGroup") as? String
    guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
    return value
  }()

  /// 没签 App Group（未签名侧载包、描述文件没勾 App Groups）时为 nil：
  /// 小组件显示「打开 Fushi 一次」占位，主 app 不写快照。
  static var containerURL: URL? {
    guard let identifier else { return nil }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: identifier)
  }

  static var widgetsDirectory: URL? {
    containerURL?.appendingPathComponent("home_widgets", isDirectory: true)
  }

  static var snapshotURL: URL? {
    widgetsDirectory?.appendingPathComponent("snapshot.json")
  }

  /// 快照里的相对路径（`covers/abc.jpg`）→ 绝对 URL；越出目录的路径一律拒绝。
  static func resolve(_ relative: String?) -> URL? {
    guard let relative, !relative.isEmpty, !relative.contains(".."),
      let base = widgetsDirectory
    else { return nil }
    return base.appendingPathComponent(relative)
  }
}

/// `snapshot.json` 的形状。字段与 Dart `HomeWidgetSnapshot.toJson` 一一对应，
/// 改字段两边一起改（契约测试 `fushi/test/platform/home_widgets/home_widget_snapshot_test.dart`）。
struct FushiWidgetSnapshot: Codable {
  static let currentVersion = 1

  var v: Int
  /// 生成时刻（毫秒）。
  var at: Double
  var labels: [String: String]
  var srs: Srs?
  var study: Study?
  var `continue`: [ContinueItem]
  var word: Word?
  var audiobook: ContinueItem?

  struct Srs: Codable {
    /// 现在起的逐小时预排：`at` 起显示 `due` / `caption`。第一项就是「现在」。
    var timeline: [SrsEntry]
    var newCount: Int
    var learning: Int
    var review: Int
    var url: String
  }

  struct SrsEntry: Codable {
    var at: Double
    var due: Int
    var caption: String
    /// 锁屏内联用的整句，如「复习 48 张」。
    var inline: String
  }

  struct Study: Codable {
    var today: StudyDay
    /// 过了零点该显示的样子（今天学过 → 连续天数保留、今日清零；没学 → 连续中断）。
    var tomorrow: StudyDay
    /// 下一个本地零点（毫秒），timeline 在这里切到 `tomorrow`。
    var midnightAt: Double
    /// 近 16 周 × 7 天，每格 0…4 档；最后一格是今天（-1 = 今天还没学）。
    var heat: [Int]
    var weekValue: String
    var weekCaption: String
    var cardsValue: String
    var cardsCaption: String
    var url: String
  }

  struct StudyDay: Codable {
    var streak: Int
    var streakCaption: String
    var todayLine: String
    /// 近 7 天强度 0…1；最后一格是今天，-1 = 今天还没学（画虚线框）。
    var last7: [Double]
  }

  struct ContinueItem: Codable, Hashable {
    /// `book` / `manga` / `video` / `audiobook` / `game`（Dart `HomeWidgetItemKind`）
    var kind: String
    var id: String
    var title: String
    var subtitle: String
    /// 0…1；无法计算进度时为 nil（不画进度条）。
    var progress: Double?
    var progressLabel: String?
    var cover: String?
    var url: String
  }

  struct Word: Codable {
    var term: String
    /// 只取卡片自带的读音字段；没有就是 nil，扩展不显示（不做自动注音）。
    var reading: String?
    var meaning: String
    var sentence: String?
    var source: String?
    var url: String
  }

  func label(_ key: String, _ fallback: String) -> String {
    labels[key] ?? fallback
  }

  static func load() -> FushiWidgetSnapshot? {
    guard let url = FushiAppGroup.snapshotURL,
      let data = try? Data(contentsOf: url)
    else { return nil }
    guard let snapshot = try? JSONDecoder().decode(FushiWidgetSnapshot.self, from: data),
      snapshot.v == currentVersion
    else { return nil }
    return snapshot
  }
}

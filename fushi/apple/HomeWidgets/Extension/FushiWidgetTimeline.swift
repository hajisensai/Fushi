import SwiftUI
import WidgetKit

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

struct FushiWidgetEntry: TimelineEntry {
  let date: Date
  let snapshot: FushiWidgetSnapshot?

  /// 该时刻应显示的复习计数：取 `at <= date` 的最后一项。
  var srs: FushiWidgetSnapshot.SrsEntry? {
    guard let timeline = snapshot?.srs?.timeline, !timeline.isEmpty else { return nil }
    let ms = date.timeIntervalSince1970 * 1000
    return timeline.last(where: { $0.at <= ms }) ?? timeline.first
  }

  /// 快照里 Dart 预翻译好的文案（跟随 app 语言）；没有快照时用英文兜底。
  func label(_ key: String, _ fallback: String) -> String {
    snapshot?.label(key, fallback) ?? fallback
  }

  /// 过了快照里记的零点就换成 `tomorrow`。
  var studyDay: FushiWidgetSnapshot.StudyDay? {
    guard let study = snapshot?.study else { return nil }
    return date.timeIntervalSince1970 * 1000 >= study.midnightAt ? study.tomorrow : study.today
  }
}

/// 所有小组件共用一份快照；timeline 节点 = 现在 + 复习逐小时预排 + 下一个零点。
/// 这样不开 app，待复习数也会随卡片到期上涨、连续天数会在零点换日。
struct FushiSnapshotProvider: TimelineProvider {
  func placeholder(in context: Context) -> FushiWidgetEntry {
    FushiWidgetEntry(date: Date(), snapshot: FushiWidgetPreview.snapshot)
  }

  func getSnapshot(in context: Context, completion: @escaping (FushiWidgetEntry) -> Void) {
    let snapshot = FushiWidgetSnapshot.load() ?? (context.isPreview ? FushiWidgetPreview.snapshot : nil)
    completion(FushiWidgetEntry(date: Date(), snapshot: snapshot))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<FushiWidgetEntry>) -> Void) {
    let now = Date()
    let snapshot = FushiWidgetSnapshot.load()
    var dates: Set<Date> = [now]
    let horizon = now.addingTimeInterval(24 * 3600)
    if let timeline = snapshot?.srs?.timeline {
      for item in timeline {
        let date = Date(timeIntervalSince1970: item.at / 1000)
        if date > now && date <= horizon { dates.insert(date) }
      }
    }
    if let midnight = snapshot?.study?.midnightAt {
      let date = Date(timeIntervalSince1970: midnight / 1000)
      if date > now && date <= horizon { dates.insert(date) }
    }
    let entries = dates.sorted().map { FushiWidgetEntry(date: $0, snapshot: snapshot) }
    // 预排用完就让系统再来要一次；数据变化时 app 会主动 reload，不靠这里轮询。
    completion(Timeline(entries: entries, policy: .after(horizon)))
  }
}

/// 小组件库预览 / 首次添加时的示例数据（文字是虚构的示意）。
enum FushiWidgetPreview {
  static var snapshot: FushiWidgetSnapshot {
    let now = Date().timeIntervalSince1970 * 1000
    return FushiWidgetSnapshot(
      v: FushiWidgetSnapshot.currentVersion,
      at: now,
      labels: [:],
      srs: .init(
        timeline: [.init(at: now, due: 48, caption: "≈ 9 min", inline: "48 reviews")],
        newCount: 12, learning: 6, review: 30, url: "fushi://srs/review"),
      study: .init(
        today: .init(
          streak: 17, streakCaption: "day streak", todayLine: "42 min today",
          last7: [0.35, 0.7, 0.5, 0.9, 0.6, 1, -1]),
        tomorrow: .init(
          streak: 17, streakCaption: "day streak", todayLine: "", last7: [0.7, 0.5, 0.9, 0.6, 1, 1, -1]),
        midnightAt: now + 24 * 3600 * 1000,
        heat: (0..<112).map { ($0 * 7 + 3) % 5 },
        weekValue: "5.2 h", weekCaption: "this week", cardsValue: "86", cardsCaption: "cards",
        url: "fushi://stats"),
      continue: [
        .init(
          kind: "book", id: "preview", title: "Book", subtitle: "Chapter 4", progress: 0.63,
          progressLabel: "63%", cover: nil, url: "fushi://"),
      ],
      word: nil,
      audiobook: nil)
  }
}

// MARK: - 共用的小件

enum FushiPalette {
  static let accent = Color(red: 0.357, green: 0.357, blue: 0.839)
  static let study = Color(red: 0.886, green: 0.447, blue: 0.357)
  static let listen = Color(red: 0.184, green: 0.620, blue: 0.431)
  static let newCard = Color(red: 0.357, green: 0.553, blue: 0.937)
}

struct FushiWidgetTag: View {
  let text: String
  var body: some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 3.5)
        .fill(FushiPalette.accent)
        .frame(width: 13, height: 13)
        .widgetAccentable()
      Text(text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

struct FushiCoverImage: View {
  let path: String?
  let kind: String
  var cornerRadius: CGFloat = 8

  var body: some View {
    Group {
      if let image = FushiPlatformImage.load(path) {
        image
          .resizable()
          .widgetAccentedRenderingModeIfAvailable()
          .aspectRatio(contentMode: .fill)
      } else {
        ZStack {
          LinearGradient(
            colors: [FushiPalette.accent.opacity(0.55), FushiPalette.accent.opacity(0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
          Image(systemName: FushiKindSymbol.name(kind))
            .font(.title3)
            .foregroundStyle(.white.opacity(0.9))
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

enum FushiKindSymbol {
  static func name(_ kind: String) -> String {
    switch kind {
    case "video": return "play.rectangle.fill"
    case "manga": return "book.pages.fill"
    case "audiobook": return "headphones"
    case "music": return "music.note"
    case "game": return "gamecontroller.fill"
    default: return "book.closed.fill"
    }
  }
}

struct FushiProgressBar: View {
  let value: Double
  var tint: Color = FushiPalette.accent
  var height: CGFloat = 5

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule()
          .fill(tint)
          .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
          .widgetAccentable()
      }
    }
    .frame(height: height)
  }
}

/// 没有快照（从没打开过 app / 没签 App Group 的侧载包）时的占位。
struct FushiEmptyState: View {
  let snapshot: FushiWidgetSnapshot?
  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "sparkles")
        .font(.title3)
        .foregroundStyle(FushiPalette.accent)
        .widgetAccentable()
      Group {
        if let text = snapshot?.labels["empty"] { Text(text) } else { Text(FushiGallery.empty) }
      }
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
  }
}

/// App Group 里的封面 PNG → SwiftUI Image（iOS UIImage / macOS NSImage）。
enum FushiPlatformImage {
  static func load(_ path: String?) -> Image? {
    guard let url = FushiAppGroup.resolve(path) else { return nil }
    #if os(iOS)
      guard let image = UIImage(contentsOfFile: url.path) else { return nil }
      return Image(uiImage: image)
    #else
      guard let image = NSImage(contentsOf: url) else { return nil }
      return Image(nsImage: image)
    #endif
  }
}

extension View {
  /// 统一底色；`.buttonStyle(.plain)` 让 `Link` 里的文字保持自己的正文 / 次要色（默认样式会把
  /// 整块染成链接强调色）。需要强调样式的按钮（接着听）自己设 `.borderedProminent`，内层优先。
  func fushiWidgetBackground() -> some View {
    buttonStyle(.plain).containerBackground(.fill.tertiary, for: .widget)
  }
}

extension Image {
  @ViewBuilder
  func widgetAccentedRenderingModeIfAvailable() -> some View {
    if #available(iOS 18.0, macOS 15.0, *) {
      widgetAccentedRenderingMode(.desaturated)
    } else {
      self
    }
  }
}

extension String {
  var fushiURL: URL? { URL(string: self) }
}

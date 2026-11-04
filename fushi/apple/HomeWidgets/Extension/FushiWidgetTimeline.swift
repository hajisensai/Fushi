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

  /// 快照里 Dart 预翻译好的文案（跟随 app 语言）；没有快照时用英文兜底。
  func label(_ key: String, _ fallback: String) -> String {
    snapshot?.label(key, fallback) ?? fallback
  }
}

/// 所有小组件共用一份快照（与 Android Glance 同一份 JSON）。数据变化时 app 主动
/// `reloadAllTimelines()`，这里不轮询；只让系统隔几小时再来要一次，读回 app 期间可能已经
/// 写下的新快照。
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
    let entry = FushiWidgetEntry(date: now, snapshot: FushiWidgetSnapshot.load())
    completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(6 * 3600))))
  }
}

/// 小组件库预览 / 首次添加时的示例数据（文字是虚构的示意）。
enum FushiWidgetPreview {
  static var snapshot: FushiWidgetSnapshot {
    let now = Date().timeIntervalSince1970 * 1000
    return FushiWidgetSnapshot(
      day: "2026-01-01",
      generatedAt: now,
      shelf: [
        .init(kind: "book", id: "preview", title: "Book", subtitle: "Author", progress: 0.63, position: "63%")
      ],
      today: .init(time: "42 min", chars: "8,400", streak: 17),
      month: .init(
        minutes: (0..<35).map { ($0 * 37 + 11) % 90 }, time: "21 h", activeDays: 29, firstWeekday: 1),
      streak: .init(current: 17, longest: 40, week: [true, true, false, true, true, true, false]),
      srs: .init(provider: "fushi", due: 48, newCount: 12, learn: 6, review: 30, reviewedToday: 20),
      vocab: [.init(term: "言葉", definition: "word; language")],
      nowPlaying: .init(
        kind: "audiobook", title: "Audiobook", subtitle: "Author", positionMs: 30, durationMs: 100,
        link: FushiLinks.open))
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
  /// App Group 里的相对路径；空串 / nil = 没有封面。
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
        if let text = snapshot?.labels["openToSetUp"], !text.isEmpty {
          Text(text)
        } else {
          Text(FushiGallery.empty)
        }
      }
      .font(.caption)
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
    }
  }
}

/// App Group 里的封面缩略图 → SwiftUI Image（iOS UIImage / macOS NSImage）。
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

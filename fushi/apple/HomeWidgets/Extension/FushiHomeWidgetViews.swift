import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 1 今日复习（小 + 锁屏圆形 / 内联）

struct FushiSrsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.srs", provider: FushiSnapshotProvider()) { entry in
      FushiSrsView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.srsName))
    .description(Text(FushiGallery.srsDescription))
    .supportedFamilies(FushiFamilies.srs)
  }
}

struct FushiSrsView: View {
  @Environment(\.widgetFamily) private var environmentFamily
  let entry: FushiWidgetEntry
  /// 只给离屏渲染校验用（`widgetFamily` 环境值只读）；小组件里恒为 nil。
  var familyOverride: WidgetFamily? = nil
  private var family: WidgetFamily { familyOverride ?? environmentFamily }

  var body: some View {
    if let srs = entry.snapshot?.srs, let now = entry.srs {
      content(srs: srs, now: now).widgetURL(srs.url.fushiURL)
    } else {
      FushiEmptyState(snapshot: entry.snapshot)
    }
  }

  @ViewBuilder
  private func content(srs: FushiWidgetSnapshot.Srs, now: FushiWidgetSnapshot.SrsEntry) -> some View {
    switch family {
    #if os(iOS)
      case .accessoryInline:
        Label(now.inline, systemImage: "rectangle.stack")
      case .accessoryCircular:
        let total = max(srs.newCount + srs.learning + srs.review, 1)
        Gauge(value: Double(min(now.due, total)), in: 0...Double(total)) {
          Image(systemName: "rectangle.stack")
        } currentValueLabel: {
          Text("\(now.due)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    #endif
    default:
      let label = entry.label
      VStack(alignment: .leading, spacing: 0) {
        FushiWidgetTag(text: label("srs_title", "Reviews"))
        Spacer(minLength: 6)
        Text("\(now.due)")
          .font(.system(size: 44, weight: .bold, design: .rounded))
          .foregroundStyle(FushiPalette.accent)
          .widgetAccentable()
          .minimumScaleFactor(0.6)
          .lineLimit(1)
        Text(now.caption)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        FushiSrsSplitBar(newCount: srs.newCount, learning: srs.learning, review: srs.review)
        HStack {
          Text("\(label("srs_new", "New")) \(srs.newCount)")
          Spacer()
          Text("\(label("srs_learning", "Learn")) \(srs.learning)")
          Spacer()
          Text("\(label("srs_review", "Review")) \(srs.review)")
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct FushiSrsSplitBar: View {
  let newCount: Int
  let learning: Int
  let review: Int

  var body: some View {
    GeometryReader { proxy in
      let total = max(newCount + learning + review, 1)
      HStack(spacing: 0) {
        Rectangle().fill(FushiPalette.newCard)
          .frame(width: proxy.size.width * CGFloat(newCount) / CGFloat(total))
        Rectangle().fill(FushiPalette.study)
          .frame(width: proxy.size.width * CGFloat(learning) / CGFloat(total))
        Rectangle().fill(FushiPalette.listen)
      }
      .clipShape(Capsule())
      .widgetAccentable()
    }
    .frame(height: 5)
  }
}

// MARK: - 2 连续学习（小 + 锁屏圆形）

struct FushiStudyWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.study", provider: FushiSnapshotProvider()) { entry in
      FushiStudyView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.studyName))
    .description(Text(FushiGallery.studyDescription))
    .supportedFamilies(FushiFamilies.study)
  }
}

struct FushiStudyView: View {
  @Environment(\.widgetFamily) private var environmentFamily
  let entry: FushiWidgetEntry
  /// 只给离屏渲染校验用（`widgetFamily` 环境值只读）；小组件里恒为 nil。
  var familyOverride: WidgetFamily? = nil
  private var family: WidgetFamily { familyOverride ?? environmentFamily }

  var body: some View {
    if let study = entry.snapshot?.study, let day = entry.studyDay {
      Group {
        #if os(iOS)
          if family == .accessoryCircular {
            ZStack {
              AccessoryWidgetBackground()
              VStack(spacing: 0) {
                Text("\(day.streak)").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(entry.label("streak_unit", "days")).font(.system(size: 9))
              }
            }
          } else {
            small(day: day)
          }
        #else
          small(day: day)
        #endif
      }
      .widgetURL(study.url.fushiURL)
    } else {
      FushiEmptyState(snapshot: entry.snapshot)
    }
  }

  private func small(day: FushiWidgetSnapshot.StudyDay) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      FushiWidgetTag(text: entry.snapshot?.label("study_title", "Study") ?? "Study")
      Spacer(minLength: 4)
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text("\(day.streak)")
          .font(.system(size: 40, weight: .bold, design: .rounded))
          .foregroundStyle(FushiPalette.study)
          .widgetAccentable()
        Text(entry.snapshot?.label("streak_unit", "days") ?? "days")
          .font(.subheadline.weight(.semibold))
      }
      Text(day.streakCaption).font(.caption2).foregroundStyle(.secondary)
      Spacer(minLength: 6)
      HStack(spacing: 4) {
        ForEach(Array(day.last7.enumerated()), id: \.offset) { _, value in
          if value < 0 {
            RoundedRectangle(cornerRadius: 4)
              .strokeBorder(FushiPalette.study, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
              .frame(height: 16)
          } else {
            RoundedRectangle(cornerRadius: 4)
              .fill(FushiPalette.study.opacity(0.15 + 0.85 * value))
              .frame(height: 16)
              .widgetAccentable()
          }
        }
      }
      Text(day.todayLine)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.top, 5)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - 3/4 继续（中 / 大 + 锁屏矩形）

struct FushiContinueWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.continue", provider: FushiSnapshotProvider()) { entry in
      FushiContinueView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.continueName))
    .description(Text(FushiGallery.continueDescription))
    .supportedFamilies(FushiFamilies.continueList)
  }
}

struct FushiContinueView: View {
  @Environment(\.widgetFamily) private var environmentFamily
  let entry: FushiWidgetEntry
  /// 只给离屏渲染校验用（`widgetFamily` 环境值只读）；小组件里恒为 nil。
  var familyOverride: WidgetFamily? = nil
  private var family: WidgetFamily { familyOverride ?? environmentFamily }

  var body: some View {
    let items = entry.snapshot?.continue ?? []
    if let first = items.first {
      switch family {
      #if os(iOS)
        case .accessoryRectangular:
          VStack(alignment: .leading, spacing: 2) {
            Text(first.title).font(.headline).lineLimit(1)
            Text(first.subtitle).font(.caption).lineLimit(1)
            if let progress = first.progress {
              ProgressView(value: progress).tint(.primary)
            }
          }
          .widgetURL(first.url.fushiURL)
      #endif
      case .systemLarge:
        large(items)
      default:
        medium(items)
      }
    } else if entry.snapshot != nil {
      VStack(spacing: 6) {
        Image(systemName: "books.vertical").font(.title2).foregroundStyle(FushiPalette.accent)
        Text(entry.snapshot?.label("continue_empty", "Nothing in progress") ?? "")
          .font(.caption).foregroundStyle(.secondary)
      }
    } else {
      FushiEmptyState(snapshot: nil)
    }
  }

  private var title: String { entry.snapshot?.label("continue_title", "Continue") ?? "Continue" }

  private func medium(_ items: [FushiWidgetSnapshot.ContinueItem]) -> some View {
    let main = items[0]
    let side = Array(items.dropFirst().prefix(2))
    return HStack(spacing: 12) {
      Link(destination: main.url.fushiURL ?? URL(string: "fushi://")!) {
        FushiCoverImage(path: main.cover, kind: main.kind)
          .frame(width: 84)
      }
      VStack(alignment: .leading, spacing: 3) {
        FushiWidgetTag(text: title)
        Link(destination: main.url.fushiURL ?? URL(string: "fushi://")!) {
          VStack(alignment: .leading, spacing: 2) {
            Text(main.title).font(.subheadline.weight(.bold)).lineLimit(1)
            Text(main.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let progress = main.progress {
              FushiProgressBar(value: progress).padding(.top, 3)
            }
          }
        }
        Spacer(minLength: 4)
        HStack(spacing: 8) {
          ForEach(side, id: \.self) { item in
            Link(destination: item.url.fushiURL ?? URL(string: "fushi://")!) {
              HStack(spacing: 6) {
                FushiCoverImage(path: item.cover, kind: item.kind, cornerRadius: 5)
                  .frame(width: item.kind == "video" ? 44 : 24, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                  Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                  Text(item.progressLabel ?? item.subtitle)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }
  }

  private func large(_ items: [FushiWidgetSnapshot.ContinueItem]) -> some View {
    let main = items[0]
    let rest = Array(items.dropFirst().prefix(3))
    return VStack(alignment: .leading, spacing: 8) {
      FushiWidgetTag(text: title)
      Link(destination: main.url.fushiURL ?? URL(string: "fushi://")!) {
        ZStack(alignment: .bottomLeading) {
          FushiCoverImage(path: main.cover, kind: main.kind, cornerRadius: 14)
            .frame(maxWidth: .infinity)
          LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
              Text(main.title).font(.headline).foregroundStyle(.white).lineLimit(1)
              Text(main.subtitle).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            Spacer()
            Image(systemName: "play.fill")
              .font(.callout)
              .foregroundStyle(FushiPalette.accent)
              .frame(width: 36, height: 36)
              .background(Circle().fill(.white.opacity(0.92)))
          }
          .padding(10)
        }
        // 高度钉在整个 ZStack 上：渐变层是贪婪的，只钉封面会把卡片撑高、封面浮在中间。
        .frame(height: 128)
      }
      if let progress = main.progress { FushiProgressBar(value: progress, height: 4) }
      VStack(spacing: 7) {
        ForEach(rest, id: \.self) { item in
          Link(destination: item.url.fushiURL ?? URL(string: "fushi://")!) {
            HStack(spacing: 10) {
              FushiCoverImage(path: item.cover, kind: item.kind, cornerRadius: 5)
                .frame(width: 30, height: 42)
              VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer()
              if let label = item.progressLabel {
                Text(label).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
  }
}

// MARK: - 5 今日一词（中）

struct FushiWordWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.word", provider: FushiSnapshotProvider()) { entry in
      FushiWordView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.wordName))
    .description(Text(FushiGallery.wordDescription))
    .supportedFamilies([.systemMedium])
  }
}

struct FushiWordView: View {
  let entry: FushiWidgetEntry

  var body: some View {
    if let word = entry.snapshot?.word {
      VStack(alignment: .leading, spacing: 2) {
        FushiWidgetTag(text: entry.snapshot?.label("word_title", "Word of the day") ?? "")
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(word.term).font(.system(size: 30, weight: .bold, design: .serif)).lineLimit(1)
            .minimumScaleFactor(0.6)
          // 只显示卡片自带的读音字段；没有就不显示（不做自动注音）。
          if let reading = word.reading, !reading.isEmpty {
            Text(reading).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        .padding(.top, 4)
        Text(word.meaning).font(.footnote).lineLimit(2)
        Spacer(minLength: 2)
        if let sentence = word.sentence {
          Text(word.source.map { "\(sentence) — \($0)" } ?? sentence)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(word.url.fushiURL)
    } else if entry.snapshot != nil {
      VStack(spacing: 6) {
        Image(systemName: "character.book.closed").font(.title2).foregroundStyle(FushiPalette.accent)
        Text(entry.snapshot?.label("word_empty", "Make a card to see it here") ?? "")
          .font(.caption).foregroundStyle(.secondary)
      }
    } else {
      FushiEmptyState(snapshot: nil)
    }
  }
}

// MARK: - 6 学习热力图（中）

struct FushiHeatmapWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.heatmap", provider: FushiSnapshotProvider()) { entry in
      FushiHeatmapView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.heatmapName))
    .description(Text(FushiGallery.heatmapDescription))
    .supportedFamilies([.systemMedium])
  }
}

struct FushiHeatmapView: View {
  let entry: FushiWidgetEntry

  var body: some View {
    if let study = entry.snapshot?.study {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          FushiWidgetTag(text: entry.snapshot?.label("heat_title", "Last 16 weeks") ?? "")
          FushiHeatGrid(cells: study.heat)
        }
        VStack(alignment: .leading) {
          stat(study.weekValue, study.weekCaption)
          Spacer()
          stat(study.cardsValue, study.cardsCaption)
        }
        .frame(width: 76, alignment: .leading)
      }
      .widgetURL(study.url.fushiURL)
    } else {
      FushiEmptyState(snapshot: entry.snapshot)
    }
  }

  private func stat(_ value: String, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value).font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
      Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }
  }
}

struct FushiHeatGrid: View {
  let cells: [Int]

  var body: some View {
    let columns = max((cells.count + 6) / 7, 1)
    GeometryReader { proxy in
      let gap: CGFloat = 3
      let side = min(
        (proxy.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
        (proxy.size.height - gap * 6) / 7)
      HStack(alignment: .top, spacing: gap) {
        ForEach(0..<columns, id: \.self) { column in
          VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
              let index = column * 7 + row
              cell(index < cells.count ? cells[index] : 0).frame(width: side, height: side)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func cell(_ level: Int) -> some View {
    if level < 0 {
      RoundedRectangle(cornerRadius: 2.5)
        .strokeBorder(FushiPalette.study, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
    } else if level == 0 {
      RoundedRectangle(cornerRadius: 2.5).fill(.quaternary)
    } else {
      RoundedRectangle(cornerRadius: 2.5)
        .fill(FushiPalette.study.opacity(0.25 + 0.1875 * Double(min(level, 4))))
        .widgetAccentable()
    }
  }
}

// MARK: - 7 接着听（小，可交互）

struct FushiAudiobookWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.audiobook", provider: FushiSnapshotProvider()) { entry in
      FushiAudiobookView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.audiobookName))
    .description(Text(FushiGallery.audiobookDescription))
    .supportedFamilies([.systemSmall])
  }
}

struct FushiAudiobookView: View {
  let entry: FushiWidgetEntry

  /// iOS：App Intent 在后台直接续播（会话还在时），否则带到前台；macOS 没有后台续播的
  /// 意义（app 在 Dock 里常驻），直接走深链。
  @ViewBuilder
  private func resumeButton(_ book: FushiWidgetSnapshot.ContinueItem) -> some View {
    let label = Label(entry.label("listen_resume", "Resume"), systemImage: "play.fill")
      .font(.caption.weight(.semibold))
    #if os(iOS)
      Button(intent: FushiResumeAudiobookIntent(url: book.url)) { label }
        .buttonStyle(.borderedProminent)
        .tint(FushiPalette.listen)
        .widgetAccentable()
    #else
      Link(destination: URL(string: FushiLinks.resumeListening)!) {
        label
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(Capsule().fill(FushiPalette.listen))
      }
      .widgetAccentable()
    #endif
  }

  var body: some View {
    if let book = entry.snapshot?.audiobook {
      VStack(alignment: .leading, spacing: 0) {
        FushiCoverImage(path: book.cover, kind: "audiobook", cornerRadius: 12)
          .frame(width: 54, height: 54)
        Spacer(minLength: 6)
        Text(book.title).font(.footnote.weight(.bold)).lineLimit(2)
        Text(book.progressLabel ?? book.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 6)
        resumeButton(book)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .widgetURL(book.url.fushiURL)
    } else if entry.snapshot != nil {
      VStack(spacing: 6) {
        Image(systemName: "headphones").font(.title2).foregroundStyle(FushiPalette.listen)
        Text(entry.snapshot?.label("listen_empty", "No audiobook yet") ?? "")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
    } else {
      FushiEmptyState(snapshot: nil)
    }
  }
}

// MARK: - 8 查词入口（小，纯深链）

struct FushiLookupWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "app.fushi.widgets.lookup", provider: FushiSnapshotProvider()) { entry in
      FushiLookupView(entry: entry).fushiWidgetBackground()
    }
    .configurationDisplayName(Text(FushiGallery.lookupName))
    .description(Text(FushiGallery.lookupDescription))
    .supportedFamilies([.systemSmall])
  }
}

struct FushiLookupView: View {
  let entry: FushiWidgetEntry

  private func label(_ key: String, _ fallback: String) -> String {
    entry.snapshot?.label(key, fallback) ?? fallback
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      FushiWidgetTag(text: label("lookup_title", "Look up"))
      Link(destination: URL(string: FushiLinks.lookup)!) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
          Text(label("lookup_hint", "Type or paste")).lineLimit(1)
          Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary))
      }
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        tile(FushiLinks.cameraLookup, "camera", label("lookup_camera", "Camera"))
        tile(FushiLinks.clipboardLookup, "doc.on.clipboard", label("lookup_clipboard", "Clipboard"))
      }
    }
  }

  private func tile(_ link: String, _ symbol: String, _ text: String) -> some View {
    Link(destination: URL(string: link)!) {
      VStack(spacing: 2) {
        Image(systemName: symbol).font(.callout)
        Text(text).font(.system(size: 10)).lineLimit(1)
      }
      .frame(maxWidth: .infinity)
      .frame(height: 42)
      .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary))
    }
  }
}

/// 各组件支持的尺寸：锁屏 accessory 只有 iOS 有。
enum FushiFamilies {
  #if os(iOS)
    static let srs: [WidgetFamily] = [.systemSmall, .accessoryCircular, .accessoryInline]
    static let study: [WidgetFamily] = [.systemSmall, .accessoryCircular]
    static let continueList: [WidgetFamily] = [.systemMedium, .systemLarge, .accessoryRectangular]
  #else
    static let srs: [WidgetFamily] = [.systemSmall]
    static let study: [WidgetFamily] = [.systemSmall]
    static let continueList: [WidgetFamily] = [.systemMedium, .systemLarge]
  #endif
}

/// 与 Dart `HomeWidgetLink` 对齐的深链。
enum FushiLinks {
  static let lookup = "fushi://shortcut/lookup"
  static let cameraLookup = "fushi://widget/camera_lookup"
  static let clipboardLookup = "fushi://widget/clipboard_lookup"
  static let review = "fushi://srs/review"
  static let resumeListening = "fushi://widget/resume_audiobook"
}

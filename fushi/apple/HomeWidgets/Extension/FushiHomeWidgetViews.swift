import AppIntents
import SwiftUI
import WidgetKit

// 所有组件吃同一份快照（Dart `buildWidgetSnapshot()`，与 Android Glance 相同），文案取
// `labels`（键见 Dart `kWidgetLabelKeys`），点按一律走 `fushi://widget/...`（[FushiLinks]）。

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
    if let snapshot = entry.snapshot, let srs = snapshot.srs {
      if srs.enabled && snapshot.moduleEnabled("srs") {
        content(srs: srs).widgetURL(FushiLinks.review.fushiURL)
      } else {
        // 复习去向是 Anki / 没开内置复习：Fushi 这边没有计数（两个 provider 的数永不混）。
        VStack(spacing: 6) {
          Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(FushiPalette.accent)
          Text(entry.label("srsOff", "Reviews are off"))
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .widgetURL(FushiLinks.cardSettings.fushiURL)
      }
    } else {
      FushiEmptyState(snapshot: entry.snapshot)
    }
  }

  @ViewBuilder
  private func content(srs: FushiWidgetSnapshot.Srs) -> some View {
    let label = entry.label
    switch family {
    #if os(iOS)
      case .accessoryInline:
        Label("\(label("srsDue", "Due")) \(srs.due)", systemImage: "rectangle.stack")
      case .accessoryCircular:
        let total = max(srs.due + srs.reviewedToday, 1)
        Gauge(value: Double(min(srs.reviewedToday, total)), in: 0...Double(total)) {
          Image(systemName: "rectangle.stack")
        } currentValueLabel: {
          Text("\(srs.due)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    #endif
    default:
      VStack(alignment: .leading, spacing: 0) {
        FushiWidgetTag(text: label("providerFushi", "Reviews"))
        Spacer(minLength: 6)
        Text("\(srs.due)")
          .font(.system(size: 44, weight: .bold, design: .rounded))
          .foregroundStyle(FushiPalette.accent)
          .widgetAccentable()
          .minimumScaleFactor(0.6)
          .lineLimit(1)
        Text(
          srs.due == 0
            ? label("allCaughtUp", "All caught up")
            : "\(label("reviewedToday", "Reviewed today")) \(srs.reviewedToday)"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Spacer(minLength: 8)
        FushiSrsSplitBar(newCount: srs.newCount, learning: srs.learn, review: srs.review)
        HStack {
          Text("\(label("srsNew", "New")) \(srs.newCount)")
          Spacer()
          Text("\(label("srsLearn", "Learn")) \(srs.learn)")
          Spacer()
          Text("\(label("srsDue", "Review")) \(srs.review)")
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
    if let snapshot = entry.snapshot, let streak = snapshot.streak {
      Group {
        #if os(iOS)
          if family == .accessoryCircular {
            ZStack {
              AccessoryWidgetBackground()
              VStack(spacing: 0) {
                Text("\(streak.current)").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(entry.label("streakDays", "days")).font(.system(size: 9))
              }
            }
          } else {
            small(snapshot: snapshot, streak: streak)
          }
        #else
          small(snapshot: snapshot, streak: streak)
        #endif
      }
      .widgetURL(FushiLinks.stats.fushiURL)
    } else {
      FushiEmptyState(snapshot: entry.snapshot)
    }
  }

  private func small(snapshot: FushiWidgetSnapshot, streak: FushiWidgetSnapshot.Streak) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      FushiWidgetTag(text: entry.label("streak", "Streak"))
      Spacer(minLength: 4)
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        Text("\(streak.current)")
          .font(.system(size: 40, weight: .bold, design: .rounded))
          .foregroundStyle(FushiPalette.study)
          .widgetAccentable()
        Text(entry.label("streakDays", "days"))
          .font(.subheadline.weight(.semibold))
      }
      Text("\(entry.label("longest", "Longest")) \(streak.longest)")
        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 6)
      HStack(spacing: 4) {
        ForEach(Array(streak.week.enumerated()), id: \.offset) { _, active in
          if active {
            RoundedRectangle(cornerRadius: 4)
              .fill(FushiPalette.study)
              .frame(height: 16)
              .widgetAccentable()
          } else {
            RoundedRectangle(cornerRadius: 4)
              .strokeBorder(FushiPalette.study.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
              .frame(height: 16)
          }
        }
      }
      if let today = snapshot.today {
        Text("\(entry.label("today", "Today")) \(today.time)")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .padding(.top, 5)
          .lineLimit(1)
      }
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
    if let snapshot = entry.snapshot {
      if let first = snapshot.shelf.first {
        switch family {
        #if os(iOS)
          case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
              Text(snapshot.displayTitle(first)).font(.headline).lineLimit(1)
              Text(caption(first)).font(.caption).lineLimit(1)
              if first.progress > 0 {
                ProgressView(value: first.progress).tint(.primary)
              }
            }
            .widgetURL(first.link.fushiURL)
        #endif
        case .systemLarge:
          large(snapshot)
        default:
          medium(snapshot)
        }
      } else {
        VStack(spacing: 6) {
          Image(systemName: "books.vertical").font(.title2).foregroundStyle(FushiPalette.accent)
          Text(entry.label("continueEmpty", "Nothing in progress"))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    } else {
      FushiEmptyState(snapshot: nil)
    }
  }

  private var title: String { entry.label("resume", "Continue") }

  /// 副标题行：作者；没有作者时退到进度 / 剩余时间。
  private func caption(_ item: FushiWidgetSnapshot.Media) -> String {
    if !item.subtitle.isEmpty { return item.subtitle }
    return detail(item)
  }

  /// 进度行：「63% · 还需 2 小时」，没有就空串。
  private func detail(_ item: FushiWidgetSnapshot.Media) -> String {
    [item.position, item.remaining].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// 视频封面是横版（16:9），书 / 漫画 / 游戏是竖版（2:3）：布局按主条目的种类分开排，
  /// 封面不再被硬塞进同一个框里裁成碎片。
  private func isLandscape(_ item: FushiWidgetSnapshot.Media) -> Bool { item.kind == "video" }

  private func link(_ item: FushiWidgetSnapshot.Media) -> URL {
    item.link.fushiURL ?? URL(string: FushiLinks.open)!
  }

  private func medium(_ snapshot: FushiWidgetSnapshot) -> some View {
    let main = snapshot.shelf[0]
    let side = Array(snapshot.shelf.dropFirst().prefix(2))
    return HStack(spacing: 12) {
      Link(destination: link(main)) {
        if isLandscape(main) {
          FushiCoverImage(path: main.cover, kind: main.kind, cornerRadius: 10)
            .frame(width: 112, height: 63)
            .frame(maxHeight: .infinity)
        } else {
          FushiCoverImage(path: main.cover, kind: main.kind)
            .aspectRatio(2 / 3, contentMode: .fit)
        }
      }
      VStack(alignment: .leading, spacing: 3) {
        FushiWidgetTag(text: title)
        Link(destination: link(main)) {
          VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.displayTitle(main)).font(.subheadline.weight(.bold))
              .lineLimit(isLandscape(main) ? 2 : 1)
            Text(caption(main)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if main.progress > 0 {
              FushiProgressBar(value: main.progress).padding(.top, 3)
            }
          }
        }
        Spacer(minLength: 4)
        HStack(spacing: 8) {
          ForEach(side, id: \.self) { item in
            Link(destination: link(item)) {
              HStack(spacing: 6) {
                FushiCoverImage(path: item.cover, kind: item.kind, cornerRadius: 5, maxPoint: 64)
                  .frame(width: isLandscape(item) ? 44 : 22, height: isLandscape(item) ? 26 : 32)
                VStack(alignment: .leading, spacing: 0) {
                  Text(snapshot.displayTitle(item)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                  Text(detail(item).isEmpty ? item.subtitle : detail(item))
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

  private func large(_ snapshot: FushiWidgetSnapshot) -> some View {
    let main = snapshot.shelf[0]
    let rest = Array(snapshot.shelf.dropFirst().prefix(3))
    return VStack(alignment: .leading, spacing: 12) {
      Link(destination: link(main)) {
        // 只有一个在读条目时主卡占满整块，不留半屏空白。
        if isLandscape(main) {
          landscapeHero(snapshot, main, height: rest.isEmpty ? 220 : 140)
        } else {
          portraitHero(snapshot, main, height: rest.isEmpty ? 230 : 150)
        }
      }
      // 小屏机型（大号组件只有 ~311pt 高）放不下三行就少放一行，不让主卡被挤出顶部。
      ViewThatFits(in: .vertical) {
        ForEach((0...rest.count).reversed(), id: \.self) { count in
          VStack(spacing: 8) {
            ForEach(rest.prefix(count), id: \.self) { item in
              Link(destination: link(item)) { row(snapshot, item) }
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// 书 / 漫画 / 游戏：竖版封面立在左边，右边标题、进度、继续按钮。
  private func portraitHero(
    _ snapshot: FushiWidgetSnapshot, _ main: FushiWidgetSnapshot.Media, height: CGFloat
  ) -> some View {
    HStack(alignment: .top, spacing: 14) {
      FushiCoverImage(path: main.cover, kind: main.kind, cornerRadius: 10, maxPoint: height)
        .frame(width: height * 2 / 3, height: height)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
      VStack(alignment: .leading, spacing: 4) {
        FushiWidgetTag(text: title)
        Text(snapshot.displayTitle(main))
          .font(.headline)
          .lineLimit(height > 200 ? 4 : 2)
          .padding(.top, 2)
        if !main.subtitle.isEmpty {
          Text(main.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 6)
        progressBlock(main)
        playPill
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: height)
  }

  /// 视频：横版封面整幅铺开，标题压在底部渐变上。
  private func landscapeHero(
    _ snapshot: FushiWidgetSnapshot, _ main: FushiWidgetSnapshot.Media, height: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      FushiWidgetTag(text: title)
      ZStack(alignment: .bottomLeading) {
        FushiCoverImage(path: main.cover, kind: main.kind, cornerRadius: 14, maxPoint: 360)
        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        HStack(alignment: .bottom, spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.displayTitle(main)).font(.headline).foregroundStyle(.white).lineLimit(2)
            Text(caption(main)).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
          }
          Spacer(minLength: 0)
          Image(systemName: "play.fill")
            .font(.callout)
            .foregroundStyle(FushiPalette.accent)
            .frame(width: 36, height: 36)
            .background(Circle().fill(.white.opacity(0.92)))
        }
        .padding(10)
      }
      // 高度钉在整个 ZStack 上：渐变层是贪婪的。
      .frame(height: height)
      if main.progress > 0 { FushiProgressBar(value: main.progress, height: 4) }
    }
  }

  @ViewBuilder
  private func progressBlock(_ item: FushiWidgetSnapshot.Media) -> some View {
    if item.progress > 0 {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(item.position).font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(FushiPalette.accent)
          Spacer(minLength: 4)
          Text(item.remaining).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        FushiProgressBar(value: item.progress, height: 4)
      }
    } else if !item.remaining.isEmpty {
      Text(item.remaining).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }
  }

  private var playPill: some View {
    Label(title, systemImage: "play.fill")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Capsule().fill(FushiPalette.accent))
      .widgetAccentable()
  }

  /// 次要条目：缩略图按种类取比例（视频横、其余竖），统一放在同宽的槽里让标题对齐。
  private func row(_ snapshot: FushiWidgetSnapshot, _ item: FushiWidgetSnapshot.Media) -> some View {
    HStack(spacing: 10) {
      FushiCoverImage(path: item.cover, kind: item.kind, cornerRadius: 5, maxPoint: 72)
        .frame(width: isLandscape(item) ? 52 : 27, height: isLandscape(item) ? 30 : 40)
        .frame(width: 52, height: 40)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(snapshot.displayTitle(item)).font(.footnote.weight(.semibold)).lineLimit(1)
          Spacer(minLength: 0)
          if !item.position.isEmpty {
            Text(item.position).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        if !item.subtitle.isEmpty {
          Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        if item.progress > 0 {
          FushiProgressBar(value: item.progress, height: 3)
        }
      }
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
    if let snapshot = entry.snapshot {
      if let word = snapshot.wordOfTheDay {
        VStack(alignment: .leading, spacing: 2) {
          FushiWidgetTag(text: entry.label("vocabTitle", "Vocabulary"))
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(word.term).font(.system(size: 30, weight: .bold, design: .serif)).lineLimit(1)
              .minimumScaleFactor(0.6)
            // 只显示卡片 / 收藏自带的读音字段；没有就不显示（不做自动注音）。
            if !word.reading.isEmpty && word.reading != word.term {
              Text(word.reading).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          .padding(.top, 4)
          if !snapshot.privacy.hideDefinitions {
            Text(word.definition).font(.footnote).lineLimit(2)
            Spacer(minLength: 2)
            if !word.sentence.isEmpty {
              Text(word.source.isEmpty ? word.sentence : "\(word.sentence) — \(word.source)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          } else {
            Spacer(minLength: 2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(word.link.fushiURL)
      } else {
        VStack(spacing: 6) {
          Image(systemName: "character.book.closed").font(.title2).foregroundStyle(FushiPalette.accent)
          Text(entry.label("noVocab", "Words you save will show up here"))
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
      }
    } else {
      FushiEmptyState(snapshot: nil)
    }
  }
}

// MARK: - 6 学习热力图（中，近 16 周）

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
    if let snapshot = entry.snapshot, let month = snapshot.month {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          // 16 周 × 7 天（Dart 给好固定阈值的档位）；旧快照没有 `heatmap` 时退回 35 天。
          if let heatmap = snapshot.heatmap, !heatmap.levels.isEmpty {
            FushiWidgetTag(text: entry.label("recentHeatmapDays", "Last 112 days"))
            FushiHeatGrid(cells: heatmap.levels, firstWeekday: heatmap.firstWeekday)
          } else {
            FushiWidgetTag(text: entry.label("recentDays", "Last 35 days"))
            FushiHeatGrid(cells: FushiHeatGrid.levels(month.minutes), firstWeekday: month.firstWeekday)
          }
        }
        // 右侧统计与网格同一口径：有 16 周热力图就用它的总时长 / 活跃天数，
        // 旧快照（只有 35 天 `month`）才退回本月口径。
        VStack(alignment: .leading) {
          if let heatmap = snapshot.heatmap, !heatmap.levels.isEmpty {
            stat(heatmap.time, entry.label("recentHeatmapDays", "Last 112 days"))
            Spacer()
            stat("\(heatmap.activeDays)", entry.label("activeDays", "Active days"))
          } else {
            stat(month.time, entry.label("thisMonth", "This month"))
            Spacer()
            stat("\(month.activeDays)", entry.label("activeDays", "Active days"))
          }
        }
        .frame(width: 76, alignment: .leading)
      }
      .widgetURL(FushiLinks.stats.fushiURL)
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

/// 一列一周（周一在上），最旧 → 今天；首列按 `firstWeekday` 留空，对齐星期。最后一格是
/// 今天：还没学时画虚线框（不是「没数据」，是「今天还空着」）。
struct FushiHeatGrid: View {
  /// 每天 0…4 档。
  let cells: [Int]
  /// `cells[0]` 的 ISO 星期（周一 = 1）。
  let firstWeekday: Int

  /// 分钟数 → 0…4 档：0 = 没学；其余按本窗口最大值四等分（只是颜色深浅，不是统计数字）。
  static func levels(_ minutes: [Int]) -> [Int] {
    let peak = minutes.max() ?? 0
    guard peak > 0 else { return minutes.map { _ in 0 } }
    return minutes.map { m in m <= 0 ? 0 : min(4, Int(ceil(Double(m) * 4 / Double(peak)))) }
  }

  var body: some View {
    let lead = max(0, min(6, firstWeekday - 1))
    let total = lead + cells.count
    let columns = max((total + 6) / 7, 1)
    GeometryReader { proxy in
      let gap: CGFloat = 3
      let side = min(
        (proxy.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
        (proxy.size.height - gap * 6) / 7)
      HStack(alignment: .top, spacing: gap) {
        ForEach(0..<columns, id: \.self) { column in
          VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
              let index = column * 7 + row - lead
              cell(index >= 0 && index < cells.count ? cells[index] : nil, isToday: index == cells.count - 1)
                .frame(width: side, height: side)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func cell(_ level: Int?, isToday: Bool) -> some View {
    if let level {
      if level == 0 && isToday {
        RoundedRectangle(cornerRadius: 2.5)
          .strokeBorder(FushiPalette.study.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
      } else if level == 0 {
        RoundedRectangle(cornerRadius: 2.5).fill(.quaternary)
      } else {
        RoundedRectangle(cornerRadius: 2.5)
          .fill(FushiPalette.study.opacity(0.25 + 0.1875 * Double(min(level, 4))))
          .widgetAccentable()
      }
    } else {
      Color.clear
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

/// 快照的 `nowPlaying`：正在 / 最近播放的有声书或音乐。
struct FushiAudiobookView: View {
  let entry: FushiWidgetEntry

  /// iOS：App Intent 在后台直接续播（会话还在时），否则带到前台打开 `link`；macOS 没有后台
  /// 续播的意义（app 在 Dock 里常驻），直接走深链。
  @ViewBuilder
  private func resumeButton(_ item: FushiWidgetSnapshot.NowPlaying) -> some View {
    let label = Label(entry.label("play", "Play"), systemImage: "play.fill")
      .font(.caption.weight(.semibold))
    #if os(iOS)
      Button(intent: FushiResumeAudiobookIntent(kind: item.kind, url: item.link)) { label }
        .buttonStyle(.borderedProminent)
        .tint(FushiPalette.listen)
        .widgetAccentable()
    #else
      Link(destination: item.link.fushiURL ?? URL(string: FushiLinks.open)!) {
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
    if let snapshot = entry.snapshot {
      if let item = snapshot.nowPlaying {
        VStack(alignment: .leading, spacing: 0) {
          FushiCoverImage(path: item.cover, kind: item.kind, cornerRadius: 12)
            .frame(width: 54, height: 54)
          Spacer(minLength: 6)
          Text(snapshot.privacy.hideTitles ? entry.label("kind_\(item.kind)", item.kind) : item.title)
            .font(.footnote.weight(.bold)).lineLimit(2)
          if item.progress > 0 {
            FushiProgressBar(value: item.progress, tint: FushiPalette.listen, height: 3).padding(.vertical, 3)
          } else {
            Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 6)
          if item.playing {
            Label(entry.label("nowPlaying", "Now playing"), systemImage: "waveform")
              .font(.caption.weight(.semibold))
              .foregroundStyle(FushiPalette.listen)
          } else {
            resumeButton(item)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(item.link.fushiURL)
      } else {
        VStack(spacing: 6) {
          Image(systemName: "headphones").font(.title2).foregroundStyle(FushiPalette.listen)
          Text(entry.label("nothingPlaying", "Nothing playing"))
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      FushiWidgetTag(text: entry.label("lookUp", "Look up"))
      Link(destination: URL(string: FushiLinks.lookup)!) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
          Text(entry.label("lookupHint", "Type or paste")).lineLimit(1)
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
        tile(FushiLinks.cameraLookup, "camera", entry.label("lookupCamera", "Camera"))
        tile(FushiLinks.clipboardLookup, "doc.on.clipboard", entry.label("lookupClipboard", "Clipboard"))
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

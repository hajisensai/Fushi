#if os(iOS)
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - A/B 有声书 · 音乐 Live Activity

struct FushiPlaybackLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FushiPlaybackAttributes.self) { context in
      FushiPlaybackLockView(context: context)
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.62))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let accent = FushiPlaybackStyle.accent(context.attributes.kind)
      return DynamicIsland {
        // 展开态总高上限约 160pt：顶部一行（封面 44）+ 底部（原文一行 / 进度 / 紧凑控件）
        // 要压在里面，否则系统直接把控件行截掉。锁屏视图空间充裕，保留两行原文与大按钮。
        DynamicIslandExpandedRegion(.leading) {
          FushiActivityCover(path: context.attributes.cover, kind: context.attributes.kind, size: 44)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          FushiEqualizer(playing: context.state.isPlaying, tint: accent)
            .frame(width: 24, height: 18)
            .padding(.trailing, 6)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 1) {
            Text(context.state.title).font(.subheadline.weight(.bold)).lineLimit(1)
            Text(context.state.detail ?? context.state.subtitle)
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 4) {
            FushiPlaybackLines(state: context.state, kind: context.attributes.kind, accent: accent, compact: true)
            FushiPlaybackProgress(state: context.state, accent: accent)
            if context.attributes.kind == "audiobook" {
              FushiPlaybackControls(context: context, compact: true)
            }
          }
          .padding(.horizontal, 4)
        }
      } compactLeading: {
        FushiActivityCover(path: context.attributes.cover, kind: context.attributes.kind, size: 24)
      } compactTrailing: {
        if context.attributes.kind == "music" && !context.state.line.isEmpty {
          Text(context.state.line)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(1)
            .frame(maxWidth: 64)
        } else {
          FushiEqualizer(playing: context.state.isPlaying, tint: accent).frame(width: 18, height: 14)
        }
      } minimal: {
        FushiActivityCover(path: context.attributes.cover, kind: context.attributes.kind, size: 24)
      }
      .keylineTint(accent)
    }
  }
}

enum FushiPlaybackStyle {
  static let audiobook = Color(red: 0.494, green: 0.878, blue: 0.659)
  static let music = Color(red: 1.0, green: 0.702, blue: 0.757)
  static let task = Color(red: 1.0, green: 0.812, blue: 0.361)

  static func accent(_ kind: String) -> Color { kind == "music" ? music : audiobook }
}

struct FushiPlaybackLockView: View {
  let context: ActivityViewContext<FushiPlaybackAttributes>

  var body: some View {
    let accent = FushiPlaybackStyle.accent(context.attributes.kind)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        FushiActivityCover(path: context.attributes.cover, kind: context.attributes.kind, size: 46)
        VStack(alignment: .leading, spacing: 1) {
          Text(context.state.title).font(.subheadline.weight(.bold)).lineLimit(1)
          Text(context.state.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        Spacer()
        FushiEqualizer(playing: context.state.isPlaying, tint: accent).frame(width: 22, height: 16)
      }
      FushiPlaybackLines(state: context.state, kind: context.attributes.kind, accent: accent)
      FushiPlaybackProgress(state: context.state, accent: accent)
      if context.attributes.kind == "audiobook" {
        FushiPlaybackControls(context: context)
      }
    }
    .foregroundStyle(.white)
  }
}

struct FushiPlaybackLines: View {
  let state: FushiPlaybackAttributes.ContentState
  let kind: String
  let accent: Color
  /// 灵动岛展开态：原文压成一行、音乐不显示下一行。
  var compact: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if kind == "audiobook" {
        // 原文照搬音频对齐 cue 的文本：不加读音、不做任何改写。
        Text(state.line)
          .font(.system(size: compact ? 15 : 16, weight: .semibold, design: .serif))
          .foregroundStyle(accent)
          .lineLimit(compact ? 1 : 2)
      } else {
        Text(state.line).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(1)
        if !compact, let next = state.nextLine, !next.isEmpty {
          Text(next).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct FushiPlaybackProgress: View {
  let state: FushiPlaybackAttributes.ContentState
  let accent: Color

  var body: some View {
    HStack(spacing: 8) {
      if state.isPlaying, let start = state.startedAt, let end = state.endsAt, end > start {
        let range = Date(timeIntervalSince1970: start)...Date(timeIntervalSince1970: end)
        let live = state.realtimeLabels == true
        Group {
          if live { Text(timerInterval: range, countsDown: false) } else { Text(state.elapsedLabel) }
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
        ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
          .tint(accent)
        Group {
          if live { Text(timerInterval: range, countsDown: true) } else { Text(state.remainingLabel) }
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 52, alignment: .trailing)
      } else {
        Text(state.elapsedLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        ProgressView(value: min(max(state.progress, 0), 1)).tint(accent)
        Text(state.remainingLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
  }
}

struct FushiPlaybackControls: View {
  let context: ActivityViewContext<FushiPlaybackAttributes>
  /// 灵动岛展开态用矮一号的按钮（总高受限）。
  var compact: Bool = false

  private var playSide: CGFloat { compact ? 34 : 44 }
  private var sideSide: CGFloat { compact ? 30 : 36 }

  var body: some View {
    HStack(spacing: 30) {
      Spacer(minLength: 0)
      control(.previous, "backward.end.fill", context.attributes.accessibilityPrevious)
      Button(intent: FushiPlaybackControlIntent(action: .toggle)) {
        Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
          .font(compact ? .body : .title3)
          .frame(width: playSide, height: playSide)
          .background(Circle().fill(.white.opacity(0.16)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        context.state.isPlaying ? context.attributes.accessibilityPause : context.attributes.accessibilityPlay)
      control(.next, "forward.end.fill", context.attributes.accessibilityNext)
      if context.state.canFavorite {
        control(.favorite, context.state.favorited ? "star.fill" : "star", context.attributes.accessibilityFavorite)
      }
      Spacer(minLength: 0)
    }
  }

  private func control(_ action: FushiPlaybackAction, _ symbol: String, _ label: String) -> some View {
    Button(intent: FushiPlaybackControlIntent(action: action)) {
      Image(systemName: symbol).font(compact ? .callout : .body).frame(width: sideSide, height: sideSide)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}

struct FushiActivityCover: View {
  let path: String?
  let kind: String
  let size: CGFloat

  var body: some View {
    Group {
      // 按显示尺寸降采样：Live Activity 的图不能大于所在呈现区域，原图塞进紧凑位只会
      // 画成一块灰占位（展开态区域大才侥幸显示）。
      if let image = FushiPlatformImage.load(path, maxPoint: size) {
        Color.clear.overlay { image.resizable().aspectRatio(contentMode: .fill) }
      } else {
        ZStack {
          FushiPlaybackStyle.accent(kind).opacity(0.35)
          Image(systemName: FushiKindSymbol.name(kind))
            .font(.system(size: size * 0.45))
            .foregroundStyle(.white)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: kind == "music" ? size / 2 : size * 0.24, style: .continuous))
  }
}

/// 播放中显示的四条声波；暂停时压平。Live Activity 里不能跑自定义动画，
/// 所以是静态造型，状态由 `isPlaying` 区分。
struct FushiEqualizer: View {
  let playing: Bool
  let tint: Color

  var body: some View {
    GeometryReader { proxy in
      let heights: [CGFloat] = playing ? [0.4, 1, 0.6, 0.85] : [0.2, 0.2, 0.2, 0.2]
      HStack(alignment: .center, spacing: proxy.size.width * 0.12) {
        ForEach(0..<4, id: \.self) { index in
          Capsule()
            .fill(tint)
            .frame(height: proxy.size.height * heights[index])
        }
      }
      .frame(maxHeight: .infinity)
    }
  }
}

// MARK: - C 转录进度 Live Activity

struct FushiTaskLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: FushiTaskAttributes.self) { context in
      FushiTaskLockView(state: context.state)
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.62))
        .activitySystemActionForegroundColor(.white)
        .widgetURL(URL(string: context.attributes.url))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "waveform.badge.magnifyingglass")
            .font(.title2)
            .foregroundStyle(FushiPlaybackStyle.task)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.percentLabel)
            .font(.title2.weight(.bold).monospacedDigit())
            .foregroundStyle(FushiPlaybackStyle.task)
            .padding(.trailing, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.title).font(.subheadline.weight(.bold)).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(context.state.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ProgressView(value: context.state.progress)
              .tint(context.state.pausedNote == nil ? FushiPlaybackStyle.task : .gray)
            if let note = context.state.pausedNote {
              Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          .padding(.horizontal, 4)
        }
      } compactLeading: {
        Image(systemName: "waveform").foregroundStyle(FushiPlaybackStyle.task)
      } compactTrailing: {
        FushiProgressRing(progress: context.state.progress, paused: context.state.pausedNote != nil)
          .frame(width: 18, height: 18)
      } minimal: {
        FushiProgressRing(progress: context.state.progress, paused: context.state.pausedNote != nil)
          .frame(width: 18, height: 18)
      }
      .widgetURL(URL(string: context.attributes.url))
      .keylineTint(FushiPlaybackStyle.task)
    }
  }
}

struct FushiTaskLockView: View {
  let state: FushiTaskAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: state.finished ? "checkmark.circle.fill" : "waveform.badge.magnifyingglass")
          .foregroundStyle(FushiPlaybackStyle.task)
        Text(state.title).font(.subheadline.weight(.bold)).lineLimit(1)
        Spacer()
        Text(state.percentLabel).font(.title3.weight(.bold).monospacedDigit())
          .foregroundStyle(FushiPlaybackStyle.task)
      }
      Text(state.detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
      ProgressView(value: state.progress).tint(state.pausedNote == nil ? FushiPlaybackStyle.task : .gray)
      if let note = state.pausedNote {
        Text(note).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
      }
    }
    .foregroundStyle(.white)
  }
}

struct FushiProgressRing: View {
  let progress: Double
  let paused: Bool

  var body: some View {
    ZStack {
      Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
      Circle()
        .trim(from: 0, to: min(max(progress, 0), 1))
        .stroke(paused ? Color.gray : FushiPlaybackStyle.task, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
  }
}
#endif

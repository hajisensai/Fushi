#if os(macOS)
  import AppKit
  import SwiftUI

  /// macOS 上 Live Activity 的对应物：播放有声书 / 音乐或跑设备端转录时，菜单栏出现一个
  /// 状态项（图标 + 当前句 / 歌词行的短截），点开是一张卡片（封面、标题、当前句、下一行、
  /// 自走进度条）加 上一句 / 播放暂停 / 下一句 / 收藏这句 / 打开 Fushi。
  ///
  /// 数据与 iOS 的灵动岛同一份（[FushiPlaybackContent] / [FushiTaskContent]），由
  /// [FushiHomeWidgets] 转进来；按钮把动作原样交回 Dart（`playback` + toggle/previous/next/favorite），
  /// 与 Live Activity 上的 [FushiPlaybackControlIntent] 走同一个 Dart 入口。
  final class FushiMenuBarActivities: NSObject, NSMenuDelegate {
    private struct Playback {
      let id: String
      let info: FushiPlaybackInfo
      var state: FushiPlaybackContent
    }

    private struct TaskItem {
      let id: String
      let info: FushiTaskInfo
      var state: FushiTaskContent
    }

    private let onAction: (String) -> Void
    private let onOpen: (String) -> Void

    private var playback: Playback?
    private var task: TaskItem?
    private var statusItem: NSStatusItem?
    private var pendingEnds: [String: DispatchWorkItem] = [:]
    private var menuOpen = false

    /// 状态项标题最多显示的字符数；整句在卡片里。
    private static let titleLimit = 24

    init(onAction: @escaping (String) -> Void, onOpen: @escaping (String) -> Void) {
      self.onAction = onAction
      self.onOpen = onOpen
    }

    // MARK: 来自 FushiHomeWidgets

    func startPlayback(info: FushiPlaybackInfo, state: FushiPlaybackContent) -> String {
      let id = "menubar-playback-\(UUID().uuidString)"
      playback = Playback(id: id, info: info, state: state)
      refresh()
      return id
    }

    func updatePlayback(id: String, state: FushiPlaybackContent) {
      guard playback?.id == id else { return }
      playback?.state = state
      refresh()
    }

    func startTask(info: FushiTaskInfo, state: FushiTaskContent) -> String {
      let id = "menubar-task-\(UUID().uuidString)"
      task = TaskItem(id: id, info: info, state: state)
      refresh()
      return id
    }

    func updateTask(id: String, state: FushiTaskContent) {
      guard task?.id == id else { return }
      task?.state = state
      refresh()
    }

    func end(id: String, after linger: Double) {
      pendingEnds.removeValue(forKey: id)?.cancel()
      guard linger > 0 else {
        remove(id: id)
        return
      }
      let work = DispatchWorkItem { [weak self] in
        self?.pendingEnds.removeValue(forKey: id)
        self?.remove(id: id)
      }
      pendingEnds[id] = work
      DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    func endAll() {
      pendingEnds.values.forEach { $0.cancel() }
      pendingEnds.removeAll()
      playback = nil
      task = nil
      refresh()
    }

    private func remove(id: String) {
      if playback?.id == id { playback = nil }
      if task?.id == id { task = nil }
      refresh()
    }

    // MARK: 状态项

    private func refresh() {
      guard playback != nil || task != nil else {
        if let statusItem {
          NSStatusBar.system.removeStatusItem(statusItem)
          self.statusItem = nil
        }
        return
      }
      let item = statusItem ?? makeStatusItem()
      statusItem = item
      updateButton(item.button)
      // 菜单开着时不重建（会把用户正在指的那一项闪掉）；卡片里的进度条自己走，
      // 文字变化等下次打开再取。
      if !menuOpen {
        item.menu = buildMenu()
      }
    }

    private func makeStatusItem() -> NSStatusItem {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.imagePosition = .imageLeading
      item.button?.lineBreakMode = .byTruncatingTail
      return item
    }

    private func updateButton(_ button: NSStatusBarButton?) {
      guard let button else { return }
      if let playback {
        let symbol =
          playback.state.isPlaying
          ? (playback.info.kind == "music" ? "music.note" : "waveform")
          : "pause.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.title = " " + Self.shorten(playback.state.line, fallback: playback.state.title)
        button.toolTip = [playback.state.title, playback.state.line]
          .filter { !$0.isEmpty }.joined(separator: "\n")
      } else if let task {
        button.image = NSImage(
          systemSymbolName: task.state.finished ? "checkmark.circle" : "waveform.badge.mic",
          accessibilityDescription: nil)
        button.title = " " + task.state.percentLabel
        button.toolTip = [task.state.title, task.state.detail].joined(separator: "\n")
      }
      button.image?.isTemplate = true
    }

    private static func shorten(_ text: String, fallback: String) -> String {
      let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let value = source.isEmpty ? fallback : source
      guard value.count > titleLimit else { return value }
      return String(value.prefix(titleLimit - 1)) + "…"
    }

    // MARK: 菜单

    private func buildMenu() -> NSMenu {
      let menu = NSMenu()
      menu.delegate = self
      menu.autoenablesItems = false
      if let playback {
        menu.addItem(hosted(FushiMenuPlaybackCard(info: playback.info, state: playback.state)))
        menu.addItem(.separator())
        menu.addItem(
          actionItem(
            playback.state.isPlaying
              ? playback.info.accessibilityPause : playback.info.accessibilityPlay,
            symbol: playback.state.isPlaying ? "pause.fill" : "play.fill",
            action: "toggle", key: " "))
        menu.addItem(
          actionItem(
            playback.info.accessibilityPrevious, symbol: "backward.fill", action: "previous",
            key: String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        menu.addItem(
          actionItem(
            playback.info.accessibilityNext, symbol: "forward.fill", action: "next",
            key: String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        if playback.state.canFavorite {
          let favorite = actionItem(
            playback.info.accessibilityFavorite,
            symbol: playback.state.favorited ? "star.fill" : "star", action: "favorite", key: "")
          favorite.state = playback.state.favorited ? .on : .off
          menu.addItem(favorite)
        }
      }
      if let task {
        if playback != nil { menu.addItem(.separator()) }
        let card = hosted(FushiMenuTaskCard(state: task.state))
        menu.addItem(card)
        let open = NSMenuItem(
          title: task.state.title, action: #selector(openTask(_:)), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        open.representedObject = task.info.url
        menu.addItem(open)
      }
      menu.addItem(.separator())
      let openApp = NSMenuItem(
        title: "Fushi", action: #selector(activateApp(_:)), keyEquivalent: "")
      openApp.target = self
      openApp.image = NSApp.applicationIconImage.map { icon in
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
      }
      menu.addItem(openApp)
      return menu
    }

    private func hosted<V: View>(_ view: V) -> NSMenuItem {
      let host = NSHostingView(rootView: view)
      host.frame.size = host.fittingSize
      let item = NSMenuItem()
      item.view = host
      return item
    }

    private func actionItem(_ title: String, symbol: String, action: String, key: String)
      -> NSMenuItem
    {
      let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: key)
      item.keyEquivalentModifierMask = []
      item.target = self
      item.representedObject = action
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? String else { return }
      onAction(action)
    }

    @objc private func openTask(_ sender: NSMenuItem) {
      guard let url = sender.representedObject as? String else { return }
      onOpen(url)
    }

    @objc private func activateApp(_ sender: NSMenuItem) {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }

    func menuDidClose(_ menu: NSMenu) {
      menuOpen = false
      // 开着时攒下的变化补上。
      statusItem?.menu = buildMenu()
    }
  }

  // MARK: 卡片

  struct FushiMenuPlaybackCard: View {
    let info: FushiPlaybackInfo
    let state: FushiPlaybackContent

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          cover
          VStack(alignment: .leading, spacing: 2) {
            Text(state.title).font(.headline).lineLimit(1)
            Text(state.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        if !state.line.isEmpty {
          Text(state.line)
            .font(.system(size: 15, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(3)
        }
        if let next = state.nextLine, !next.isEmpty {
          Text(next).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        progress
        if let detail = state.detail, !detail.isEmpty {
          Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder private var cover: some View {
      if let path = info.cover, let url = FushiAppGroup.resolve(path),
        let image = NSImage(contentsOf: url)
      {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
          .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
      } else {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
          .frame(width: 40, height: 40)
          .overlay(
            Image(systemName: info.kind == "music" ? "music.note" : "headphones")
              .foregroundStyle(.secondary))
      }
    }

    /// 播放中按起止时刻自走（已按倍速换算成墙钟），暂停时静态。时间文字一律用 Dart 给的
    /// 标签：倍速 ≠ 1 时墙钟计时与音频时间对不上。
    @ViewBuilder private var progress: some View {
      VStack(spacing: 3) {
        if state.isPlaying, let start = state.startedAt, let end = state.endsAt, end > start {
          ProgressView(
            timerInterval: Date(timeIntervalSince1970: start)...Date(timeIntervalSince1970: end),
            countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
        } else {
          ProgressView(value: min(max(state.progress, 0), 1))
        }
        HStack {
          Text(state.elapsedLabel)
          Spacer()
          Text(state.remainingLabel)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      .progressViewStyle(.linear)
    }
  }

  struct FushiMenuTaskCard: View {
    let state: FushiTaskContent

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Image(systemName: state.finished ? "checkmark.circle.fill" : "waveform.badge.mic")
            .foregroundStyle(state.finished ? .green : .accentColor)
          Text(state.title).font(.headline).lineLimit(1)
          Spacer(minLength: 0)
          Text(state.percentLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        ProgressView(value: min(max(state.progress, 0), 1))
          .progressViewStyle(.linear)
          .tint(state.pausedNote == nil ? .accentColor : .gray)
        Text(state.pausedNote ?? state.detail)
          .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(width: 300, alignment: .leading)
    }
  }
#endif

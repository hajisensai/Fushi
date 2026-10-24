import Cocoa
import CoreText
import FlutterMacOS

// macOS 悬浮字幕 / 桌面歌词（有声书悬浮字幕 + 音乐桌面歌词共用一个窗口）。
//
// 与 windows/runner/floating_lyric_window.cpp（hook 富文本模式 + kAudiobook 槽表）、
// Android FloatingLyricService 同一条 `app.fushi.reader/floating_lyric` 通道契约
// （fushi/lib/src/media/audiobook/floating_lyric_channel.dart）。分工同 Windows：
// Dart 持有文本 / 样式 / 播放态 / 窗口矩形持久化，这里只画字、做命中、拖动 / 缩放，
// 并把「点了哪个字（带字的屏幕矩形）/ 点了哪颗按钮 / 窗口挪到哪」报回 Dart。
//
// 窗口：
// - 正文窗：无边框 NSPanel `.nonactivatingPanel` + canBecomeKey/Main = false，视图
//   acceptsFirstMouse —— 点字 / 拖动都不激活 Fushi（不抢前台）。层级 `.statusBar`
//   （置顶）/ `.normal`（取消置顶）；`canJoinAllSpaces + fullScreenAuxiliary`，切桌面、
//   别的 app 全屏时照样浮在上面。
// - 工具条窗：独立的小药丸 NSPanel（正文窗的 child window，跟着正文窗走），槽表与
//   Windows kAudiobookSlotActions 同序：上一句 / 播放暂停 / 下一句 / 锁定 / 置顶 / 关闭。
//   光标进入正文窗 ∪ 工具条（外扩 24pt）才显示（Windows toolbar_auto_hide_ 默认开），
//   穿透态恒显——它是穿透态下唯一能点的东西（BUG-951 的逃生口语义）。
//
// 穿透（passThrough）：正文窗 `ignoresMouseEvents = true`，工具条窗照常可点。与 Windows
// 的差异：Windows 靠逐像素 alpha 让字形像素仍可点字查词，AppKit 的 ignoresMouseEvents
// 是整窗级的，所以 macOS 穿透态下点字查词不可用，只剩 Shift-悬停查词（轮询全局光标）。
//
// 位置锁定（lock）：禁拖动 / 禁缩放，点字查词与播放控制照常（与 Android / Windows 同）。
//
// 坐标：
// - 内部几何一律走 AppKit 全局 pt（左下原点）。
// - 点词回传的 wordRect 是「屏幕逻辑 px」= 左上原点的全局 pt（以主屏高度翻转 y，与
//   GlobalLookupOverlay.swift / FushiDesktopFloatingBall.swift 同一约定）；Dart 把它乘主窗
//   dpr 交给查词卡，查词卡再按同一 dpr 除回来，锚点落在被点的字上。
// - windowRectChanged / show 里的 left/top/width/height 是「物理 px」，见
//   FloatingLyricScreenSpace：宽高 = pt × 所在屏 backingScaleFactor（真物理像素）；原点
//   按「屏幕原点 × k + 屏内偏移 × 该屏 scale」编码（k = 所有屏 scale 的最大值）。macOS
//   的屏幕排布是 pt 空间的，混合缩放（Retina 内屏 + 1x 外屏）时简单的「pt × scale」会让
//   两块屏的物理区间重叠、恢复时落错屏；×k 编码保证各屏物理区间互不相交，往返无歧义。
//   单屏时就是 pt × scale，与 Windows 的物理像素同值。恢复时那块屏不在了 → 落回主屏
//   可见区（默认底部居中）。

private let kFloatingLyricChannel = "app.fushi.reader/floating_lyric"
/// 测试钩子通道：只在环境变量 FUSHI_TEST_FLOATING_LYRIC 存在时注册（生产启动零暴露），
/// 供 integration_test/macos_floating_lyric_itest.dart 取证与驱动。
private let kFloatingLyricTestChannel = "app.fushi.test/floating_lyric"
private let kFloatingLyricTestEnv = "FUSHI_TEST_FLOATING_LYRIC"

// 几何（pt；与 Windows floating_lyric_window.cpp 的 dip 常量同值，除默认高度）。
private let kFloatingLyricStripWidth: CGFloat = 720
/// 默认窗高。Windows 是 96dip，但它的正文区要先扣掉 40dip 工具条带，默认字号下
/// 双行（当前 + 下一行）会被裁掉半行；macOS 从一开始就给够两行。
private let kFloatingLyricStripHeight: CGFloat = 130
/// 6 槽工具条放得下的最窄窗宽（Windows kHookTextMinStripWidthDip）。
private let kFloatingLyricMinWidth: CGFloat = 376
private let kFloatingLyricMinHeight: CGFloat = 64
private let kFloatingLyricMaxWidth: CGFloat = 2400
private let kFloatingLyricMaxHeight: CGFloat = 480
private let kFloatingLyricBottomGap: CGFloat = 48
/// 拖动 / 恢复时窗口至少留这么多在工作区内（Windows kMinVisibleMarginDip）。
private let kFloatingLyricMinVisibleMargin: CGFloat = 48
private let kFloatingLyricButtonSize: CGFloat = 32
private let kFloatingLyricButtonGap: CGFloat = 4
private let kFloatingLyricControlsTop: CGFloat = 8
private let kFloatingLyricToolbarMargin: CGFloat = 5
private let kFloatingLyricToolbarRevealMargin: CGFloat = 24
private let kFloatingLyricResizeGrip: CGFloat = 18
private let kFloatingLyricDragThreshold: CGFloat = 6
private let kFloatingLyricHighlightRadius: CGFloat = 4
/// 背景 alpha 下限（≈2%）：用户把背景调成全透明时窗口仍接得住点击（Windows
/// kHookTextMinCatchAlpha）。
private let kFloatingLyricMinCatchAlpha: UInt32 = 5
private let kFloatingLyricScrollStep: CGFloat = 40
private let kFloatingLyricHoverPoll: TimeInterval = 0.06
private let kFloatingLyricToolbarRevealPoll: TimeInterval = 0.12

/// 工具条槽表（与 Windows hook_toolbar::kAudiobookSlotActions、Dart `_slotTooltips`
/// 严格同序；改一处必须三处同拍）。
let kFloatingLyricSlotActions: [String] = [
  "previousCue", "playPause", "nextCue", "lock", "topmost", "close",
]

// MARK: - 样式

/// 通道里的样式字段（键名与 Windows StyleFromArgs 同）。与 Windows 同规矩：每次
/// show / updateStyle 都从默认值重新解析，缺字段 = 默认值，而不是「沿用上一次」。
struct FloatingLyricMacStyle {
  var fontSize: CGFloat = 20
  var fontFamily = ""
  var fontPath = ""
  var letterSpacing: CGFloat = 0
  var lineHeight: CGFloat = 1.0
  var bold = true
  /// 0 = 居中，1 = 左对齐。
  var textAlignment = 0
  /// 0 = 垂直居中（溢出时自动顶对齐），1 = 恒顶对齐。
  var verticalAlignment = 0
  var textColor: UInt32 = 0xFFFF_FFFF
  var bgColor: UInt32 = 0xCC00_0000
  var outlineColor: UInt32 = 0xE000_0000
  var outlineWidth: CGFloat = 1.6
  var textPadding: CGFloat = 20
  var buttonTextColor: UInt32 = 0xFFFF_FFFF
  var buttonBgColor: UInt32 = 0x3300_0000
  var highlightColor: UInt32 = 0x80FF_D54F
  var activeColor: UInt32 = 0xFFFF_D54F
  var toolbarBgColor: UInt32 = 0
  var toolbarIconColor: UInt32 = 0
  var toolbarHoverColor: UInt32 = 0
  var toolbarActiveBgColor: UInt32 = 0
  var toolbarActiveIconColor: UInt32 = 0
  /// 0 是合法取值（直角），不是哨兵（与 Windows Style::corner_radius 同）。
  var cornerRadius: CGFloat = 14
  /// 0 = 平台默认宽（720pt 起始 + 可拖拽）。
  var windowWidth: CGFloat = 0
  var windowHeight: CGFloat = 0
  /// alpha 0 = 当前句沿用 textColor。
  var currentLineColor: UInt32 = 0
  var contextLineOpacity: CGFloat = 0.55

  init() {}

  init(args: [String: Any]) {
    func number(_ key: String) -> NSNumber? { return args[key] as? NSNumber }
    func double(_ key: String, _ fallback: CGFloat) -> CGFloat {
      guard let n = number(key) else { return fallback }
      let v = n.doubleValue
      return v.isFinite ? CGFloat(v) : fallback
    }
    func argb(_ key: String, _ fallback: UInt32) -> UInt32 {
      guard let n = number(key) else { return fallback }
      return UInt32(truncatingIfNeeded: n.int64Value)
    }
    func string(_ key: String) -> String { return (args[key] as? String) ?? "" }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      return (args[key] as? Bool) ?? number(key)?.boolValue ?? fallback
    }
    let d = FloatingLyricMacStyle()
    fontSize = double("fontSize", d.fontSize)
    fontFamily = string("fontFamily")
    fontPath = string("fontPath")
    letterSpacing = double("letterSpacing", d.letterSpacing)
    lineHeight = double("lineHeight", d.lineHeight)
    bold = bool("bold", d.bold)
    textAlignment = number("textAlignment")?.intValue ?? d.textAlignment
    verticalAlignment = number("verticalAlignment")?.intValue ?? d.verticalAlignment
    textColor = argb("textColor", d.textColor)
    bgColor = argb("bgColor", d.bgColor)
    outlineColor = argb("outlineColor", d.outlineColor)
    outlineWidth = double("outlineWidth", d.outlineWidth)
    textPadding = double("textPadding", d.textPadding)
    buttonTextColor = argb("buttonTextColor", d.buttonTextColor)
    buttonBgColor = argb("buttonBgColor", d.buttonBgColor)
    highlightColor = argb("highlightColor", d.highlightColor)
    activeColor = argb("activeColor", d.activeColor)
    toolbarBgColor = argb("toolbarBgColor", d.toolbarBgColor)
    toolbarIconColor = argb("toolbarIconColor", d.toolbarIconColor)
    toolbarHoverColor = argb("toolbarHoverColor", d.toolbarHoverColor)
    toolbarActiveBgColor = argb("toolbarActiveBgColor", d.toolbarActiveBgColor)
    toolbarActiveIconColor = argb("toolbarActiveIconColor", d.toolbarActiveIconColor)
    cornerRadius = double("cornerRadius", d.cornerRadius)
    windowWidth = double("windowWidth", d.windowWidth)
    windowHeight = double("windowHeight", d.windowHeight)
    currentLineColor = argb("currentLineColor", d.currentLineColor)
    contextLineOpacity = double("contextLineOpacity", d.contextLineOpacity)
  }
}

func floatingLyricColor(_ argb: UInt32) -> NSColor {
  return NSColor(
    srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
    green: CGFloat((argb >> 8) & 0xFF) / 255,
    blue: CGFloat(argb & 0xFF) / 255,
    alpha: CGFloat((argb >> 24) & 0xFF) / 255)
}

/// 把 [argb] 的 alpha 乘上 [factor]（0..1）。
func floatingLyricScaleAlpha(_ argb: UInt32, _ factor: CGFloat) -> UInt32 {
  let f = max(0, min(1, factor))
  let alpha = UInt32((CGFloat((argb >> 24) & 0xFF) * f).rounded())
  return (alpha << 24) | (argb & 0x00FF_FFFF)
}

// MARK: - 屏幕坐标空间（物理 px 编码）

/// 纯计算：全局 pt（AppKit 左下原点）矩形 ↔ 通道里的「物理 px、左上原点」矩形。
/// 编码规则见文件头。屏幕清单以参数传入，便于测试钩子用合成屏幕配置自检。
struct FloatingLyricScreenSpace {
  struct Screen {
    /// AppKit 全局 pt frame（左下原点）。
    let frame: CGRect
    /// 工作区（扣掉菜单栏与 Dock），AppKit 全局 pt。
    let visibleFrame: CGRect
    let scale: CGFloat
  }

  /// [0] 是主屏（菜单栏所在屏，全局坐标原点）。
  let screens: [Screen]

  static func current() -> FloatingLyricScreenSpace {
    return FloatingLyricScreenSpace(
      screens: NSScreen.screens.map {
        Screen(frame: $0.frame, visibleFrame: $0.visibleFrame, scale: $0.backingScaleFactor)
      })
  }

  var primaryHeight: CGFloat { return screens.first?.frame.maxY ?? 0 }

  /// 编码系数：所有屏 scale 的最大值。
  var k: CGFloat { return max(1, screens.map { $0.scale }.max() ?? 1) }

  /// AppKit 矩形 → 左上原点 pt。
  func topLeft(_ r: CGRect) -> CGRect {
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
  }

  /// 左上原点 pt → AppKit 矩形。
  func appKit(_ r: CGRect) -> CGRect {
    return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
  }

  /// 矩形所属的屏：中心落在哪块屏就是哪块；中心不在任何屏上时取相交面积最大的；
  /// 都不相交 = nil。
  func screenIndex(for r: CGRect) -> Int? {
    let center = CGPoint(x: r.midX, y: r.midY)
    if let i = screens.firstIndex(where: { $0.frame.contains(center) }) { return i }
    var best: Int?
    var bestArea: CGFloat = 0
    for (i, s) in screens.enumerated() {
      let inter = s.frame.intersection(r)
      if inter.isNull { continue }
      let area = inter.width * inter.height
      if area > bestArea {
        bestArea = area
        best = i
      }
    }
    return best
  }

  /// 某块屏在物理编码空间里的区间（左上原点）。
  func physicalRegion(of index: Int) -> CGRect {
    let s = screens[index]
    let tl = topLeft(s.frame)
    return CGRect(
      x: tl.minX * k, y: tl.minY * k, width: tl.width * s.scale, height: tl.height * s.scale)
  }

  /// AppKit 窗口 frame → 物理 px 矩形（四舍五入为整数，与 Windows 的 int 同形）。
  func toPhysical(_ frame: CGRect) -> CGRect {
    let index = screenIndex(for: frame) ?? 0
    guard index < screens.count else {
      return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }
    let s = screens[index]
    let tl = topLeft(frame)
    let stl = topLeft(s.frame)
    return CGRect(
      x: (stl.minX * k + (tl.minX - stl.minX) * s.scale).rounded(),
      y: (stl.minY * k + (tl.minY - stl.minY) * s.scale).rounded(),
      width: (tl.width * s.scale).rounded(),
      height: (tl.height * s.scale).rounded())
  }

  /// 物理 px 矩形 → (AppKit frame, 屏下标)。中心不落在任何屏的物理区间里（那块屏
  /// 被拔掉了 / 排布变了）= nil，调用方落回主屏默认位置。
  func fromPhysical(_ p: CGRect) -> (frame: CGRect, screen: Int)? {
    guard p.width > 0, p.height > 0 else { return nil }
    let center = CGPoint(x: p.midX, y: p.midY)
    for i in screens.indices where physicalRegion(of: i).contains(center) {
      let s = screens[i]
      let stl = topLeft(s.frame)
      let tl = CGRect(
        x: stl.minX + (p.minX - stl.minX * k) / s.scale,
        y: stl.minY + (p.minY - stl.minY * k) / s.scale,
        width: p.width / s.scale,
        height: p.height / s.scale)
      return (appKit(tl), i)
    }
    return nil
  }

  /// 把窗口原点夹进工作区：每条边至少留 [margin]（窗口比 margin 窄时整窗）在
  /// 工作区内（Windows ClampOriginToWorkArea 同式，换成 AppKit 坐标）。
  static func clampOrigin(_ frame: CGRect, into work: CGRect, margin: CGFloat) -> CGPoint {
    let mx = min(margin, frame.width)
    let my = min(margin, frame.height)
    let minX = work.minX - (frame.width - mx)
    let maxX = work.maxX - mx
    let minY = work.minY - (frame.height - my)
    let maxY = work.maxY - my
    let x = minX > maxX ? minX : max(minX, min(maxX, frame.minX))
    let y = minY > maxY ? maxY : max(minY, min(maxY, frame.minY))
    return CGPoint(x: x, y: y)
  }

  /// 默认位置：屏幕工作区底部居中，离底 48pt。
  static func defaultFrame(size: CGSize, in work: CGRect) -> CGRect {
    return CGRect(
      x: (work.midX - size.width / 2).rounded(),
      y: work.minY + kFloatingLyricBottomGap,
      width: size.width, height: size.height)
  }
}

// MARK: - 窗口

final class FloatingLyricPanel: NSPanel {
  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

/// 正文：背景、文字（双行 / 多行上下文，当前句满色、其余降亮）、区间高亮、描边，
/// 以及点字 / 拖动 / 缩放 / 滚动 / 悬停的事件入口。翻转坐标（左上原点）。
final class FloatingLyricBodyView: NSView {
  weak var controller: FloatingLyricController?

  override var isFlipped: Bool { return true }
  override var isOpaque: Bool { return false }
  override var mouseDownCanMoveWindow: Bool { return false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    // .activeAlways：Fushi 不在前台（这个窗口的常态）时也要收悬停。
    let t = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with event: NSEvent) { controller?.bodyHoverChanged(true) }
  override func mouseExited(with event: NSEvent) { controller?.bodyHoverChanged(false) }
  override func mouseMoved(with event: NSEvent) {
    controller?.bodyMouseMoved(local: convert(event.locationInWindow, from: nil))
  }
  override func mouseDown(with event: NSEvent) {
    controller?.bodyMouseDown(local: convert(event.locationInWindow, from: nil))
  }
  override func mouseDragged(with event: NSEvent) { controller?.pointerDragged() }
  override func mouseUp(with event: NSEvent) {
    controller?.bodyMouseUp(local: convert(event.locationInWindow, from: nil))
  }
  override func scrollWheel(with event: NSEvent) {
    let dy = event.hasPreciseScrollingDeltas
      ? event.scrollingDeltaY : event.scrollingDeltaY * kFloatingLyricScrollStep
    controller?.scrollBody(by: -dy)
  }

  override func draw(_ dirtyRect: NSRect) {
    controller?.drawBody(in: bounds)
  }
}

/// 工具条药丸：6 颗按钮（SF Symbols），悬停底色、激活态（锁定 / 置顶）高亮、提示。
final class FloatingLyricToolbarView: NSView {
  weak var controller: FloatingLyricController?
  var hoveredSlot = -1 { didSet { if oldValue != hoveredSlot { needsDisplay = true } } }
  private var tracking: NSTrackingArea?

  override var isFlipped: Bool { return true }
  override var isOpaque: Bool { return false }
  override var mouseDownCanMoveWindow: Bool { return false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(t)
    tracking = t
  }

  static func slotRect(_ slot: Int) -> CGRect {
    return CGRect(
      x: kFloatingLyricToolbarMargin
        + CGFloat(slot) * (kFloatingLyricButtonSize + kFloatingLyricButtonGap),
      y: kFloatingLyricToolbarMargin,
      width: kFloatingLyricButtonSize, height: kFloatingLyricButtonSize)
  }

  static var preferredSize: CGSize {
    let n = CGFloat(kFloatingLyricSlotActions.count)
    return CGSize(
      width: n * kFloatingLyricButtonSize + (n - 1) * kFloatingLyricButtonGap
        + 2 * kFloatingLyricToolbarMargin,
      height: kFloatingLyricButtonSize + 2 * kFloatingLyricToolbarMargin)
  }

  func slot(at p: CGPoint) -> Int {
    for i in kFloatingLyricSlotActions.indices where FloatingLyricToolbarView.slotRect(i)
      .contains(p)
    {
      return i
    }
    return -1
  }

  override func mouseMoved(with event: NSEvent) {
    hoveredSlot = slot(at: convert(event.locationInWindow, from: nil))
    toolTip = controller?.tooltip(forSlot: hoveredSlot)
  }
  override func mouseExited(with event: NSEvent) { hoveredSlot = -1 }
  override func mouseDown(with event: NSEvent) {
    controller?.toolbarMouseDown(slot: slot(at: convert(event.locationInWindow, from: nil)))
  }
  override func mouseDragged(with event: NSEvent) { controller?.pointerDragged() }
  override func mouseUp(with event: NSEvent) {
    controller?.toolbarMouseUp(slot: slot(at: convert(event.locationInWindow, from: nil)))
  }

  override func draw(_ dirtyRect: NSRect) {
    controller?.drawToolbar(in: bounds, hoveredSlot: hoveredSlot)
  }
}

// MARK: - 控制器

final class FloatingLyricController: NSObject {
  private enum Press {
    case none
    /// 正文上按下，还没越过拖动阈值：抬起即点字。
    case body(local: CGPoint)
    case drag
    case resize
    case toolbarButton(slot: Int)
    /// 工具条按钮之间的空白：拖它 = 拖正文窗。
    case toolbarBackground
  }

  private let channel: FlutterMethodChannel
  private var testChannel: FlutterMethodChannel?

  // Dart 下发的状态。
  private var style = FloatingLyricMacStyle()
  private var text = ""
  private var currentLineStart = -1
  private var currentLineLength = 0
  private var lineId = ""
  private var highlightStart = -1
  private var highlightLength = 0
  private var playing = false
  private var clickLookupEnabled = true
  private var hoverAutoLookup = false
  private var locked = false
  private var passThrough = false
  private var topmost = true
  private var slotTooltips: [String] = []
  private var labels: [String: String] = [:]
  private var initialPhysicalRect: CGRect?

  // 窗口。
  private var bodyPanel: FloatingLyricPanel?
  private var bodyView: FloatingLyricBodyView?
  private var toolbarPanel: FloatingLyricPanel?
  private var toolbarView: FloatingLyricToolbarView?
  private var toolbarShown = false
  private var visible = false

  // 排版缓存（文本 / 样式 / 正文宽度任一变化即作废）。
  private var layoutDirty = true
  private var layoutWidth: CGFloat = -1
  private let fillStorage = NSTextStorage()
  private let fillLayout = NSLayoutManager()
  private let fillContainer = NSTextContainer()
  private let strokeStorage = NSTextStorage()
  private let strokeLayout = NSLayoutManager()
  private let strokeContainer = NSTextContainer()
  private var contentHeight: CGFloat = 0
  private var scrollOffset: CGFloat = 0
  private var scrollMax: CGFloat = 0
  /// 跟随当前句（当前句行盒中线对准视口中线）；用户滚过就停，下一句 updateText 恢复。
  private var followCurrentLine = false

  // 交互。
  private var press: Press = .none
  private var pressGlobal: CGPoint = .zero
  private var pressFrame: CGRect = .zero
  private var hovered = false
  private var hoverLookupIndex = -1
  private var hoverTimer: Timer?
  private var revealTimer: Timer?
  private var screenObserver: NSObjectProtocol?

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: kFloatingLyricChannel, binaryMessenger: binaryMessenger)
    super.init()
    for (storage, layout, container) in [
      (fillStorage, fillLayout, fillContainer), (strokeStorage, strokeLayout, strokeContainer),
    ] {
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      layout.addTextContainer(container)
      storage.addLayoutManager(layout)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    if ProcessInfo.processInfo.environment[kFloatingLyricTestEnv] != nil {
      let test = FlutterMethodChannel(
        name: kFloatingLyricTestChannel, binaryMessenger: binaryMessenger)
      test.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.handleTest(call, result: result)
      }
      testChannel = test
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    testChannel?.setMethodCallHandler(nil)
  }

  // MARK: 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      return (args[key] as? Bool) ?? (args[key] as? NSNumber)?.boolValue ?? fallback
    }
    func int(_ key: String, _ fallback: Int) -> Int {
      return (args[key] as? NSNumber)?.intValue ?? fallback
    }
    switch call.method {
    case "canDrawOverlays":
      // runner 自己的窗口，没有系统悬浮窗权限这回事（与 Windows 同）。
      result(true)
    case "show":
      if let tips = args["slotTooltips"] as? [String] { slotTooltips = tips }
      applyStyle(FloatingLyricMacStyle(args: args))
      clickLookupEnabled = bool("clickLookupEnabled", true)
      hoverAutoLookup = bool("hoverAutoLookup", false)
      // 置顶 / 穿透按会话复位（与 Windows 同规矩）；locked 只在给了才覆盖。
      topmost = bool("topmost", true)
      if args["locked"] != nil { setLocked(bool("locked", false)) }
      let w = int("width", 0)
      let h = int("height", 0)
      initialPhysicalRect = (w > 0 && h > 0)
        ? CGRect(x: int("left", 0), y: int("top", 0), width: w, height: h) : nil
      result(show(passThrough: bool("passThrough", false)))
    case "hide":
      hide()
      result(nil)
    case "isShowing":
      result(isShowing)
    case "updateText":
      updateText(
        (args["text"] as? String) ?? "",
        currentLineStart: int("currentLineStart", -1),
        currentLineLength: int("currentLineLength", 0),
        lineId: (args["lineId"] as? String) ?? "")
      result(nil)
    case "highlight":
      highlightStart = int("start", -1)
      highlightLength = int("length", 0)
      bodyView?.needsDisplay = true
      result(nil)
    case "updateStyle":
      applyStyle(FloatingLyricMacStyle(args: args))
      result(nil)
    case "updateLabels":
      for key in ["previous", "playPause", "next", "lock", "unlock", "close"] {
        if let v = args[key] as? String { labels[key] = v }
      }
      result(nil)
    case "setPlaybackState":
      playing = bool("playing", false)
      toolbarView?.needsDisplay = true
      result(nil)
    case "setClickLookupEnabled":
      clickLookupEnabled = bool("enabled", true)
      result(nil)
    case "setLocked":
      setLocked(bool("locked", false))
      result(nil)
    case "setPassThrough":
      setPassThrough(bool("enabled", false))
      result(nil)
    case "setHoverAutoLookup":
      hoverAutoLookup = bool("enabled", false)
      hoverLookupIndex = -1
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func invoke(_ method: String, _ args: Any? = nil) {
    channel.invokeMethod(method, arguments: args)
  }

  // MARK: 生命周期

  var isShowing: Bool { return visible && (bodyPanel?.isVisible ?? false) }

  private func show(passThrough wantPassThrough: Bool) -> Bool {
    if bodyPanel == nil { createPanels() }
    guard let panel = bodyPanel else { return false }
    let space = FloatingLyricScreenSpace.current()
    var frame: CGRect
    if let physical = initialPhysicalRect, let restored = space.fromPhysical(physical) {
      // 存下来的宽度可能比今天的工具条还窄：夹到下限（Windows 同）。
      frame = restored.frame
      frame.size = clampedSize(frame.size)
      let work = space.screens[restored.screen].visibleFrame
      frame.origin = FloatingLyricScreenSpace.clampOrigin(
        frame, into: work, margin: kFloatingLyricMinVisibleMargin)
    } else if visible || panel.frame.width > 1 {
      // 已经摆过（再次 show / 上次 hide 后再开）：原地，只夹回屏内。
      frame = panel.frame
      frame.origin = clampedOriginOnScreen(frame)
    } else {
      // 首次 / 记住的那块屏不在了：主窗所在屏（缺省主屏）工作区底部居中。
      var size = CGSize(width: kFloatingLyricStripWidth, height: kFloatingLyricStripHeight)
      if style.windowWidth > 0 { size.width = style.windowWidth }
      if style.windowHeight > 0 { size.height = style.windowHeight }
      size = clampedSize(size)
      if let physical = initialPhysicalRect {
        // 屏幕被拔掉：尺寸按主屏 scale 还原，位置落回主屏可见区。
        let scale = space.screens.first?.scale ?? 1
        size = clampedSize(CGSize(width: physical.width / scale, height: physical.height / scale))
      }
      let work = defaultWorkArea()
      frame = FloatingLyricScreenSpace.defaultFrame(size: size, in: work)
    }
    initialPhysicalRect = nil
    panel.setFrame(frame, display: false)
    applyLevel()
    panel.orderFrontRegardless()
    visible = true
    hovered = false
    hoverLookupIndex = -1
    layoutDirty = true
    bodyView?.needsDisplay = true
    setPassThrough(wantPassThrough, force: true)
    startRevealTimer()
    updateToolbarReveal()
    if screenObserver == nil {
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.relayoutForScreenChange()
      }
    }
    return panel.isVisible
  }

  func hide() {
    visible = false
    cancelPress()
    hovered = false
    hoverLookupIndex = -1
    stopHoverTimer()
    stopRevealTimer()
    setToolbarShown(false)
    bodyPanel?.orderOut(nil)
  }

  /// 进程退出：拆掉全部窗口与观察者。
  func destroy() {
    hide()
    if let tb = toolbarPanel {
      bodyPanel?.removeChildWindow(tb)
      tb.close()
    }
    bodyPanel?.close()
    toolbarPanel = nil
    toolbarView = nil
    bodyPanel = nil
    bodyView = nil
    if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
    screenObserver = nil
  }

  private static func makePanel(title: String) -> FloatingLyricPanel {
    let panel = FloatingLyricPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isReleasedWhenClosed = false
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.allowsToolTipsWhenApplicationIsInactive = true
    panel.acceptsMouseMovedEvents = true
    panel.title = title
    return panel
  }

  private func createPanels() {
    let body = FloatingLyricController.makePanel(title: "Fushi Floating Lyric")
    let view = FloatingLyricBodyView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    view.controller = self
    view.wantsLayer = true
    view.autoresizingMask = [.width, .height]
    body.contentView = view
    bodyPanel = body
    bodyView = view

    let size = FloatingLyricToolbarView.preferredSize
    let toolbar = FloatingLyricController.makePanel(title: "Fushi Floating Lyric Toolbar")
    let tview = FloatingLyricToolbarView(frame: NSRect(origin: .zero, size: size))
    tview.controller = self
    tview.wantsLayer = true
    toolbar.contentView = tview
    toolbar.setContentSize(size)
    toolbarPanel = toolbar
    toolbarView = tview
  }

  private func applyLevel() {
    let level: NSWindow.Level = topmost ? .statusBar : .normal
    bodyPanel?.level = level
    toolbarPanel?.level = level
  }

  // MARK: 状态

  private func applyStyle(_ next: FloatingLyricMacStyle) {
    style = next
    layoutDirty = true
    applyStyleWidth()
    bodyView?.needsDisplay = true
    toolbarView?.needsDisplay = true
  }

  /// 设置里给了窗宽（>0）：按它改宽，保留左上角，再夹回屏内（Windows ApplyStyleWidth）。
  private func applyStyleWidth() {
    guard let panel = bodyPanel, style.windowWidth > 0, panel.frame.width > 1 else { return }
    let target = max(kFloatingLyricMinWidth, min(kFloatingLyricMaxWidth, style.windowWidth))
    var frame = panel.frame
    if abs(frame.width - target) < 0.5 { return }
    frame.size.width = target
    frame.origin = clampedOriginOnScreen(frame)
    panel.setFrame(frame, display: true)
    syncToolbarFrame()
  }

  private func updateText(
    _ next: String, currentLineStart start: Int, currentLineLength length: Int, lineId id: String
  ) {
    text = next
    currentLineStart = start
    currentLineLength = length
    lineId = id
    followCurrentLine = start >= 0 && length > 0
    highlightStart = -1
    highlightLength = 0
    // 整块换掉而不是追加：回到顶部（再由跟随把当前句滚进视口中央）。
    scrollOffset = 0
    hoverLookupIndex = -1
    layoutDirty = true
    bodyView?.needsDisplay = true
  }

  private func setLocked(_ value: Bool) {
    guard locked != value else { return }
    locked = value
    // 锁定时正在进行的拖动 / 缩放就地作废，下一下按重新判。
    if locked { cancelPress() }
    bodyView?.needsDisplay = true
    toolbarView?.needsDisplay = true
  }

  private func setPassThrough(_ value: Bool, force: Bool = false) {
    if !force && passThrough == value { return }
    passThrough = value
    cancelPress()
    // 穿透的正文收不到鼠标，也就收不到 mouseExited：悬停态在这里清掉。
    hovered = false
    hoverLookupIndex = -1
    bodyPanel?.ignoresMouseEvents = value
    if value {
      // 先把工具条亮出来：它是穿透态下唯一的回退入口（BUG-951 语义）。
      setToolbarShown(true)
      if toolbarPanel?.isVisible != true {
        // 逃生口建不出来就拒绝穿透，并告诉 Dart（Windows BUG-951 同契约）。
        passThrough = false
        bodyPanel?.ignoresMouseEvents = false
        invoke("passThroughChanged", ["passThrough": false])
        return
      }
      // 穿透态只剩 Shift-悬停查词：轮询全局光标。
      startHoverTimer()
    } else {
      stopHoverTimer()
    }
    if !force { invoke("passThroughChanged", ["passThrough": value]) }
    bodyView?.needsDisplay = true
    toolbarView?.needsDisplay = true
  }

  private func setTopmost(_ value: Bool) {
    topmost = value
    applyLevel()
    if value { bodyPanel?.orderFrontRegardless() }
    toolbarView?.needsDisplay = true
  }

  // MARK: 几何

  private func clampedSize(_ size: CGSize) -> CGSize {
    return CGSize(
      width: max(kFloatingLyricMinWidth, min(kFloatingLyricMaxWidth, size.width)).rounded(),
      height: max(kFloatingLyricMinHeight, min(kFloatingLyricMaxHeight, size.height)).rounded())
  }

  private func defaultWorkArea() -> CGRect {
    let mainWindowScreen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: {
      !($0 is FloatingLyricPanel) && $0.isVisible
    })?.screen
    return (mainWindowScreen ?? NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
      ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
  }

  /// 按窗口自己所在的屏夹原点；它不在任何屏上了 = nil 屏 → 主屏默认位置。
  private func clampedOriginOnScreen(_ frame: CGRect) -> CGPoint {
    let space = FloatingLyricScreenSpace.current()
    guard let i = space.screenIndex(for: frame) else {
      let primary = space.screens.first?.visibleFrame ?? defaultWorkArea()
      return FloatingLyricScreenSpace.defaultFrame(size: frame.size, in: primary).origin
    }
    return FloatingLyricScreenSpace.clampOrigin(
      frame, into: space.screens[i].visibleFrame, margin: kFloatingLyricMinVisibleMargin)
  }

  /// 拖动中按光标所在屏夹（能跨屏拖，拖不出屏外；Windows MoveBodyTo 同）。
  private func clampedOriginUnderCursor(_ frame: CGRect, cursor: CGPoint) -> CGPoint {
    let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) })
    guard let work = screen?.visibleFrame else { return clampedOriginOnScreen(frame) }
    return FloatingLyricScreenSpace.clampOrigin(
      frame, into: work, margin: kFloatingLyricMinVisibleMargin)
  }

  private func relayoutForScreenChange() {
    guard let panel = bodyPanel, visible else { return }
    cancelPress()
    var frame = panel.frame
    frame.origin = clampedOriginOnScreen(frame)
    if frame.origin != panel.frame.origin {
      panel.setFrameOrigin(frame.origin)
      notifyBounds()
    }
    syncToolbarFrame()
    layoutDirty = true
    bodyView?.needsDisplay = true
  }

  private func notifyBounds() {
    guard let panel = bodyPanel else { return }
    let p = FloatingLyricScreenSpace.current().toPhysical(panel.frame)
    invoke(
      "windowRectChanged",
      [
        "left": Int(p.minX), "top": Int(p.minY), "width": Int(p.width), "height": Int(p.height),
      ])
  }

  private var controlsHeight: CGFloat {
    return kFloatingLyricButtonSize + kFloatingLyricControlsTop
  }

  /// 正文区（视图翻转坐标）：顶部留工具条带，左右 textPadding、底部半个 padding
  /// （Windows text_rect_ 同式）。
  private func textRect(in bounds: CGRect) -> CGRect {
    let pad = max(0, min(120, style.textPadding))
    return CGRect(
      x: pad, y: controlsHeight,
      width: max(1, bounds.width - pad * 2),
      height: max(1, bounds.height - controlsHeight - pad * 0.5))
  }

  // MARK: 排版

  private func resolvedFont() -> NSFont {
    let size = max(4, style.fontSize)
    var font: NSFont?
    if !style.fontPath.isEmpty,
      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
        URL(fileURLWithPath: style.fontPath) as CFURL) as? [CTFontDescriptor],
      let first = descriptors.first
    {
      font = CTFontCreateWithFontDescriptor(first, size, nil) as NSFont
    }
    if font == nil, !style.fontFamily.isEmpty {
      font = NSFont(name: style.fontFamily, size: size)
        ?? NSFontManager.shared.font(
          withFamily: style.fontFamily, traits: [], weight: 5, size: size)
    }
    guard var resolved = font else {
      return NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
    }
    if style.bold {
      let converted = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
      resolved = converted
    }
    return resolved
  }

  private func ensureLayout(width: CGFloat) {
    if !layoutDirty && abs(width - layoutWidth) < 0.5 { return }
    layoutDirty = false
    layoutWidth = width
    let font = resolvedFont()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = style.textAlignment == 1 ? .left : .center
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineHeightMultiple = max(0.8, min(2.0, style.lineHeight))
    let kern = max(-5, min(20, style.letterSpacing))
    let base: [NSAttributedString.Key: Any] = [
      .font: font, .paragraphStyle: paragraph, .kern: kern,
    ]
    let ns = text as NSString
    let length = ns.length

    // 填充遍：当前句满色（或 currentLineColor），其余行降到 contextLineOpacity。
    let fill = NSMutableAttributedString(string: text, attributes: base)
    fill.addAttribute(
      .foregroundColor, value: floatingLyricColor(style.textColor),
      range: NSRange(location: 0, length: length))
    if let current = currentLineRange(length: length) {
      let dim = floatingLyricColor(
        floatingLyricScaleAlpha(style.textColor, style.contextLineOpacity))
      if current.location > 0 {
        fill.addAttribute(
          .foregroundColor, value: dim, range: NSRange(location: 0, length: current.location))
      }
      let end = current.location + current.length
      if end < length {
        fill.addAttribute(
          .foregroundColor, value: dim, range: NSRange(location: end, length: length - end))
      }
      if (style.currentLineColor >> 24) != 0 {
        fill.addAttribute(
          .foregroundColor, value: floatingLyricColor(style.currentLineColor), range: current)
      }
    }
    fillStorage.setAttributedString(fill)

    // 描边遍：同一排版属性（字形位置逐一相同），只描不填。strokeWidth 是字号百分比，
    // 描边以轮廓为中线，外侧可见一半，所以取 2 × outlineWidth。
    let outline = max(0, min(8, style.outlineWidth))
    var strokeAttrs = base
    strokeAttrs[.foregroundColor] = NSColor.clear
    strokeAttrs[.strokeColor] = floatingLyricColor(style.outlineColor)
    strokeAttrs[.strokeWidth] = outline > 0 ? (2 * outline / font.pointSize) * 100 : 0
    strokeStorage.setAttributedString(NSAttributedString(string: text, attributes: strokeAttrs))

    for container in [fillContainer, strokeContainer] {
      container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }
    fillLayout.ensureLayout(for: fillContainer)
    strokeLayout.ensureLayout(for: strokeContainer)
    contentHeight = ceil(fillLayout.usedRect(for: fillContainer).height)
  }

  private func currentLineRange(length: Int) -> NSRange? {
    guard currentLineStart >= 0, currentLineLength > 0, length > 0 else { return nil }
    let start = min(currentLineStart, length)
    let end = min(currentLineStart + currentLineLength, length)
    return end > start ? NSRange(location: start, length: end - start) : nil
  }

  /// 文字块左上角在视图（翻转）坐标里的位置；同时刷新滚动行程与跟随。
  private func textOrigin(in rect: CGRect) -> CGPoint {
    scrollMax = max(0, contentHeight - rect.height)
    let overflow = scrollMax > 0
    if overflow, followCurrentLine,
      let current = currentLineRange(length: (text as NSString).length)
    {
      let glyphs = fillLayout.glyphRange(forCharacterRange: current, actualCharacterRange: nil)
      let lineRect = fillLayout.boundingRect(forGlyphRange: glyphs, in: fillContainer)
      scrollOffset = lineRect.midY - rect.height / 2
    }
    scrollOffset = max(0, min(scrollMax, scrollOffset))
    let y: CGFloat
    if overflow || style.verticalAlignment == 1 {
      y = rect.minY - scrollOffset
    } else {
      y = rect.minY + (rect.height - contentHeight) / 2
    }
    return CGPoint(x: rect.minX, y: y)
  }

  // MARK: 绘制

  func drawBody(in bounds: CGRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    // 背景（alpha 下限保证全透明背景也接得住点击）。
    var bg = style.bgColor
    if (bg >> 24) < kFloatingLyricMinCatchAlpha {
      bg = (kFloatingLyricMinCatchAlpha << 24) | (bg & 0x00FF_FFFF)
    }
    let radius = max(0, min(style.cornerRadius, min(bounds.width, bounds.height) / 2))
    let bgPath = CGPath(
      roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.setFillColor(floatingLyricColor(bg).cgColor)
    ctx.fillPath()

    let rect = textRect(in: bounds)
    ensureLayout(width: rect.width)
    let origin = textOrigin(in: rect)
    ctx.saveGState()
    ctx.clip(to: rect)
    // 区间高亮（音节 / 句内区间；Dart 按音节边界下发，不逐帧）。
    let length = (text as NSString).length
    if highlightStart >= 0, highlightLength > 0, highlightStart < length {
      let range = NSRange(
        location: highlightStart, length: min(highlightLength, length - highlightStart))
      let glyphs = fillLayout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      ctx.setFillColor(floatingLyricColor(style.highlightColor).cgColor)
      fillLayout.enumerateEnclosingRects(
        forGlyphRange: glyphs,
        withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: fillContainer
      ) { r, _ in
        let box = r.offsetBy(dx: origin.x, dy: origin.y)
        ctx.addPath(
          CGPath(
            roundedRect: box, cornerWidth: kFloatingLyricHighlightRadius,
            cornerHeight: kFloatingLyricHighlightRadius, transform: nil))
        ctx.fillPath()
      }
    }
    if style.outlineWidth > 0, (style.outlineColor >> 24) != 0 {
      strokeLayout.drawGlyphs(
        forGlyphRange: strokeLayout.glyphRange(for: strokeContainer), at: origin)
    }
    fillLayout.drawGlyphs(forGlyphRange: fillLayout.glyphRange(for: fillContainer), at: origin)
    ctx.restoreGState()

    // 右下角缩放握把（锁定时不画、也不命中）。
    if !locked && !passThrough {
      let alpha: CGFloat = hovered ? 0.7 : 0.2
      ctx.setStrokeColor(floatingLyricColor(style.textColor).withAlphaComponent(alpha).cgColor)
      ctx.setLineWidth(1.5)
      ctx.setLineCap(.round)
      for i in 1...3 {
        let d = CGFloat(i) * 4
        ctx.move(to: CGPoint(x: bounds.maxX - 4 - d, y: bounds.maxY - 4))
        ctx.addLine(to: CGPoint(x: bounds.maxX - 4, y: bounds.maxY - 4 - d))
      }
      ctx.strokePath()
    }
  }

  private struct ToolbarColors {
    let surface: UInt32
    let icon: UInt32
    let hover: UInt32
    let activeBg: UInt32
    let activeIcon: UInt32
  }

  /// M3E 工具条配色（Dart galHookToolbarThemeArgs）；没下发（toolbarBgColor alpha 0）
  /// 按旧四色兜底（Windows FloatingLyricWindow::ToolbarStyle 同式）。
  private var toolbarColors: ToolbarColors {
    if (style.toolbarBgColor >> 24) != 0 {
      return ToolbarColors(
        surface: style.toolbarBgColor, icon: style.toolbarIconColor,
        hover: style.toolbarHoverColor, activeBg: style.toolbarActiveBgColor,
        activeIcon: style.toolbarActiveIconColor)
    }
    var surface = style.bgColor
    if (surface >> 24) < 0xB0 { surface = (0xB0 << 24) | (surface & 0x00FF_FFFF) }
    return ToolbarColors(
      surface: surface, icon: style.buttonTextColor, hover: style.buttonBgColor,
      activeBg: style.buttonBgColor, activeIcon: style.activeColor)
  }

  private func symbol(forSlot slot: Int) -> String {
    switch kFloatingLyricSlotActions[slot] {
    case "previousCue": return "backward.fill"
    case "playPause": return playing ? "pause.fill" : "play.fill"
    case "nextCue": return "forward.fill"
    case "lock": return locked ? "lock.fill" : "lock.open"
    case "topmost": return topmost ? "pin.fill" : "pin.slash"
    default: return "xmark"
    }
  }

  private func slotIsActive(_ slot: Int) -> Bool {
    switch kFloatingLyricSlotActions[slot] {
    case "lock": return locked
    case "topmost": return topmost
    default: return false
    }
  }

  func tooltip(forSlot slot: Int) -> String? {
    guard slot >= 0, slot < kFloatingLyricSlotActions.count else { return nil }
    if slot < slotTooltips.count, !slotTooltips[slot].isEmpty { return slotTooltips[slot] }
    switch kFloatingLyricSlotActions[slot] {
    case "previousCue": return labels["previous"]
    case "playPause": return labels["playPause"]
    case "nextCue": return labels["next"]
    case "lock": return locked ? labels["unlock"] : labels["lock"]
    case "close": return labels["close"]
    default: return nil
    }
  }

  func drawToolbar(in bounds: CGRect, hoveredSlot: Int) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let colors = toolbarColors
    let pill = CGPath(
      roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2,
      transform: nil)
    ctx.addPath(pill)
    ctx.setFillColor(floatingLyricColor(colors.surface).cgColor)
    ctx.fillPath()
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    for slot in kFloatingLyricSlotActions.indices {
      let r = FloatingLyricToolbarView.slotRect(slot)
      let active = slotIsActive(slot)
      if active || slot == hoveredSlot {
        ctx.addPath(
          CGPath(
            roundedRect: r, cornerWidth: r.width / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(floatingLyricColor(active ? colors.activeBg : colors.hover).cgColor)
        ctx.fillPath()
      }
      guard
        let base = NSImage(
          systemSymbolName: symbol(forSlot: slot), accessibilityDescription: tooltip(forSlot: slot)),
        let image = base.withSymbolConfiguration(config)
      else { continue }
      let tint = floatingLyricColor(active ? colors.activeIcon : colors.icon)
      let tinted = NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        tint.set()
        rect.fill(using: .sourceAtop)
        return true
      }
      let size = image.size
      tinted.draw(
        in: CGRect(
          x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width,
          height: size.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
  }

  // MARK: 工具条显隐

  private func syncToolbarFrame() {
    guard let body = bodyPanel, let toolbar = toolbarPanel else { return }
    let size = FloatingLyricToolbarView.preferredSize
    // 药丸压在正文窗上沿的工具条带里、水平居中（Windows ComputePassThroughToolbarLayout）。
    let x = body.frame.minX + (body.frame.width - size.width) / 2
    let topY = body.frame.maxY - kFloatingLyricControlsTop + kFloatingLyricToolbarMargin
    toolbar.setFrame(
      CGRect(x: x.rounded(), y: (topY - size.height).rounded(), width: size.width,
        height: size.height), display: toolbarShown)
  }

  private func setToolbarShown(_ shown: Bool) {
    guard let body = bodyPanel, let toolbar = toolbarPanel else { return }
    let want = shown && visible
    if want == toolbarShown && (want == toolbar.isVisible) { return }
    toolbarShown = want
    if want {
      syncToolbarFrame()
      if toolbar.parent == nil { body.addChildWindow(toolbar, ordered: .above) }
      toolbar.orderFrontRegardless()
      toolbarView?.needsDisplay = true
    } else {
      if toolbar.parent != nil { body.removeChildWindow(toolbar) }
      toolbar.orderOut(nil)
      toolbarView?.hoveredSlot = -1
    }
  }

  /// 揭示区 = 正文窗 ∪ 工具条，外扩 24pt（鼠标往工具条方向移不会先把它判没）。
  private func cursorInRevealZone() -> Bool {
    guard let body = bodyPanel else { return false }
    var zone = body.frame
    if let toolbar = toolbarPanel { zone = zone.union(toolbar.frame) }
    zone = zone.insetBy(
      dx: -kFloatingLyricToolbarRevealMargin, dy: -kFloatingLyricToolbarRevealMargin)
    return zone.contains(NSEvent.mouseLocation)
  }

  private func updateToolbarReveal() {
    guard visible else { return }
    switch press {
    case .drag, .resize, .toolbarBackground, .toolbarButton:
      // 拖动 / 按着按钮时不收工具条。
      setToolbarShown(true)
      return
    default:
      break
    }
    setToolbarShown(passThrough || cursorInRevealZone())
  }

  private func startRevealTimer() {
    guard revealTimer == nil else { return }
    let timer = Timer(timeInterval: kFloatingLyricToolbarRevealPoll, repeats: true) {
      [weak self] _ in
      self?.updateToolbarReveal()
    }
    RunLoop.main.add(timer, forMode: .common)
    revealTimer = timer
  }

  private func stopRevealTimer() {
    revealTimer?.invalidate()
    revealTimer = nil
  }

  // MARK: 命中与查词

  /// 视图（翻转）坐标点下的字（UTF-16 下标）与它在视图里的矩形；不在字上 = nil。
  private func charHit(at local: CGPoint) -> (index: Int, rect: CGRect)? {
    guard let view = bodyView, !text.isEmpty else { return nil }
    let rect = textRect(in: view.bounds)
    guard rect.contains(local) else { return nil }
    ensureLayout(width: rect.width)
    let origin = textOrigin(in: rect)
    let p = CGPoint(x: local.x - origin.x, y: local.y - origin.y)
    var fraction: CGFloat = 0
    let glyph = fillLayout.glyphIndex(
      for: p, in: fillContainer, fractionOfDistanceThroughGlyph: &fraction)
    guard glyph < fillLayout.numberOfGlyphs else { return nil }
    let box = fillLayout.boundingRect(
      forGlyphRange: NSRange(location: glyph, length: 1), in: fillContainer)
    guard box.width > 0, box.contains(p) else { return nil }
    let index = fillLayout.characterIndexForGlyph(at: glyph)
    let ns = text as NSString
    guard index < ns.length else { return nil }
    let ch = ns.character(at: index)
    if ch == 0x0A || ch == 0x0D { return nil }
    return (index, box.offsetBy(dx: origin.x, dy: origin.y))
  }

  /// 视图矩形 → 屏幕逻辑 px（左上原点全局 pt；macOS 坐标 y 轴在这里翻转）。
  private func screenLogicalRect(_ viewRect: CGRect) -> CGRect? {
    guard let view = bodyView, let window = view.window else { return nil }
    let inWindow = view.convert(viewRect, to: nil)
    let onScreen = window.convertToScreen(inWindow)
    return FloatingLyricScreenSpace.current().topLeft(onScreen)
  }

  @discardableResult
  private func dispatchLookup(at local: CGPoint) -> Bool {
    guard let hit = charHit(at: local), let word = screenLogicalRect(hit.rect) else {
      return false
    }
    invoke(
      "lookupText",
      [
        "lineId": lineId, "text": text, "index": hit.index,
        "wordLeft": Double(word.minX), "wordTop": Double(word.minY),
        "wordWidth": Double(word.width), "wordHeight": Double(word.height),
      ])
    return true
  }

  // MARK: 悬停查词

  func bodyHoverChanged(_ inside: Bool) {
    hovered = inside && !passThrough
    if !inside { hoverLookupIndex = -1 }
    if hovered || passThrough { startHoverTimer() } else { stopHoverTimer() }
    bodyView?.needsDisplay = true
    updateToolbarReveal()
  }

  func bodyMouseMoved(local: CGPoint) {
    if !hovered { bodyHoverChanged(true) }
    maybeHoverLookup(local: local)
  }

  /// Shift-悬停（或「悬停即查词」）：同一个字不重复查；拖动 / 按压中不查；穿透态只认
  /// Shift（Windows MaybeHoverLookup 同判据）。Shift 读全局修饰键态——这个窗口永远
  /// 不是 key window，收不到 flagsChanged。
  private func maybeHoverLookup(local: CGPoint) {
    guard clickLookupEnabled, visible else { return }
    if case .none = press {} else { return }
    let shift = NSEvent.modifierFlags.contains(.shift)
    if (passThrough && !shift) || (!shift && !hoverAutoLookup) {
      hoverLookupIndex = -1
      return
    }
    guard let hit = charHit(at: local) else {
      hoverLookupIndex = -1
      return
    }
    if hit.index == hoverLookupIndex { return }
    hoverLookupIndex = hit.index
    if !dispatchLookup(at: local) { hoverLookupIndex = -1 }
  }

  private func pollHover() {
    guard visible, let view = bodyView, let window = view.window else { return }
    let mouse = NSEvent.mouseLocation
    guard window.frame.contains(mouse) else {
      hoverLookupIndex = -1
      if !passThrough && hovered { bodyHoverChanged(false) }
      return
    }
    let local = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
    maybeHoverLookup(local: local)
  }

  private func startHoverTimer() {
    guard hoverTimer == nil else { return }
    let timer = Timer(timeInterval: kFloatingLyricHoverPoll, repeats: true) { [weak self] _ in
      self?.pollHover()
    }
    RunLoop.main.add(timer, forMode: .common)
    hoverTimer = timer
  }

  private func stopHoverTimer() {
    hoverTimer?.invalidate()
    hoverTimer = nil
  }

  // MARK: 按压 / 拖动 / 缩放

  private func cancelPress() {
    press = .none
  }

  private func inResizeGrip(_ local: CGPoint) -> Bool {
    guard let view = bodyView, !locked else { return false }
    let b = view.bounds
    return local.x >= b.maxX - kFloatingLyricResizeGrip && local.y >= b.maxY - kFloatingLyricResizeGrip
  }

  func bodyMouseDown(local: CGPoint) {
    guard let panel = bodyPanel else { return }
    pressGlobal = NSEvent.mouseLocation
    pressFrame = panel.frame
    press = inResizeGrip(local) ? .resize : .body(local: local)
  }

  func toolbarMouseDown(slot: Int) {
    guard let panel = bodyPanel else { return }
    pressGlobal = NSEvent.mouseLocation
    pressFrame = panel.frame
    press = slot >= 0 ? .toolbarButton(slot: slot) : .toolbarBackground
  }

  /// 测试钩子与真鼠标共用：拖动以全局 pt 计。
  func pointerDragged(to global: CGPoint = NSEvent.mouseLocation) {
    guard let panel = bodyPanel else { return }
    let dx = global.x - pressGlobal.x
    let dy = global.y - pressGlobal.y
    switch press {
    case .resize:
      // 左上角不动：AppKit y 向上，往下拖（dy < 0）= 加高。
      let size = clampedSize(CGSize(width: pressFrame.width + dx, height: pressFrame.height - dy))
      let frame = CGRect(
        x: pressFrame.minX, y: pressFrame.maxY - size.height, width: size.width,
        height: size.height)
      panel.setFrame(frame, display: true)
      syncToolbarFrame()
      layoutDirty = true
    case .body, .toolbarBackground, .drag:
      if locked { return }
      if case .drag = press {} else {
        if hypot(dx, dy) < kFloatingLyricDragThreshold { return }
        press = .drag
      }
      var frame = pressFrame.offsetBy(dx: dx, dy: dy)
      frame.origin = clampedOriginUnderCursor(frame, cursor: global)
      panel.setFrameOrigin(frame.origin)
    default:
      break
    }
  }

  private func endDragOrResize() {
    guard let panel = bodyPanel else { return }
    var frame = panel.frame
    frame.origin = clampedOriginOnScreen(frame)
    if frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
    syncToolbarFrame()
    notifyBounds()
  }

  func bodyMouseUp(local: CGPoint) {
    let finished = press
    press = .none
    switch finished {
    case .drag, .resize:
      endDragOrResize()
    case .body:
      if clickLookupEnabled { dispatchLookup(at: local) }
    default:
      break
    }
    updateToolbarReveal()
  }

  func toolbarMouseUp(slot: Int) {
    let finished = press
    press = .none
    switch finished {
    case .drag:
      endDragOrResize()
    case .toolbarButton(let pressed) where pressed == slot:
      dispatchControl(kFloatingLyricSlotActions[slot])
    default:
      break
    }
    updateToolbarReveal()
  }

  /// 锁定 / 置顶 native 就地翻转（锁定回报 lockChanged）；其余转给 Dart（Windows
  /// DispatchControlAction 同）。
  private func dispatchControl(_ action: String) {
    switch action {
    case "lock":
      setLocked(!locked)
      invoke("lockChanged", ["locked": locked])
    case "topmost":
      setTopmost(!topmost)
    default:
      invoke(action)
    }
  }

  func scrollBody(by delta: CGFloat) {
    guard scrollMax > 0 else { return }
    followCurrentLine = false
    scrollOffset = max(0, min(scrollMax, scrollOffset + delta))
    hoverLookupIndex = -1
    bodyView?.needsDisplay = true
  }

  // MARK: 测试钩子（FUSHI_TEST_FLOATING_LYRIC）

  private func handleTest(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probe":
      result(probe())
    case "clickChar":
      // 真 NSEvent 按下 / 抬起送进正文窗（sendEvent → 视图 mouseDown/Up → 控制器），
      // 点在第 index 个字的中心。真光标不动，所以不越拖动阈值 = 点字。
      let index = (args["index"] as? NSNumber)?.intValue ?? 0
      guard let panel = bodyPanel, let view = bodyView,
        let center = charCenter(index: index)
      else {
        result(FlutterError(code: "no_char", message: "char \(index) not laid out", details: nil))
        return
      }
      let inWindow = view.convert(center, to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
          with: type, location: inWindow, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        {
          panel.sendEvent(event)
        }
      }
      result(["x": Double(center.x), "y": Double(center.y)])
    case "dragBy":
      // 拖动走与真鼠标同一组控制器入口（bodyMouseDown → pointerDragged → bodyMouseUp），
      // 只是全局光标位置由参数给出（ssh 起的进程没有辅助功能授权，CGEvent 挪不动光标）。
      let dx = CGFloat((args["dx"] as? NSNumber)?.doubleValue ?? 0)
      let dy = CGFloat((args["dy"] as? NSNumber)?.doubleValue ?? 0)
      guard let panel = bodyPanel else {
        result(FlutterError(code: "no_panel", message: nil, details: nil))
        return
      }
      let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
      pressGlobal = start
      pressFrame = panel.frame
      press = .body(local: .zero)
      let steps = 8
      for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        pointerDragged(to: CGPoint(x: start.x + dx * t, y: start.y - dy * t))
      }
      press = .drag
      bodyMouseUp(local: .zero)
      result(probe())
    case "toolbarAction":
      let action = (args["action"] as? String) ?? ""
      dispatchControl(action)
      result(probe())
    case "screenSpaceSelfTest":
      result(FloatingLyricController.screenSpaceSelfTest())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func charCenter(index: Int) -> CGPoint? {
    guard let view = bodyView else { return nil }
    let rect = textRect(in: view.bounds)
    ensureLayout(width: rect.width)
    let origin = textOrigin(in: rect)
    let ns = text as NSString
    guard index >= 0, index < ns.length else { return nil }
    let glyphs = fillLayout.glyphRange(
      forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
    let box = fillLayout.boundingRect(forGlyphRange: glyphs, in: fillContainer)
    return CGPoint(x: origin.x + box.midX, y: origin.y + box.midY)
  }

  private func probe() -> [String: Any] {
    let space = FloatingLyricScreenSpace.current()
    var out: [String: Any] = [
      "visible": isShowing, "locked": locked, "topmost": topmost, "passThrough": passThrough,
      "text": text, "highlightStart": highlightStart, "highlightLength": highlightLength,
      "appActive": NSApp.isActive, "scrollOffset": Double(scrollOffset),
      "scrollMax": Double(scrollMax), "contentHeight": Double(contentHeight),
    ]
    if let panel = bodyPanel {
      let tl = space.topLeft(panel.frame)
      let p = space.toPhysical(panel.frame)
      out["windowNumber"] = panel.windowNumber
      out["level"] = panel.level.rawValue
      out["ignoresMouseEvents"] = panel.ignoresMouseEvents
      out["isKeyWindow"] = panel.isKeyWindow
      out["canBecomeKey"] = panel.canBecomeKey
      out["collectionBehavior"] = panel.collectionBehavior.rawValue
      out["styleMask"] = panel.styleMask.rawValue
      out["frameTopLeft"] = [tl.minX, tl.minY, tl.width, tl.height].map { Double($0) }
      out["physical"] = [p.minX, p.minY, p.width, p.height].map { Double($0) }
      out["screenIndex"] = space.screenIndex(for: panel.frame) ?? -1
      out["screenScale"] = Double(panel.screen?.backingScaleFactor ?? 0)
    }
    if let toolbar = toolbarPanel {
      out["toolbarVisible"] = toolbar.isVisible
      out["toolbarWindowNumber"] = toolbar.windowNumber
      out["toolbarFrameTopLeft"] =
        [space.topLeft(toolbar.frame).minX, space.topLeft(toolbar.frame).minY,
         toolbar.frame.width, toolbar.frame.height].map { Double($0) }
    }
    out["screens"] = space.screens.map { s -> [Double] in
      [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height, s.scale].map { Double($0) }
    }
    return out
  }

  /// 物理 px 编码的往返自检：合成三种屏幕配置（单 Retina、Retina 主屏 + 右侧 1x
  /// 外屏、外屏被拔掉），逐条报告编码值与解码回来的屏 / 矩形。
  static func screenSpaceSelfTest() -> [[String: Any]] {
    let retina = FloatingLyricScreenSpace.Screen(
      frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
      visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 919), scale: 2)
    let external = FloatingLyricScreenSpace.Screen(
      frame: CGRect(x: 1470, y: -124, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 1470, y: -124, width: 1920, height: 1055), scale: 1)
    let single = FloatingLyricScreenSpace(screens: [retina])
    let dual = FloatingLyricScreenSpace(screens: [retina, external])
    var cases: [[String: Any]] = []
    func record(_ name: String, _ space: FloatingLyricScreenSpace, _ frame: CGRect,
                decodeWith: FloatingLyricScreenSpace? = nil) {
      let p = space.toPhysical(frame)
      let decoded = (decodeWith ?? space).fromPhysical(p)
      cases.append([
        "name": name,
        "frame": [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) },
        "physical": [p.minX, p.minY, p.width, p.height].map { Double($0) },
        "decodedScreen": decoded?.screen ?? -1,
        "decodedFrame": decoded.map {
          [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].map { Double($0) }
        } ?? [],
      ])
    }
    record("single-retina", single, CGRect(x: 375, y: 48, width: 720, height: 130))
    record("dual-on-retina", dual, CGRect(x: 375, y: 48, width: 720, height: 130))
    // 外屏上、且「pt × 内屏 scale」会落进内屏物理区间的位置——朴素编码在这里会解错屏。
    record("dual-on-external", dual, CGRect(x: 1600, y: 300, width: 720, height: 130))
    record(
      "external-unplugged", dual, CGRect(x: 2400, y: 300, width: 720, height: 130),
      decodeWith: single)
    return cases
  }
}

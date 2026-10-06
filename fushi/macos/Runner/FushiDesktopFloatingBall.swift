import Cocoa
import FlutterMacOS
import QuartzCore

// macOS 应用外悬浮球（docs/specs/2026-09-30-desktop-system-floating-ball.md）。
//
// 分工：Dart 持有配置、位置持久化与全部动作的执行；这里只画球与按钮列、做拖动 /
// 吸附 / 展开动画，并把「点了哪颗、球在哪」经 `app.fushi.reader/floating_ball`
// 报回 Dart。原生侧不执行任何查词逻辑。
//
// 形态与 Android FloatingBallService（BUG-2793 之后）一致：
// - 球窗固定大小（球 + 阴影边），展开 / 收起只挪窗口；
// - 按钮窗在展开前就按**最终几何**一次布好（按钮全透明），之后只做动画——不会
//   出现「窗口先变大、下一帧才挪位」的闪动。
//
// 坐标：几何全部在「左上原点、y 向下」的 pt 空间里算（与 GlobalLookupOverlay.swift
// 的 top-left domain 同一约定：以主屏高度翻转 AppKit 的左下原点）；通道里的 anchor
// 是这个空间 × 球所在屏幕的 backingScaleFactor = 物理像素、左上原点。
//
// 不抢前台：NSPanel `.nonactivatingPanel` + canBecomeKey/Main = false + 视图
// acceptsFirstMouse = true。点球 / 点按钮都不激活 Fushi，否则「查前台程序选中的
// 文字」就取不到别的 app 的选区了。

private let kDesktopFloatingBallChannel = "app.fushi.reader/floating_ball"

// 按钮 id（与 Dart / Android 同名）。
private let kFloatingBallActionClose = "close"
private let kFloatingBallActionOpenApp = "open_app"
private let kFloatingBallLabelBall = "ball"

/// 球窗在球四周留给阴影的边（pt）。
private let kFloatingBallShadowPad: CGFloat = 10
/// 按钮四周留给阴影的边（pt）。
private let kFloatingBallButtonShadowPad: CGFloat = 6
/// 按钮图标边长（pt）。
private let kFloatingBallIconSize: CGFloat = 22

private let kFloatingBallExpandDuration: CFTimeInterval = 0.28
private let kFloatingBallCollapseDuration: CFTimeInterval = 0.19
private let kFloatingBallSnapDuration: CFTimeInterval = 0.22
/// 拖动阈值（pt）：越过它才算拖动，否则是点击。
private let kFloatingBallDragThreshold: CGFloat = 4

// MARK: - 几何（与 Android FloatingBallGeometry.java / Dart ReaderFloatingBallLayout 同一套公式）

/// 纯计算。坐标系：左上原点、y 向下的全局 pt 空间；`viewport` 是球所在屏幕的工作区
/// （visibleFrame，扣掉菜单栏与 Dock），`minY` 是上边、`maxY` 是下边。
struct DesktopFloatingBallGeometry {
  static let ballSize: CGFloat = 48
  static let buttonSize: CGFloat = 40
  static let gapSize: CGFloat = 6
  static let marginSize: CGFloat = 8
  /// 收起时缩进停靠边外的比例（Dart tuck = ballSize * 0.34）。
  static let tuckRatio: CGFloat = 0.34
  /// 收起态不透明度（Dart kReaderFloatingBallIdleOpacity）。
  static let idleOpacity: CGFloat = 0.42

  let viewport: CGRect
  let dockLeft: Bool
  let verticalFraction: CGFloat
  let actionCount: Int
  /// 停靠边外侧紧挨着另一块显示器时为 false：tuck 取 0，不把球塞进邻屏。
  let allowTuck: Bool

  var ball: CGFloat { return DesktopFloatingBallGeometry.ballSize }
  var button: CGFloat { return DesktopFloatingBallGeometry.buttonSize }
  var gap: CGFloat { return DesktopFloatingBallGeometry.gapSize }
  var margin: CGFloat { return DesktopFloatingBallGeometry.marginSize }

  var tuck: CGFloat {
    return allowTuck ? (ball * DesktopFloatingBallGeometry.tuckRatio).rounded() : 0
  }

  /// 相邻两颗按钮中心的竖向间距，也是相邻两列的横向间距。
  var pitch: CGFloat { return button + gap }

  /// 每列最多几颗：视口扣掉上下 margin 与球后，球顶以上还能放几个 pitch（至少 1）。
  var perColumn: Int {
    let available = viewport.height - 2 * margin - ball
    if available < pitch { return 1 }
    return max(1, Int(floor(available / pitch)))
  }

  /// 最高一列的颗数（= 第一列）。
  var rowCount: Int { return min(max(0, actionCount), perColumn) }

  /// 新列朝屏幕中央展开：左停靠往右 +1，右停靠往左 -1。
  var columnDirection: CGFloat { return dockLeft ? 1 : -1 }

  /// 第 index 颗按钮中心相对球心的偏移（展开态）：列表末颗离球最近、紧贴球顶，
  /// 先自下而上填满第一列，再往中央方向换列（各列底对齐）。
  func buttonOffset(_ index: Int) -> CGPoint {
    let slot = actionCount - 1 - index
    let per = perColumn
    let column = slot / per
    let row = slot % per
    let nearest = ball / 2 + gap + button / 2
    return CGPoint(
      x: columnDirection * CGFloat(column) * pitch,
      y: -(nearest + CGFloat(row) * pitch))
  }

  /// 展开态按钮区从球心向上伸出的距离（到最高一颗的上缘）。
  var reach: CGFloat {
    return actionCount <= 0 ? 0 : ball / 2 + CGFloat(rowCount) * pitch
  }

  var minTop: CGFloat { return viewport.minY + margin }

  var maxTop: CGFloat { return max(minTop, viewport.maxY - ball - margin) }

  /// 收起态球顶 y（比例落在活动范围内）。
  var ballTop: CGFloat {
    let f = verticalFraction.isNaN ? 0.5 : max(0, min(1, verticalFraction))
    return (minTop + (maxTop - minTop) * f).rounded()
  }

  /// 展开态球顶 y：最高一列要放得进视口，放不下把球沿边往下滑。
  var expandedBallTop: CGFloat {
    let lo = viewport.minY + margin + reach - ball / 2
    let hi = maxTop
    if hi < lo { return hi }
    return max(lo, min(hi, ballTop))
  }

  /// 收起态球左 x：停靠边外缩 tuck。
  var collapsedBallLeft: CGFloat {
    return dockLeft ? viewport.minX - tuck : viewport.maxX - ball + tuck
  }

  /// 展开态球左 x：整球回到视口内、贴边留 margin。
  var expandedBallLeft: CGFloat {
    return dockLeft ? viewport.minX + margin : viewport.maxX - ball - margin
  }

  /// 任意球顶 y 反算持久化比例。
  func fractionForTop(_ top: CGFloat) -> CGFloat {
    let span = maxTop - minTop
    if span <= 0 { return 0.5 }
    return max(0, min(1, (top - minTop) / span))
  }

  /// 松手时按球心落在视口左右哪一半决定停靠边。
  func dockLeftForBallLeft(_ ballLeft: CGFloat) -> Bool {
    return ballLeft + ball / 2 < viewport.midX
  }
}

// MARK: - 曲线

enum DesktopFloatingBallEasing {
  /// CSS / Flutter Cubic(x1, y1, x2, y2)：按 x 二分求参数 s，再取 y(s)。
  static func cubic(
    _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat
  ) -> CGFloat {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    func bx(_ s: CGFloat) -> CGFloat {
      return 3 * (1 - s) * (1 - s) * s * x1 + 3 * (1 - s) * s * s * x2 + s * s * s
    }
    func by(_ s: CGFloat) -> CGFloat {
      return 3 * (1 - s) * (1 - s) * s * y1 + 3 * (1 - s) * s * s * y2 + s * s * s
    }
    var lo: CGFloat = 0
    var hi: CGFloat = 1
    for _ in 0..<28 {
      let mid = (lo + hi) / 2
      if bx(mid) < x { lo = mid } else { hi = mid }
    }
    return by((lo + hi) / 2)
  }

  /// Flutter Curves.easeOutBack = Cubic(0.175, 0.885, 0.32, 1.275)。
  static func easeOutBack(_ x: CGFloat) -> CGFloat {
    return cubic(0.175, 0.885, 0.32, 1.275, x)
  }

  /// Flutter Curves.easeOutCubic = Cubic(0.215, 0.61, 0.355, 1)。
  static func easeOutCubic(_ x: CGFloat) -> CGFloat {
    return cubic(0.215, 0.61, 0.355, 1, x)
  }
}

// MARK: - 颜色

/// 非预乘 sRGB 分量。插值 / 叠色与 Android 的逐通道 lerpColor / alphaBlend 同口径。
struct DesktopFloatingBallColor {
  var r: CGFloat
  var g: CGFloat
  var b: CGFloat
  var a: CGFloat

  init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }

  init(argb: UInt32) {
    a = CGFloat((argb >> 24) & 0xFF) / 255
    r = CGFloat((argb >> 16) & 0xFF) / 255
    g = CGFloat((argb >> 8) & 0xFF) / 255
    b = CGFloat(argb & 0xFF) / 255
  }

  func withAlpha(_ factor: CGFloat) -> DesktopFloatingBallColor {
    return DesktopFloatingBallColor(r: r, g: g, b: b, a: a * factor)
  }

  func lerp(to other: DesktopFloatingBallColor, _ t: CGFloat) -> DesktopFloatingBallColor {
    return DesktopFloatingBallColor(
      r: r + (other.r - r) * t, g: g + (other.g - g) * t,
      b: b + (other.b - b) * t, a: a + (other.a - a) * t)
  }

  /// 自己按自身 alpha 叠在 `background` 上（Color.alphaBlend）。
  func over(_ background: DesktopFloatingBallColor) -> DesktopFloatingBallColor {
    return DesktopFloatingBallColor(
      r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a),
      b: b * a + background.b * (1 - a), a: background.a)
  }

  var cgColor: CGColor {
    return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
  }
}

// MARK: - 窗口与视图

/// 无边框、不激活、永不成为 key / main 的面板。
final class DesktopFloatingBallPanel: NSPanel {
  override var canBecomeKey: Bool { return false }
  override var canBecomeMain: Bool { return false }
}

/// 球：圆形裁切的 Fushi 图标 + 描边环 + 随 t 加深的阴影。不透明度由面板
/// alphaValue 管（连阴影一起淡）。
final class DesktopFloatingBallView: NSView {
  weak var controller: DesktopFloatingBallController?
  var image: CGImage? { didSet { needsDisplay = true } }
  var progress: CGFloat = 0 { didSet { needsDisplay = true } }
  var surface = DesktopFloatingBallColor(argb: 0xFFFF_FFFF) { didSet { needsDisplay = true } }
  var onSurface = DesktopFloatingBallColor(argb: 0xFF1C_1B1F) { didSet { needsDisplay = true } }
  var primary = DesktopFloatingBallColor(argb: 0xFF67_50A4) { didSet { needsDisplay = true } }

  override var isOpaque: Bool { return false }
  override var mouseDownCanMoveWindow: Bool { return false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  private var ballRect: CGRect {
    let d = DesktopFloatingBallGeometry.ballSize
    return CGRect(
      x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
  }

  /// 只有圆内算命中（四周阴影边不吃点击）。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden else { return nil }
    let local = convert(point, from: superview)
    let rect = ballRect
    let dx = local.x - rect.midX
    let dy = local.y - rect.midY
    return dx * dx + dy * dy <= (rect.width / 2) * (rect.width / 2) ? self : nil
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let t = max(0, min(1, progress))
    let rect = ballRect
    // 阴影（应用内 elevation 1 → 6 随 t 加深）：先画一个实心圆投影。
    ctx.saveGState()
    ctx.setShadow(
      offset: CGSize(width: 0, height: -(1 + 2 * t)), blur: 2 + 6 * t,
      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18 + 0.14 * t))
    ctx.setFillColor(surface.cgColor)
    ctx.fillEllipse(in: rect)
    ctx.restoreGState()
    // 球面（BoxFit.cover：解码时已裁成中心正方形）。
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    if let image = image {
      ctx.interpolationQuality = .high
      ctx.draw(image, in: rect)
    } else {
      ctx.setFillColor(primary.cgColor)
      ctx.fill(rect)
    }
    ctx.restoreGState()
    // 描边环：收起态细的 onSurface@35%，随 t 换成主题色粗环。
    let stroke = 1 + 1.5 * t
    ctx.setStrokeColor(onSurface.withAlpha(0.35).lerp(to: primary, t).cgColor)
    ctx.setLineWidth(stroke)
    ctx.strokeEllipse(in: rect.insetBy(dx: stroke / 2, dy: stroke / 2))
  }

  override func mouseDown(with event: NSEvent) {
    controller?.ballMouseDown()
  }

  override func mouseDragged(with event: NSEvent) {
    controller?.ballMouseDragged()
  }

  override func mouseUp(with event: NSEvent) {
    controller?.ballMouseUp()
  }
}

/// 按钮列的容器：翻转坐标（左上原点）方便按几何摆子视图；自己不吃点击。
final class DesktopFloatingBallMenuView: NSView {
  override var isFlipped: Bool { return true }
  override var isOpaque: Bool { return false }
  override var mouseDownCanMoveWindow: Bool { return false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self ? nil : hit
  }
}

/// 一颗圆形按钮：surface 上叠 6% onSurface 的底 + 轻阴影 + 居中 22pt 图标；悬停 /
/// 按下叠 onSurface 8% / 12%。视图按「按钮 + 阴影边」的名义尺寸画，动画缩放时
/// 整体按 bounds 比例缩。
final class DesktopFloatingBallButtonView: NSView {
  static var nominalSide: CGFloat {
    return DesktopFloatingBallGeometry.buttonSize + 2 * kFloatingBallButtonShadowPad
  }

  let actionId: String
  weak var controller: DesktopFloatingBallController?
  private let icon: NSImage?
  private let fallbackGlyph: String
  private let surface: DesktopFloatingBallColor
  private let onSurface: DesktopFloatingBallColor
  private var trackingArea: NSTrackingArea?
  private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
  private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

  init(
    actionId: String, label: String, icon: NSImage?,
    surface: DesktopFloatingBallColor, onSurface: DesktopFloatingBallColor
  ) {
    self.actionId = actionId
    self.icon = icon
    self.surface = surface
    self.onSurface = onSurface
    // 没有图标：退化成文案首字，至少认得出（同 Android）。
    self.fallbackGlyph = label.isEmpty ? "?" : String(label.prefix(1))
    let side = DesktopFloatingBallButtonView.nominalSide
    super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
    wantsLayer = true
    toolTip = label
    setAccessibilityLabel(label)
    setAccessibilityRole(.button)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var isOpaque: Bool { return false }
  override var mouseDownCanMoveWindow: Bool { return false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  private var circleRadius: CGFloat {
    return bounds.width / 2 * DesktopFloatingBallGeometry.buttonSize
      / DesktopFloatingBallButtonView.nominalSide
  }

  private func contains(local: NSPoint) -> Bool {
    let dx = local.x - bounds.midX
    let dy = local.y - bounds.midY
    let r = circleRadius
    return dx * dx + dy * dy <= r * r
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0.01 else { return nil }
    let local = convert(point, from: superview)
    return contains(local: local) ? self : nil
  }

  override func updateTrackingAreas() {
    if let area = trackingArea {
      removeTrackingArea(area)
    }
    // activeAlways：Fushi 不在前台时（这正是应用外球的常态）也要有悬停反馈。
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    pressed = false
  }

  override func mouseDown(with event: NSEvent) {
    pressed = true
  }

  override func mouseDragged(with event: NSEvent) {
    pressed = contains(local: convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let inside = contains(local: convert(event.locationInWindow, from: nil))
    pressed = false
    if inside {
      controller?.buttonTapped(actionId)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let nominal = DesktopFloatingBallButtonView.nominalSide
    let unit = bounds.width / nominal
    guard unit > 0 else { return }
    let pad = kFloatingBallButtonShadowPad
    let button = DesktopFloatingBallGeometry.buttonSize
    ctx.saveGState()
    ctx.scaleBy(x: unit, y: unit)
    let circle = CGRect(x: pad, y: pad, width: button, height: button)
    // 底色 + 轻阴影（≈ elevation 2）。阴影偏移不受 CTM 影响，手动乘缩放。
    ctx.saveGState()
    ctx.setShadow(
      offset: CGSize(width: 0, height: -1 * unit), blur: 3 * unit,
      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24))
    ctx.setFillColor(onSurface.withAlpha(0.06).over(surface).cgColor)
    ctx.fillEllipse(in: circle)
    ctx.restoreGState()
    if pressed || hovered {
      ctx.setFillColor(onSurface.withAlpha(pressed ? 0.12 : 0.08).cgColor)
      ctx.fillEllipse(in: circle)
    }
    let iconSize = kFloatingBallIconSize
    let iconRect = CGRect(
      x: pad + (button - iconSize) / 2, y: pad + (button - iconSize) / 2,
      width: iconSize, height: iconSize)
    if let icon = icon {
      icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    } else {
      let color = NSColor(cgColor: onSurface.cgColor) ?? NSColor.labelColor
      let text = NSAttributedString(
        string: fallbackGlyph,
        attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: color])
      let size = text.size()
      text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
    }
    ctx.restoreGState()
  }
}

// MARK: - 控制器

/// `app.fushi.reader/floating_ball` 的 macOS 实现。只在主线程使用。
final class DesktopFloatingBallController: NSObject {
  private struct ExpandAnimation {
    let from: CGFloat
    let to: CGFloat
    let start: CFTimeInterval
    let duration: CFTimeInterval
  }

  private struct SnapAnimation {
    let from: CGPoint
    let to: CGPoint
    let start: CFTimeInterval
  }

  private let channel: FlutterMethodChannel

  // 配置（Dart 下发）。
  private var actions: [String] = []
  private var labels: [String: String] = [:]
  private var icons: [String: NSImage] = [:]
  private var ballImage: CGImage?
  private var surface = DesktopFloatingBallColor(argb: 0xFFFF_FFFF)
  private var onSurface = DesktopFloatingBallColor(argb: 0xFF1C_1B1F)
  private var primary = DesktopFloatingBallColor(argb: 0xFF67_50A4)

  // 位置：停靠边 + 纵向比例 + 所在屏幕（本进程内记忆；缺省主屏）。
  private var dockLeft = false
  private var fraction: CGFloat = 0.5
  private var screenNumber: NSNumber?

  // 窗口。
  private var ballPanel: DesktopFloatingBallPanel?
  private var ballView: DesktopFloatingBallView?
  private var menuPanel: DesktopFloatingBallPanel?
  private var menuButtons: [DesktopFloatingBallButtonView] = []
  /// 按钮落点中心与展开态球心，均为菜单视图（翻转）局部坐标。
  private var menuButtonCenters: [CGPoint] = []
  private var menuBallCenter: CGPoint = .zero

  // 动画。
  private var progress: CGFloat = 0
  private var expandTarget = false
  private var expandAnimation: ExpandAnimation?
  private var snapAnimation: SnapAnimation?
  private var timer: Timer?

  // 拖动（全局左上原点 pt）。
  private var mouseDownPoint: CGPoint?
  private var dragging = false
  private var dragStart: CGPoint = .zero
  private var dragBall: CGPoint = .zero
  private var dragScreen: NSScreen?

  private var screenObserver: NSObjectProtocol?

  // 截屏识字（FushiDesktopScreenOcr.swift）：冻结层、会话代数（stop / 新一次 start
  // 之后到达的旧截图一律作废）、球是否因截屏被藏起。
  private var screenOcrOverlay: DesktopScreenOcrOverlay?
  private var screenOcrGeneration = 0
  private var screenOcrBallHidden = false

  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: kDesktopFloatingBallChannel, binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startSystemBall":
      // 回真实结果（面板是否在），与 Windows 同一契约。
      result(start(call.arguments as? [String: Any] ?? [:]))
    case "stopSystemBall":
      destroy()
      result(nil)
    case "isSystemBallRunning":
      result(ballPanel != nil)
    case "setAppForeground":
      // 桌面上应用内外两颗球共存，不因主窗前后台让位。
      result(nil)
    case "takeSystemBallClosedByUser":
      // 关闭即时推给 Dart（进程就是 app），没有需要补取的持久标记。
      result(false)
    case "startScreenOcrCapture":
      startScreenOcrCapture(call.arguments as? [String: Any] ?? [:], result: result)
    case "updateScreenOcrOverlay":
      updateScreenOcrOverlay(call.arguments as? [String: Any] ?? [:])
      result(nil)
    case "stopScreenOcr":
      // Dart 主动关：不回调。
      endScreenOcr(restoreBall: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: 生命周期

  @discardableResult
  private func start(_ args: [String: Any]) -> Bool {
    actions = (args["actions"] as? [String]) ?? []
    labels = (args["labels"] as? [String: String]) ?? [:]
    var decodedIcons: [String: NSImage] = [:]
    if let raw = args["iconImages"] as? [String: Any] {
      for (id, value) in raw {
        if let bytes = value as? FlutterStandardTypedData, let image = NSImage(data: bytes.data) {
          decodedIcons[id] = image
        }
      }
    }
    icons = decodedIcons
    if let bytes = args["ballImage"] as? FlutterStandardTypedData {
      ballImage = DesktopFloatingBallController.decodeBallImage(bytes.data)
    }
    if let colors = args["colors"] as? [String: Any] {
      func color(_ key: String) -> DesktopFloatingBallColor? {
        guard let n = colors[key] as? NSNumber else { return nil }
        return DesktopFloatingBallColor(argb: UInt32(truncatingIfNeeded: n.int64Value))
      }
      surface = color("surface") ?? surface
      onSurface = color("onSurface") ?? onSurface
      primary = color("primary") ?? primary
    }

    if ballPanel == nil {
      dockLeft = (args["dock"] as? String) == "left"
      let f = (args["fraction"] as? NSNumber)?.doubleValue ?? 0.5
      fraction = f.isNaN ? 0.5 : CGFloat(max(0, min(1, f)))
      createBallPanel()
    } else {
      // 已运行：原地换按钮 / 配色 / 图片，不挪位置；收起菜单（下次展开按新按钮重建）。
      collapseImmediately()
      applyBallAppearance()
    }
    return ballPanel != nil
  }

  /// 销毁全部窗口（stopSystemBall / 用户点关闭 / app 退出）。
  func destroy() {
    // 冻结层随球一起拆（不回调、不恢复——球马上也没了）。
    endScreenOcr(restoreBall: false)
    screenOcrBallHidden = false
    stopTimer()
    expandAnimation = nil
    snapAnimation = nil
    expandTarget = false
    progress = 0
    dragging = false
    mouseDownPoint = nil
    dragScreen = nil
    removeMenuPanel()
    if let panel = ballPanel {
      panel.orderOut(nil)
      panel.close()
    }
    ballPanel = nil
    ballView = nil
    if let observer = screenObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    screenObserver = nil
  }

  private static func makePanel(title: String) -> DesktopFloatingBallPanel {
    let panel = DesktopFloatingBallPanel(
      contentRect: NSRect(x: -32000, y: -32000, width: 1, height: 1),
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
    // 应用外球的常态就是 Fushi 不在前台：tooltip 也得照常出。
    panel.allowsToolTipsWhenApplicationIsInactive = true
    panel.title = title
    return panel
  }

  private func createBallPanel() {
    let side = DesktopFloatingBallGeometry.ballSize + 2 * kFloatingBallShadowPad
    let panel = DesktopFloatingBallController.makePanel(title: "Fushi Floating Ball")
    let view = DesktopFloatingBallView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.controller = self
    view.wantsLayer = true
    panel.contentView = view
    ballPanel = panel
    ballView = view
    applyBallAppearance()
    progress = 0
    expandTarget = false
    setProgress(0)
    panel.orderFrontRegardless()

    if screenObserver == nil {
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.relayoutForScreenChange()
      }
    }
  }

  private func applyBallAppearance() {
    guard let view = ballView else { return }
    view.image = ballImage
    view.surface = surface
    view.onSurface = onSurface
    view.primary = primary
    let label = labels[kFloatingBallLabelBall] ?? "Fushi"
    view.toolTip = label
    view.setAccessibilityLabel(label)
  }

  /// 球面 PNG → 取中心正方形（BoxFit.cover）并缩到 192px（48pt × 4），避免每帧
  /// 从 1024² 原图重采样。
  private static func decodeBallImage(_ data: Data) -> CGImage? {
    guard let image = NSImage(data: data),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let side = min(cg.width, cg.height)
    guard side > 0,
      let square = cg.cropping(
        to: CGRect(
          x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side))
    else { return nil }
    let target = min(side, 192)
    guard
      let ctx = CGContext(
        data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return square }
    ctx.interpolationQuality = .high
    ctx.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
    return ctx.makeImage() ?? square
  }

  // MARK: 坐标（左上原点 pt ↔ AppKit 左下原点，同 GlobalLookupOverlay.swift）

  private static var primaryScreenHeight: CGFloat {
    return NSScreen.screens.first?.frame.maxY ?? 0
  }

  /// 左上原点 pt 矩形 → AppKit 窗口 frame。
  private static func appKitRect(_ topLeftRect: CGRect) -> NSRect {
    return NSRect(
      x: topLeftRect.minX, y: primaryScreenHeight - topLeftRect.maxY,
      width: topLeftRect.width, height: topLeftRect.height)
  }

  /// 屏幕工作区（扣掉菜单栏与 Dock）→ 左上原点 pt。
  private static func workArea(of screen: NSScreen) -> CGRect {
    let vf = screen.visibleFrame
    return CGRect(
      x: vf.minX, y: primaryScreenHeight - vf.maxY, width: vf.width, height: vf.height)
  }

  private static func mouseTopLeft() -> CGPoint {
    let loc = NSEvent.mouseLocation
    return CGPoint(x: loc.x, y: primaryScreenHeight - loc.y)
  }

  private static func screen(atTopLeft p: CGPoint) -> NSScreen? {
    let appKit = NSPoint(x: p.x, y: primaryScreenHeight - p.y)
    return NSScreen.screens.first { NSMouseInRect(appKit, $0.frame, false) }
  }

  private static func number(of screen: NSScreen) -> NSNumber? {
    return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  }

  /// 球所在的屏幕：记住的那块还在就用它，否则回主屏。
  private func currentScreen() -> NSScreen? {
    if let wanted = screenNumber,
      let match = NSScreen.screens.first(where: {
        DesktopFloatingBallController.number(of: $0) == wanted
      })
    {
      return match
    }
    return NSScreen.screens.first ?? NSScreen.main
  }

  /// 停靠边外侧紧挨着另一块显示器时不外缩（不把球塞进邻屏）。
  private static func hasNeighbor(beyond screen: NSScreen, dockLeft: Bool) -> Bool {
    let vf = screen.visibleFrame
    let strip = dockLeft
      ? NSRect(x: vf.minX - 2, y: vf.minY, width: 2, height: vf.height)
      : NSRect(x: vf.maxX, y: vf.minY, width: 2, height: vf.height)
    return NSScreen.screens.contains { $0 !== screen && $0.frame.intersects(strip) }
  }

  private var menuIds: [String] {
    // 固定的关闭 / 打开 Fushi 在最上（离球最远，防误触），用户勾选的动作在下。
    return [kFloatingBallActionClose, kFloatingBallActionOpenApp] + actions
  }

  private func geometry(on screen: NSScreen?, dockLeft: Bool) -> DesktopFloatingBallGeometry {
    let viewport: CGRect
    var allowTuck = true
    if let screen = screen {
      viewport = DesktopFloatingBallController.workArea(of: screen)
      allowTuck = !DesktopFloatingBallController.hasNeighbor(beyond: screen, dockLeft: dockLeft)
    } else {
      viewport = CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
    return DesktopFloatingBallGeometry(
      viewport: viewport, dockLeft: dockLeft, verticalFraction: fraction,
      actionCount: menuIds.count, allowTuck: allowTuck)
  }

  private func geometry() -> DesktopFloatingBallGeometry {
    return geometry(on: currentScreen(), dockLeft: dockLeft)
  }

  // MARK: 摆放

  private func moveBall(left: CGFloat, top: CGFloat) {
    guard let panel = ballPanel else { return }
    let pad = kFloatingBallShadowPad
    let side = DesktopFloatingBallGeometry.ballSize + 2 * pad
    let frame = DesktopFloatingBallController.appKitRect(
      CGRect(x: left - pad, y: top - pad, width: side, height: side))
    panel.setFrame(frame, display: true)
  }

  private func placeBall(_ t: CGFloat) {
    let g = geometry()
    moveBall(
      left: g.collapsedBallLeft + (g.expandedBallLeft - g.collapsedBallLeft) * t,
      top: g.ballTop + (g.expandedBallTop - g.ballTop) * t)
  }

  private func updateBallOpacity() {
    let idle = DesktopFloatingBallGeometry.idleOpacity
    ballPanel?.alphaValue = dragging ? 1 : idle + (1 - idle) * progress
  }

  private func setProgress(_ t: CGFloat) {
    progress = t
    placeBall(t)
    ballView?.progress = t
    updateBallOpacity()
    applyButtonProgress(t)
  }

  /// 按最终几何一次建好按钮窗（按钮全透明），之后只做动画。窗口范围把展开态的球
  /// 也包进去：按钮从球心飞出，起点不能被窗口边裁掉。
  private func ensureMenuPanel() {
    guard menuPanel == nil, let ballPanel = ballPanel else { return }
    let g = geometry()
    let ids = menuIds
    let ballCenter = CGPoint(
      x: g.expandedBallLeft + g.ball / 2, y: g.expandedBallTop + g.ball / 2)
    let half = DesktopFloatingBallButtonView.nominalSide / 2
    let ballHalf = g.ball / 2 + kFloatingBallShadowPad
    var bounds = CGRect(
      x: ballCenter.x - ballHalf, y: ballCenter.y - ballHalf,
      width: ballHalf * 2, height: ballHalf * 2)
    var centers: [CGPoint] = []
    for i in 0..<ids.count {
      let off = g.buttonOffset(i)
      let c = CGPoint(x: ballCenter.x + off.x, y: ballCenter.y + off.y)
      centers.append(c)
      bounds = bounds.union(CGRect(x: c.x - half, y: c.y - half, width: half * 2, height: half * 2))
    }
    // 按钮放大到 1.2 倍（easeOutBack 过冲）时也不被裁。
    bounds = bounds.insetBy(dx: -half * 0.25, dy: -half * 0.25).integral

    let panel = DesktopFloatingBallController.makePanel(title: "Fushi Floating Ball Menu")
    let root = DesktopFloatingBallMenuView(
      frame: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
    root.wantsLayer = true
    panel.contentView = root
    menuButtons = []
    menuButtonCenters = []
    for (i, id) in ids.enumerated() {
      let button = DesktopFloatingBallButtonView(
        actionId: id, label: label(for: id), icon: icons[id],
        surface: surface, onSurface: onSurface)
      button.controller = self
      root.addSubview(button)
      menuButtons.append(button)
      menuButtonCenters.append(
        CGPoint(x: centers[i].x - bounds.minX, y: centers[i].y - bounds.minY))
    }
    menuBallCenter = CGPoint(x: ballCenter.x - bounds.minX, y: ballCenter.y - bounds.minY)
    menuPanel = panel
    // 先定窗口尺寸（contentView 随窗口铺满），再按当前进度摆按钮，最后才上屏。
    panel.setFrame(DesktopFloatingBallController.appKitRect(bounds), display: false)
    applyButtonProgress(progress)
    panel.displayIfNeeded()
    // 按钮窗压在球窗下面：球始终在最上、点得到。
    panel.order(.below, relativeTo: ballPanel.windowNumber)
  }

  private func removeMenuPanel() {
    menuButtons = []
    menuButtonCenters = []
    if let panel = menuPanel {
      panel.orderOut(nil)
      panel.close()
    }
    menuPanel = nil
  }

  /// 每颗按钮占总时长里错开的一段：离球越远起得越晚、尾部对齐，从球心飞到落点并
  /// 缩放淡入（应用内 _buildColumnButton 同一套区间与曲线）；收起沿同一区间反放。
  private func applyButtonProgress(_ t: CGFloat) {
    let n = menuButtons.count
    guard n > 0, menuButtonCenters.count == n else { return }
    let step: CGFloat = n <= 1 ? 0 : 0.35 / CGFloat(n - 1)
    let nominal = DesktopFloatingBallButtonView.nominalSide
    for i in 0..<n {
      let begin = CGFloat(n - 1 - i) * step
      let end = min(1, begin + 0.65)
      var raw: CGFloat = end > begin ? (t - begin) / (end - begin) : (t >= end ? 1 : 0)
      raw = max(0, min(1, raw))
      let k = DesktopFloatingBallEasing.easeOutBack(raw)
      let target = menuButtonCenters[i]
      let center = CGPoint(
        x: menuBallCenter.x + (target.x - menuBallCenter.x) * k,
        y: menuBallCenter.y + (target.y - menuBallCenter.y) * k)
      let scale = 0.4 + 0.6 * min(max(k, 0), 1.2)
      let side = nominal * scale
      let button = menuButtons[i]
      button.frame = NSRect(
        x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
      button.alphaValue = max(0, min(1, k))
      button.isHidden = k <= 0.001
      button.needsDisplay = true
    }
  }

  // MARK: 展开 / 收起

  private func setExpanded(_ expand: Bool) {
    guard expand != expandTarget, ballPanel != nil else { return }
    expandTarget = expand
    snapAnimation = nil
    if expand { ensureMenuPanel() }
    let target: CGFloat = expand ? 1 : 0
    let full = expand ? kFloatingBallExpandDuration : kFloatingBallCollapseDuration
    // 中途反向时按剩余路程缩短（与 AnimationController 反向同感）。
    let duration = max(0.001, full * CFTimeInterval(abs(target - progress)))
    expandAnimation = ExpandAnimation(
      from: progress, to: target, start: CACurrentMediaTime(), duration: duration)
    ensureTimer()
  }

  /// 收起到 t=0、不做动画（拖动开始 / 配置更新 / 屏幕变化）。
  private func collapseImmediately() {
    expandAnimation = nil
    snapAnimation = nil
    expandTarget = false
    removeMenuPanel()
    setProgress(0)
  }

  private func ensureTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      self?.tick()
    }
    // .common：拖动 / 菜单追踪等事件追踪模式下也要走帧。
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    let now = CACurrentMediaTime()
    var running = false
    if let a = expandAnimation {
      let f = CGFloat(min(1, max(0, (now - a.start) / a.duration)))
      if f >= 1 {
        expandAnimation = nil
        setProgress(a.to)
        if a.to == 0 { removeMenuPanel() }
      } else {
        setProgress(a.from + (a.to - a.from) * f)
        running = true
      }
    }
    if let s = snapAnimation {
      let raw = CGFloat(min(1, max(0, (now - s.start) / kFloatingBallSnapDuration)))
      let f = DesktopFloatingBallEasing.easeOutCubic(raw)
      moveBall(left: s.from.x + (s.to.x - s.from.x) * f, top: s.from.y + (s.to.y - s.from.y) * f)
      if raw >= 1 {
        snapAnimation = nil
      } else {
        running = true
      }
    }
    if !running { stopTimer() }
  }

  // MARK: 点击 / 拖动

  func ballMouseDown() {
    mouseDownPoint = DesktopFloatingBallController.mouseTopLeft()
    dragging = false
  }

  func ballMouseDragged() {
    guard let down = mouseDownPoint else { return }
    let p = DesktopFloatingBallController.mouseTopLeft()
    let dx = p.x - down.x
    let dy = p.y - down.y
    if !dragging {
      if abs(dx) <= kFloatingBallDragThreshold && abs(dy) <= kFloatingBallDragThreshold {
        return
      }
      beginDrag()
    }
    // 拖到另一块显示器就以那块的工作区为视口。
    let screen = DesktopFloatingBallController.screen(atTopLeft: p) ?? dragScreen ?? currentScreen()
    dragScreen = screen
    let left = geometry(on: screen, dockLeft: true)
    let right = geometry(on: screen, dockLeft: false)
    let vp = left.viewport
    let x = max(vp.minX - left.tuck, min(vp.maxX - right.ball + right.tuck, dragStart.x + dx))
    let y = max(left.minTop, min(left.maxTop, dragStart.y + dy))
    dragBall = CGPoint(x: x, y: y)
    moveBall(left: x, top: y)
  }

  func ballMouseUp() {
    if dragging {
      endDrag()
    } else if mouseDownPoint != nil {
      setExpanded(!expandTarget)
    }
    mouseDownPoint = nil
  }

  private func beginDrag() {
    // 先立即收起：按钮跟着球飞没有意义。
    collapseImmediately()
    dragging = true
    let g = geometry()
    dragStart = CGPoint(x: g.collapsedBallLeft, y: g.ballTop)
    dragBall = dragStart
    dragScreen = currentScreen()
    updateBallOpacity()
  }

  private func endDrag() {
    dragging = false
    let screen = dragScreen ?? currentScreen()
    dragScreen = nil
    if let screen = screen {
      screenNumber = DesktopFloatingBallController.number(of: screen)
    }
    let g = geometry(on: screen, dockLeft: dockLeft)
    dockLeft = g.dockLeftForBallLeft(dragBall.x)
    fraction = g.fractionForTop(dragBall.y)
    let settled = geometry()
    snapAnimation = SnapAnimation(
      from: dragBall, to: CGPoint(x: settled.collapsedBallLeft, y: settled.ballTop),
      start: CACurrentMediaTime())
    updateBallOpacity()
    ensureTimer()
    channel.invokeMethod(
      "systemBallPositionChanged",
      arguments: ["dock": dockLeft ? "left" : "right", "fraction": Double(fraction)])
  }

  func buttonTapped(_ id: String) {
    if id == kFloatingBallActionClose {
      // 原生先自行销毁窗口，再告诉 Dart 把「应用外显示」开关关掉。
      destroy()
      channel.invokeMethod("systemBallClosedByUser", arguments: nil)
      return
    }
    let anchor = ballAnchorPixels()
    setExpanded(false)
    channel.invokeMethod("systemBallAction", arguments: ["id": id, "anchor": anchor])
  }

  /// 球（收起后的落点）在屏幕上的矩形：物理像素、左上原点（与 global_lookup 通道
  /// 同一约定 = 左上原点 pt × 所在屏幕 backingScaleFactor）。
  private func ballAnchorPixels() -> [Double] {
    let g = geometry()
    let scale = Double(currentScreen()?.backingScaleFactor ?? 1)
    let left = Double(g.collapsedBallLeft)
    let top = Double(g.ballTop)
    let side = Double(g.ball)
    return [left * scale, top * scale, (left + side) * scale, (top + side) * scale]
  }

  private func label(for id: String) -> String {
    if let label = labels[id], !label.isEmpty { return label }
    switch id {
    case kFloatingBallActionClose: return "Close"
    case kFloatingBallActionOpenApp: return "Open Fushi"
    case "lookup": return "Look up"
    case "popup_lookup": return "App-external lookup"
    case "clipboard": return "Clipboard"
    case "sync": return "Sync now"
    default: return id
    }
  }

  // MARK: 截屏识字

  /// `startScreenOcrCapture`：选屏 → 查权限 → 藏球 → 截整块屏 → 立即盖冻结层。
  /// 失败（`permission_denied` / `capture_failed`）时球已恢复、不显示冻结层。
  private func startScreenOcrCapture(_ args: [String: Any], result: @escaping FlutterResult) {
    // 上一次还没结束（截图在途或冻结层还开着）：直接作废，不回调。
    endScreenOcr(restoreBall: false)
    screenOcrGeneration += 1
    let generation = screenOcrGeneration

    let anchor = (args["anchor"] as? [NSNumber])?.map { $0.doubleValue }
    guard let screen = DesktopScreenCapture.screen(forAnchor: anchor) else {
      restoreBallAfterScreenOcr()
      result(["error": "capture_failed"])
      return
    }
    // 没有「屏幕录制」权限：请求一次（首次弹系统框，之后只是把 Fushi 列进设置里），
    // 本次直接失败，由 Dart 唤起主窗提示。截不到别的 app 的窗口内容，强截没有意义。
    if !CGPreflightScreenCaptureAccess() {
      CGRequestScreenCaptureAccess()
      restoreBallAfterScreenOcr()
      result(["error": "permission_denied"])
      return
    }

    let labels = (args["labels"] as? [String: String]) ?? [:]
    var ocrPrimary = primary
    var ocrSurface = surface
    var ocrOnSurface = onSurface
    if let colors = args["colors"] as? [String: Any] {
      func color(_ key: String) -> DesktopFloatingBallColor? {
        guard let n = colors[key] as? NSNumber else { return nil }
        return DesktopFloatingBallColor(argb: UInt32(truncatingIfNeeded: n.int64Value))
      }
      ocrPrimary = color("primary") ?? ocrPrimary
      ocrSurface = color("surface") ?? ocrSurface
      ocrOnSurface = color("onSurface") ?? ocrOnSurface
    }

    // 藏球与按钮列（不销毁）：菜单直接收掉，球面板 orderOut。截图时再按 windowID
    // 排除球面板，双保险。
    collapseImmediately()
    var excluded: [Int] = []
    if let panel = ballPanel {
      excluded.append(panel.windowNumber)
      panel.orderOut(nil)
      screenOcrBallHidden = true
    }

    DesktopScreenCapture.capture(screen: screen, excludedWindowNumbers: excluded) {
      [weak self] outcome in
      guard let self = self, generation == self.screenOcrGeneration else {
        // 期间被 stopScreenOcr / stopSystemBall / 新一次 start 取代：球已由取代方处理。
        result(["error": "capture_failed"])
        return
      }
      let image: CGImage
      switch outcome {
      case .success(let captured):
        image = captured
      case .failure(let failure):
        self.restoreBallAfterScreenOcr()
        result(["error": failure == .permissionDenied ? "permission_denied" : "capture_failed"])
        return
      }
      guard let png = DesktopScreenCapture.pngData(image) else {
        self.restoreBallAfterScreenOcr()
        result(["error": "capture_failed"])
        return
      }
      let overlay = DesktopScreenOcrOverlay(
        screen: screen, image: image, labels: labels,
        primary: ocrPrimary, surface: ocrSurface, onSurface: ocrOnSurface,
        onTap: { [weak self] point in
          self?.channel.invokeMethod(
            "screenOcrTap", arguments: ["x": Double(point.x), "y": Double(point.y)])
        },
        onDismiss: { [weak self] in
          guard let self = self, self.screenOcrOverlay != nil else { return }
          self.endScreenOcr(restoreBall: true)
          self.channel.invokeMethod("screenOcrDismissed", arguments: nil)
        })
      self.screenOcrOverlay = overlay
      overlay.show()
      result([
        "png": FlutterStandardTypedData(bytes: png),
        "screen": DesktopScreenCapture.physicalRect(of: screen),
      ])
    }
  }

  /// `updateScreenOcrOverlay`：`lines` 为截图像素 [l, t, r, b]；`message` 为 null 时
  /// 显示 labels.hint。
  private func updateScreenOcrOverlay(_ args: [String: Any]) {
    guard let overlay = screenOcrOverlay else { return }
    var rects: [CGRect] = []
    for raw in (args["lines"] as? [Any]) ?? [] {
      guard let v = (raw as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), v.count == 4,
        v[2] > v[0], v[3] > v[1]
      else { continue }
      rects.append(CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]))
    }
    overlay.update(lines: rects, message: args["message"] as? String)
  }

  /// 结束本次截屏识字：作废在途截图、关冻结层，按需把球放回来。不回调 Dart。
  private func endScreenOcr(restoreBall: Bool) {
    screenOcrGeneration += 1
    if let overlay = screenOcrOverlay {
      screenOcrOverlay = nil
      overlay.close()
    }
    // restoreBall == false：要么马上重新截（球继续藏着），要么球正被销毁。
    if restoreBall { restoreBallAfterScreenOcr() }
  }

  private func restoreBallAfterScreenOcr() {
    guard screenOcrBallHidden else { return }
    screenOcrBallHidden = false
    guard let panel = ballPanel else { return }
    setProgress(0)
    panel.orderFrontRegardless()
  }

  /// 显示器配置 / 工作区 / 缩放变化：收起并按停靠边 + 比例在新视口重摆（位置永远
  /// 落在屏内）。球原来那块屏幕没了就回主屏。
  private func relayoutForScreenChange() {
    guard ballPanel != nil else { return }
    if let wanted = screenNumber,
      !NSScreen.screens.contains(where: {
        DesktopFloatingBallController.number(of: $0) == wanted
      })
    {
      screenNumber = nil
    }
    dragging = false
    mouseDownPoint = nil
    dragScreen = nil
    collapseImmediately()
  }
}

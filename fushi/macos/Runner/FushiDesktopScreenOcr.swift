import Cocoa
import ScreenCaptureKit

// macOS 应用外悬浮球的「截屏识字」原生侧（docs/specs/2026-09-30-desktop-system-floating-ball.md
// 「截屏识字（2026-10-04 补齐）」）：截一整块显示器 + 用这张截图盖满该显示器的冻结层
// （画行框、顶部提示条），把点击 / 退出报回 Dart。OCR、命中测试、查词全在 Dart。
//
// 坐标：通道里一律「物理像素、左上原点」——与球的 anchor 同一换算（左上原点 pt ×
// 该屏 backingScaleFactor）。`screen` 是该屏在这个空间里的矩形，`screenOcrTap` 的
// x / y 是截图像素坐标（相对该屏左上的物理像素），PNG 宽高 = 屏的像素宽高。
//
// 本文件只做截图与冻结层；何时藏 / 恢复球由 DesktopFloatingBallController 决定。

// MARK: - 截屏

enum DesktopScreenCapture {
  enum Failure: Error {
    case permissionDenied
    case captureFailed
  }

  /// 左上原点、y 向下的全局 pt 空间里，以主屏高度翻转 AppKit 左下原点（同
  /// GlobalLookupOverlay.swift / FushiDesktopFloatingBall.swift）。
  static var primaryScreenHeight: CGFloat {
    return NSScreen.screens.first?.frame.maxY ?? 0
  }

  static func displayId(of screen: NSScreen) -> CGDirectDisplayID? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
  }

  /// 屏幕整块（含菜单栏）在左上原点 pt 空间里的矩形。
  static func topLeftFrame(of screen: NSScreen) -> CGRect {
    let f = screen.frame
    return CGRect(x: f.minX, y: primaryScreenHeight - f.maxY, width: f.width, height: f.height)
  }

  /// 屏的像素宽高 = pt × backingScaleFactor（截图按这个尺寸出）。
  static func pixelSize(of screen: NSScreen) -> (Int, Int) {
    let s = screen.backingScaleFactor
    return (
      max(1, Int((screen.frame.width * s).rounded())),
      max(1, Int((screen.frame.height * s).rounded()))
    )
  }

  /// 该屏在「物理像素、左上原点、全局」空间里的矩形 [l, t, r, b]。
  static func physicalRect(of screen: NSScreen) -> [Double] {
    let tl = topLeftFrame(of: screen)
    let s = Double(screen.backingScaleFactor)
    return [
      Double(tl.minX) * s, Double(tl.minY) * s, Double(tl.maxX) * s, Double(tl.maxY) * s,
    ]
  }

  /// anchor（物理像素、左上原点）中心所在的屏。各屏 scale 可能不同，所以逐屏按
  /// 自己的 scale 还原成 pt 再判；没有命中（或没有 anchor）取鼠标所在屏。
  static func screen(forAnchor anchor: [Double]?) -> NSScreen? {
    if let a = anchor, a.count == 4 {
      let cx = (a[0] + a[2]) / 2
      let cy = (a[1] + a[3]) / 2
      for screen in NSScreen.screens {
        let s = Double(screen.backingScaleFactor)
        let p = CGPoint(x: cx / s, y: cy / s)
        if topLeftFrame(of: screen).contains(p) { return screen }
      }
    }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens.first
  }

  /// 截 `screen` 整块，排除 `excludedWindowNumbers`（球与按钮列面板）。结果在主线程
  /// 回调。调用前须已确认有屏幕录制权限。
  static func capture(
    screen: NSScreen, excludedWindowNumbers: [Int],
    completion: @escaping (Result<CGImage, Failure>) -> Void
  ) {
    guard let displayId = displayId(of: screen) else {
      completion(.failure(.captureFailed))
      return
    }
    let (width, height) = pixelSize(of: screen)
    if #available(macOS 14.0, *) {
      captureWithScreenCaptureKit(
        displayId: displayId, width: width, height: height,
        excluded: Set(excludedWindowNumbers.map { CGWindowID($0) }), completion: completion)
    } else {
      // 13.x：没有 SCScreenshotManager。球已 orderOut，但 WindowServer 要到下一次
      // 合成才把它从帧缓冲里拿掉（CGDisplayCreateImage 读的就是合成结果），所以等
      // 一个合成周期再截。
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard let image = legacyDisplayImage(displayId) else {
          completion(.failure(.captureFailed))
          return
        }
        completion(.success(normalized(image, width: width, height: height)))
      }
    }
  }

  /// CGDisplayCreateImage 在 SDK 里标为 14.4 弃用、15.0 废弃；部署目标 13.4 下可调，
  /// 只在 14 以下走到这里。
  @available(macOS, deprecated: 14.0)
  private static func legacyDisplayImage(_ displayId: CGDirectDisplayID) -> CGImage? {
    return CGDisplayCreateImage(displayId)
  }

  @available(macOS 14.0, *)
  private static func captureWithScreenCaptureKit(
    displayId: CGDirectDisplayID, width: Int, height: Int, excluded: Set<CGWindowID>,
    completion: @escaping (Result<CGImage, Failure>) -> Void
  ) {
    // onScreenWindowsOnly: false —— 球刚 orderOut，可能已不在屏上清单里；拿全量清单
    // 才能按 windowID 精确排除（排除不在屏上的窗口无害）。
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
      content, error in
      guard error == nil, let content = content,
        let display = content.displays.first(where: { $0.displayID == displayId })
      else {
        DispatchQueue.main.async { completion(.failure(.captureFailed)) }
        return
      }
      let windows = content.windows.filter { excluded.contains($0.windowID) }
      let filter = SCContentFilter(display: display, excludingWindows: windows)
      let config = SCStreamConfiguration()
      config.width = width
      config.height = height
      config.showsCursor = false
      config.captureResolution = .best
      SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
        image, error in
        DispatchQueue.main.async {
          guard error == nil, let image = image else {
            completion(.failure(.captureFailed))
            return
          }
          completion(.success(normalized(image, width: width, height: height)))
        }
      }
    }
  }

  /// 缩放模式（「看起来像 …」）下帧缓冲尺寸可能不等于 pt × scale：统一重采样到屏的
  /// 像素宽高，保证「PNG 宽高 = screen 宽高、点击像素 = 截图像素」。
  static func normalized(_ image: CGImage, width: Int, height: Int) -> CGImage {
    if image.width == width && image.height == height { return image }
    guard
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage() ?? image
  }

  static func pngData(_ image: CGImage) -> Data? {
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}

// MARK: - 冻结层

/// 盖满一块显示器的无边框面板。要收 Esc，所以能成为 key（不能成为 main）；
/// `.nonactivatingPanel` 让它成为 key 时不激活 Fushi 主窗。
final class DesktopScreenOcrPanel: NSPanel {
  override var canBecomeKey: Bool { return true }
  override var canBecomeMain: Bool { return false }
}

/// 截图 + 18% 黑压暗 + 行框 + 顶部提示条。翻转坐标（左上原点 pt）。
final class DesktopScreenOcrView: NSView {
  var onTap: ((CGPoint) -> Void)?
  var onDismiss: (() -> Void)?

  private let image: NSImage
  /// 截图像素 / 视图 pt。
  private let pixelScale: CGFloat
  private let primary: DesktopFloatingBallColor
  private let surface: DesktopFloatingBallColor
  private let onSurface: DesktopFloatingBallColor
  private let closeLabel: String
  /// 提示条离屏顶的距离：刘海屏要躲开刘海（safeAreaInsets.top）。
  private let topInset: CGFloat

  private var lines: [CGRect] = []
  private var text: String

  init(
    frame: NSRect, image: CGImage, primary: DesktopFloatingBallColor,
    surface: DesktopFloatingBallColor, onSurface: DesktopFloatingBallColor,
    text: String, closeLabel: String, topInset: CGFloat
  ) {
    self.image = NSImage(cgImage: image, size: frame.size)
    self.pixelScale = frame.width > 0 ? CGFloat(image.width) / frame.width : 1
    self.primary = primary
    self.surface = surface
    self.onSurface = onSurface
    self.text = text
    self.closeLabel = closeLabel
    self.topInset = topInset
    super.init(frame: frame)
    setAccessibilityRole(.group)
    refreshCloseToolTip()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var isFlipped: Bool { return true }
  override var isOpaque: Bool { return true }
  override var acceptsFirstResponder: Bool { return true }
  override var mouseDownCanMoveWindow: Bool { return false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

  /// `lines` 为截图像素坐标 [l, t, r, b]。
  func update(lines pixelLines: [CGRect], text: String) {
    lines = pixelLines.map {
      CGRect(
        x: $0.minX / pixelScale, y: $0.minY / pixelScale,
        width: $0.width / pixelScale, height: $0.height / pixelScale)
    }
    self.text = text
    refreshCloseToolTip()
    needsDisplay = true
  }

  // MARK: 绘制

  private static let barFont = NSFont.systemFont(ofSize: 14, weight: .medium)
  private static let barHeight: CGFloat = 36
  private static let barHPad: CGFloat = 16
  private static let closeSide: CGFloat = 24
  private static let closeGap: CGFloat = 10

  private func barLayout() -> (bar: CGRect, textOrigin: CGPoint, close: CGRect, string: NSAttributedString) {
    let fg = NSColor(cgColor: onSurface.cgColor) ?? .labelColor
    let string = NSAttributedString(
      string: text, attributes: [.font: DesktopScreenOcrView.barFont, .foregroundColor: fg])
    let maxText = max(40, bounds.width - 64 - 2 * DesktopScreenOcrView.barHPad
      - DesktopScreenOcrView.closeGap - DesktopScreenOcrView.closeSide)
    let textSize = string.size()
    let textW = min(ceil(textSize.width), maxText)
    let h = DesktopScreenOcrView.barHeight
    let w = DesktopScreenOcrView.barHPad + textW + DesktopScreenOcrView.closeGap
      + DesktopScreenOcrView.closeSide + (h - DesktopScreenOcrView.closeSide) / 2
    let bar = CGRect(x: ((bounds.width - w) / 2).rounded(), y: topInset + 12, width: w, height: h)
    let textOrigin = CGPoint(
      x: bar.minX + DesktopScreenOcrView.barHPad, y: bar.midY - textSize.height / 2)
    let side = DesktopScreenOcrView.closeSide
    let close = CGRect(
      x: bar.maxX - (h - side) / 2 - side, y: bar.midY - side / 2, width: side, height: side)
    return (bar, textOrigin, close, string)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    // 截图（NSImage 在翻转视图里按 respectFlipped 摆正）。
    image.draw(
      in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    // 压暗：提示这是定格画面。
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.fill(bounds)
    // 行框：primary 12% 填充 + 1.5pt 描边。
    if !lines.isEmpty {
      ctx.setFillColor(primary.withAlpha(0.12).cgColor)
      ctx.setStrokeColor(primary.cgColor)
      ctx.setLineWidth(1.5)
      for rect in lines {
        let r = rect.insetBy(dx: -2, dy: -2)
        let path = CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.strokePath()
      }
    }
    // 顶部居中提示条。
    let layout = barLayout()
    ctx.saveGState()
    ctx.setShadow(
      offset: CGSize(width: 0, height: 2), blur: 8,
      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(surface.cgColor)
    ctx.addPath(
      CGPath(
        roundedRect: layout.bar, cornerWidth: layout.bar.height / 2,
        cornerHeight: layout.bar.height / 2, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    let textRect = CGRect(
      x: layout.textOrigin.x, y: layout.textOrigin.y,
      width: layout.close.minX - DesktopScreenOcrView.closeGap - layout.textOrigin.x,
      height: layout.string.size().height)
    layout.string.draw(
      with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    // 关闭 ×：onSurface 8% 圆底 + 两笔。
    let c = layout.close
    ctx.setFillColor(onSurface.withAlpha(0.08).cgColor)
    ctx.fillEllipse(in: c)
    ctx.setStrokeColor(onSurface.cgColor)
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    let k: CGFloat = 4.5
    ctx.move(to: CGPoint(x: c.midX - k, y: c.midY - k))
    ctx.addLine(to: CGPoint(x: c.midX + k, y: c.midY + k))
    ctx.move(to: CGPoint(x: c.midX + k, y: c.midY - k))
    ctx.addLine(to: CGPoint(x: c.midX - k, y: c.midY + k))
    ctx.strokePath()
  }

  // MARK: 输入

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if barLayout().close.insetBy(dx: -4, dy: -4).contains(p) {
      onDismiss?()
      return
    }
    onTap?(CGPoint(x: p.x * pixelScale, y: p.y * pixelScale))
  }

  override func rightMouseDown(with event: NSEvent) {
    onDismiss?()
  }

  override func keyDown(with event: NSEvent) {
    // 53 = Esc。其它键吞掉（不给 super，免得系统提示音）。
    if event.keyCode == 53 { onDismiss?() }
  }

  override func cancelOperation(_ sender: Any?) {
    onDismiss?()
  }

  /// 关闭钮悬停提示 = labels.close。提示条宽度随文字变，所以文字一变就重挂。
  private func refreshCloseToolTip() {
    removeAllToolTips()
    addToolTip(barLayout().close, owner: closeLabel as NSString, userData: nil)
  }
}

/// 一次截屏识字的冻结层：建面板、显示、更新、拆除。只在主线程使用。
final class DesktopScreenOcrOverlay {
  private let panel: DesktopScreenOcrPanel
  private let view: DesktopScreenOcrView
  private let hint: String

  init(
    screen: NSScreen, image: CGImage, labels: [String: String],
    primary: DesktopFloatingBallColor, surface: DesktopFloatingBallColor,
    onSurface: DesktopFloatingBallColor,
    onTap: @escaping (CGPoint) -> Void, onDismiss: @escaping () -> Void
  ) {
    hint = labels["hint"] ?? ""
    let frame = screen.frame
    let panel = DesktopScreenOcrPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    // 盖住菜单栏（24）与 Dock（20），但在查词卡（.popUpMenu）之下。
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isMovable = false
    panel.isMovableByWindowBackground = false
    panel.isOpaque = true
    panel.backgroundColor = .black
    panel.hasShadow = false
    panel.animationBehavior = .none
    panel.title = "Fushi Screen OCR"
    let view = DesktopScreenOcrView(
      frame: NSRect(origin: .zero, size: frame.size), image: image, primary: primary,
      surface: surface, onSurface: onSurface,
      text: labels["recognizing"] ?? "", closeLabel: labels["close"] ?? "Close",
      topInset: screen.safeAreaInsets.top)
    view.onTap = onTap
    view.onDismiss = onDismiss
    view.setAccessibilityLabel(labels["hint"])
    panel.contentView = view
    panel.setFrame(frame, display: false)
    self.panel = panel
    self.view = view
  }

  func show() {
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)
  }

  /// `lines` 截图像素坐标；`message` 为 nil / 空时显示 hint。
  func update(lines: [CGRect], message: String?) {
    let text = (message?.isEmpty == false) ? message! : hint
    view.update(lines: lines, text: text)
  }

  func close() {
    view.onTap = nil
    view.onDismiss = nil
    panel.orderOut(nil)
    panel.close()
    // 关闭常发生在冻结层自己的 mouseDown / keyDown 里：把面板与视图留到这次事件
    // 分发结束后再释放，别在它们自己的栈帧里被析构。
    DispatchQueue.main.async { [panel, view] in
      _ = panel
      _ = view
    }
  }
}

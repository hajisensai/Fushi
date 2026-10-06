import Foundation

#if os(iOS)
import Flutter
import UIKit
#else
import AppKit
import FlutterMacOS
#endif

/// 原生系统材质平台视图（viewType `app.fushi/native_material`），iOS / macOS 共用。
///
/// 用途：app 内查词浮层的**真模糊背衬**。浮层内容是一个透明背景的 WKWebView
/// （popup.css `html.fushi-glass-host`），它背后的阅读器 / 视频 / 漫画正文本身也是
/// 原生平台视图——Flutter 的 BackdropFilter 与玻璃着色器都采不到。Dart 侧
/// （`fushi_native_material.dart` 的 `FushiNativeMaterialBackdrop`）把本视图放在
/// 弹窗 WebView 之下的 Stack 兄弟层：
///
/// - macOS：`NSVisualEffectView`，`blendingMode = .withinWindow`、`state = .active`。
///   within-window 混合由系统合成器在本窗口内采样背后的一切（阅读器 WKWebView 的
///   远程图层 + Flutter 的 IOSurface 图层）做模糊。
/// - iOS：`UIVisualEffectView`（`.systemThinMaterial` / `.systemMaterial`），同理。
///
/// 两端都**永不接收事件**（macOS `hitTest` 返回 nil；iOS `isUserInteractionEnabled =
/// false`），圆角在原生侧裁（Flutter 侧不能包 ClipRRect：clip mutator 给祖先挂的
/// layer mask 会让 backdrop 失去模糊）。可选 `tint`（ARGB）是叠在材质上的低 alpha
/// 色层（MD3 的主色淡染面板色）。
///
/// 创建参数（StandardMessageCodec 字典）：
/// `dark: Bool`、`cornerRadius: Double`、`continuousCorners: Bool`、`tint: Int?`。
enum FushiNativeMaterial {
  static let viewType = "app.fushi/native_material"

  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(FushiNativeMaterialFactory(), withId: viewType)
  }
}

struct FushiNativeMaterialParams {
  let dark: Bool
  let cornerRadius: CGFloat
  let continuousCorners: Bool
  /// 0xAARRGGBB；nil = 不叠色层。
  let tint: UInt32?

  init(_ arguments: Any?) {
    let map = arguments as? [String: Any] ?? [:]
    dark = map["dark"] as? Bool ?? false
    cornerRadius = CGFloat((map["cornerRadius"] as? NSNumber)?.doubleValue ?? 0)
    continuousCorners = map["continuousCorners"] as? Bool ?? false
    if let value = map["tint"] as? NSNumber {
      tint = UInt32(truncatingIfNeeded: value.int64Value)
    } else {
      tint = nil
    }
  }

  var tintComponents: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
    guard let tint else { return nil }
    return (
      CGFloat((tint >> 16) & 0xFF) / 255,
      CGFloat((tint >> 8) & 0xFF) / 255,
      CGFloat(tint & 0xFF) / 255,
      CGFloat((tint >> 24) & 0xFF) / 255
    )
  }
}

#if os(macOS)

final class FushiNativeMaterialFactory: NSObject, FlutterPlatformViewFactory {
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    return FushiNativeMaterialNSView(params: FushiNativeMaterialParams(args))
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// 透传事件的色层（`hitTest` 返回 nil）。
private final class FushiPassthroughLayerView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FushiNativeMaterialNSView: NSVisualEffectView {
  private let params: FushiNativeMaterialParams

  init(params: FushiNativeMaterialParams) {
    self.params = params
    super.init(frame: .zero)
    // 弹出面板的系统材质；明暗由 appearance 钉死跟随 app 主题（不跟系统外观）。
    material = params.dark ? .hudWindow : .popover
    blendingMode = .withinWindow
    state = .active
    isEmphasized = false
    appearance = NSAppearance(named: params.dark ? .darkAqua : .aqua)
    wantsLayer = true
    autoresizingMask = [.width, .height]
    if let c = params.tintComponents {
      let tintView = FushiPassthroughLayerView(frame: bounds)
      tintView.wantsLayer = true
      tintView.layer?.backgroundColor = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
      tintView.autoresizingMask = [.width, .height]
      addSubview(tintView)
    }
    applyCorners()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// 圆角：NSVisualEffectView 官方支持的裁形手段是 `maskImage`（可拉伸的圆角矩形
  /// 模板图，capInsets = 半径）；只设 layer.cornerRadius 时材质的 backdrop 层不一定跟着裁。
  /// 色层另按 layer 圆角裁。
  private func applyCorners() {
    let radius = max(0, params.cornerRadius)
    guard radius > 0 else { return }
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    maskImage = image
    for sub in subviews {
      sub.layer?.cornerRadius = radius
      if params.continuousCorners {
        sub.layer?.cornerCurve = .continuous
      }
      sub.layer?.masksToBounds = true
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var acceptsFirstResponder: Bool { false }
}

#else

final class FushiNativeMaterialFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return FushiNativeMaterialPlatformView(
      frame: frame, params: FushiNativeMaterialParams(args))
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

final class FushiNativeMaterialPlatformView: NSObject, FlutterPlatformView {
  private let effectView: UIVisualEffectView

  init(frame: CGRect, params: FushiNativeMaterialParams) {
    // 浅色用更通透的 thin，深色用标准 material（深色 thin 压在正文上偏灰脏）。
    let blur = UIBlurEffect(style: params.dark ? .systemMaterialDark : .systemThinMaterialLight)
    effectView = UIVisualEffectView(effect: blur)
    effectView.frame = frame
    effectView.isUserInteractionEnabled = false
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.overrideUserInterfaceStyle = params.dark ? .dark : .light
    effectView.layer.cornerRadius = max(0, params.cornerRadius)
    if params.continuousCorners {
      effectView.layer.cornerCurve = .continuous
    }
    effectView.clipsToBounds = true
    if let c = params.tintComponents {
      let tintView = UIView(frame: effectView.contentView.bounds)
      tintView.backgroundColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
      tintView.isUserInteractionEnabled = false
      tintView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      effectView.contentView.addSubview(tintView)
    }
    super.init()
  }

  func view() -> UIView {
    return effectView
  }
}

#endif

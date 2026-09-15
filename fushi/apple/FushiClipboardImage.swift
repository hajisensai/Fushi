import Foundation

#if os(iOS)
import Flutter
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
import FlutterMacOS
#endif

/// Apple 侧的「复制图片到剪贴板」：`app.fushi.reader/clipboard_image` 的 iOS / macOS 实现。
///
/// 这条通道原先只有 Windows 一端（`windows/runner/flutter_window.cpp` 的
/// `CopyImageFileToClipboard`，WIC 解码 → 32bpp BGRA → `SetClipboardData(CF_DIB)`），
/// 服务阅读器内联图与插画查看器的「复制图片」。视频截图要把它铺到五端，这里补 Apple 的
/// 那半边，**方法名与入参逐字对齐 Windows**：`copyImageFile` + `{"path": <本地路径>}`。
///
/// 两点与 Windows 的差异是平台决定的，不是随意选的：
///
/// 1. **不解码成位图，直接把原始字节按 UTI 贴上去**。AppKit / UIKit 的剪贴板本来就
///    认 PNG / JPEG 的原始表示，粘贴方要位图时由系统转；自己先解成 `NSImage` 再贴
///    反而会丢掉 alpha 与色彩配置。字节按文件扩展名判 UTI，判不出来时退到 PNG——
///    调用方（`clipboard_image.dart`）写的就是 PNG。
/// 2. **iOS 的 `UIPasteboard` 与 macOS 的 `NSPasteboard` 类型标识符不同**（`public.png`
///    两边同名，但取法一个来自 `UTType`、一个来自 `NSPasteboard.PasteboardType`），
///    所以两边各写各的，不硬凑一个共用分支。
///
/// 失败一律经 `FlutterError` 回到 Dart（`copyImageToClipboard` 会把原因显示出来）；
/// 绝不 `result(nil)` 装成功——静默假成功会让用户以为复制好了，粘贴时才发现是空的。
enum FushiClipboardImage {
  /// 与 Dart 的 `FushiChannels.clipboardImage`、Windows 的 channel 名同名。
  static let channelName = "app.fushi.reader/clipboard_image"

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "copyImageFile" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let path = args["path"] as? String,
      !path.isEmpty
    else {
      result(
        FlutterError(
          code: "INVALID_ARGUMENTS",
          message: "copyImageFile requires a non-empty 'path'",
          details: nil))
      return
    }

    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      result(
        FlutterError(
          code: "READ_FAILED",
          message: "Could not read \(path): \(error.localizedDescription)",
          details: nil))
      return
    }
    if data.isEmpty {
      result(
        FlutterError(
          code: "READ_FAILED", message: "Image file is empty: \(path)", details: nil))
      return
    }

    let isJpeg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())

    #if os(iOS)
      let type = isJpeg ? UTType.jpeg : UTType.png
      UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
      result(nil)
    #else
      let type: NSPasteboard.PasteboardType = isJpeg ? .init("public.jpeg") : .png
      let pasteboard = NSPasteboard.general
      // clearContents() 必须在 setData 之前：NSPasteboard 的写入是「先清空拿到所有权、
      // 再往这一代里放」，不清空 setData 会失败并返回 false。
      pasteboard.clearContents()
      if pasteboard.setData(data, forType: type) {
        result(nil)
      } else {
        result(
          FlutterError(
            code: "CLIPBOARD_FAILED",
            message: "NSPasteboard rejected the image data",
            details: nil))
      }
    #endif
  }
}

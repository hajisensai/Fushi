import Foundation
import ImageIO
import Vision

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Apple 侧的「系统自带 OCR」：`app.fushi.reader/system_ocr` 的 iOS / macOS 实现。
///
/// Dart 侧（`lib/src/ocr/system_ocr_channel.dart`）与 Android 侧（ML Kit，
/// `SystemOcrChannel.java`）早就在了，这里补的是 Apple 的那半边。模型是系统组件
/// （Vision 随 OS 走），所以「安装后不用下载模型也能用」在这两个平台上天然成立，
/// 一个字节都不上传。
///
/// **契约逐字对齐 Android 那份**，四条容易写错的：
///
/// 1. **坐标是送检图的绝对像素、原点左上**。Vision 给的 `boundingBox` 是归一化的
///    且原点在**左下**，所以 y 必须翻过来：`top = (1 - maxY) * H`。翻错不会报错，
///    只会让整页透明文字层错位——和「这页没字」在设备上看起来一样。
/// 2. **不发 `vertical`**。Vision 和 ML Kit 都不报竖排，Dart 侧按包围盒长宽比统一
///    推断（`parseSystemOcrPayload`）。这里发一个自己猜的值等于让同一件事有两套
///    判据，Android 侧的注释也是这么定的。
/// 3. **`width` / `height` 是解码后 CGImage 的像素尺寸**，与坐标同一个分母。用
///    `CGImageSource` 而不是 `UIImage`：后者会把 EXIF 方向应用进去，尺寸和坐标系
///    就和 Android 的 `BitmapFactory`（rotation 0，不应用 EXIF）对不上了。
/// 4. **语言不受支持要单独报 `MODEL_UNAVAILABLE`**，不能混进 `RECOGNIZE_FAILED`。
///    Dart 侧把前者转成 `SystemOcrUnavailableException`，调用方据此换引擎；报成后者
///    会让用户去怀疑图片。iOS 15 的 Vision 没有日语/中文/韩语（那是 iOS 16 起的
///    revision 3），走的正是这条路。
///
/// 部署目标（iOS 15.1 / macOS 13.4）高于 `VNRecognizeTextRequest`（iOS 13 / macOS
/// 10.15）与实例版 `supportedRecognitionLanguages()`（iOS 15 / macOS 12），所以全文
/// 不需要 `#available` 分支。
enum FushiSystemOcr {
  /// 与 Dart 的 `kSystemOcrChannel`、Android 的 `ChannelNames.SYSTEM_OCR` 同名。
  static let channelName = "app.fushi.reader/system_ocr"

  /// Vision 跑 `.accurate` 是几百毫秒级的活，不能占着主线程；回调统一切回主线程。
  private static let queue = DispatchQueue(
    label: "app.fushi.reader.system-ocr",
    qos: .userInitiated)

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      // 必须便宜地回答：不做真识别，也不触发任何下载（Dart 侧把这个答案缓存进
      // 一次能力探测）。查一次支持语言表就够了。
      result(!supportedLanguages().isEmpty)
    case "recognize":
      recognize(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - recognize

  private static func recognize(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let typed = args["bytes"] as? FlutterStandardTypedData,
          !typed.data.isEmpty
    else {
      result(
        FlutterError(
          code: "INVALID_IMAGE",
          message: "image bytes must not be empty",
          details: nil))
      return
    }
    let data = typed.data
    let language = (args["language"] as? String) ?? ""

    let supported = supportedLanguages()
    let languages = visionLanguages(for: language, supported: supported)
    if languages.isEmpty {
      // 这条不是「识别失败」：本机的 Vision 认不了这门语言（iOS 15 没有 CJK），
      // 调用方该换引擎而不是重试这张图。
      result(
        FlutterError(
          code: "MODEL_UNAVAILABLE",
          message:
            "Vision has no recognition model for \"\(language)\" on this system",
          details: nil))
      return
    }

    queue.async {
      func reply(_ value: Any?) {
        DispatchQueue.main.async { result(value) }
      }
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        reply(
          FlutterError(
            code: "INVALID_IMAGE",
            message: "could not decode image bytes",
            details: nil))
        return
      }
      let width = image.width
      let height = image.height
      guard width > 0, height > 0 else {
        reply(
          FlutterError(
            code: "INVALID_IMAGE",
            message: "decoded image has no size",
            details: nil))
        return
      }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.recognitionLanguages = languages
      // `.up` 而不是从 EXIF 推：上面用 CGImageSource 拿的就是未旋转的像素缓冲，
      // 坐标分母也是它的宽高，两处必须同一个方向。
      let handler = VNImageRequestHandler(
        cgImage: image,
        orientation: .up,
        options: [:])
      do {
        try handler.perform([request])
      } catch {
        reply(
          FlutterError(
            code: "RECOGNIZE_FAILED",
            message: error.localizedDescription,
            details: nil))
        return
      }
      reply(
        payload(
          observations: request.results ?? [],
          width: width,
          height: height))
    }
  }

  /// 把 Vision 的观测结果拼成 Dart 侧 `parseSystemOcrPayload` 认得的那份 map。
  ///
  /// 一个 observation 一行，不做任何分组——气泡合并在 Dart / JS 那边，Android 侧
  /// 同样如此，两边都拼一套只会拼出两种结果。
  static func payload(
    observations: [VNRecognizedTextObservation],
    width: Int,
    height: Int
  ) -> [String: Any] {
    let w = CGFloat(width)
    let h = CGFloat(height)
    var lines: [[String: Any]] = []
    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        continue
      }
      let box = observation.boundingBox
      let left = box.minX * w
      let right = box.maxX * w
      // Vision 的原点在左下，Dart / Android 的在左上：这里翻 y。
      let top = (1 - box.maxY) * h
      let bottom = (1 - box.minY) * h
      if right <= left || bottom <= top { continue }
      lines.append([
        "text": text,
        "left": Double(left),
        "top": Double(top),
        "right": Double(right),
        "bottom": Double(bottom),
        // 刻意不发 `vertical`：Vision 不报竖排，Dart 侧按包围盒推断（见类文档）。
      ])
    }
    return [
      "width": width,
      "height": height,
      "lines": lines,
    ]
  }

  // MARK: - 语言

  /// 本机 Vision 认得的语言（形如 `en-US` / `ja-JP` / `zh-Hans`）。查不到就当没有。
  static func supportedLanguages() -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    return (try? request.supportedRecognitionLanguages()) ?? []
  }

  /// 纯函数：把 Dart 传来的**主子标签**（`ja` / `zh` / `en`…）配到本机支持的
  /// Vision 语言标识上。
  ///
  /// 按主子标签前缀配，所以 `zh` 会同时拿到 `zh-Hans` 与 `zh-Hant`（简繁漫画都有，
  /// 两个都给 Vision 自己挑，顺序沿用系统表）。配不上返回空数组，调用方据此报
  /// `MODEL_UNAVAILABLE`。
  static func visionLanguages(for tag: String, supported: [String]) -> [String] {
    let primary = primarySubtag(tag)
    if primary.isEmpty { return [] }
    return supported.filter { primarySubtag($0) == primary }
  }

  private static func primarySubtag(_ tag: String) -> String {
    let lowered = tag.lowercased()
    guard let first = lowered.split(separator: "-").first else { return lowered }
    return String(first)
  }
}

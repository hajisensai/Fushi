import AVFoundation
import Foundation
import Speech

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Apple 侧「不用下我们的模型」的语音转录：`app.fushi.reader/apple_speech`。
///
/// 用 iOS 26 / macOS 26 的 `SpeechAnalyzer` + `SpeechTranscriber` 直接转录**本地音频
/// 文件**，产出句级时间区间与逐词时间戳，交给 Dart 侧拼成与 ONNX 后端**逐字节同构**
/// 的产物（`transcript.srt` + `transcript.tokens.jsonl`）。
///
/// **两道版本闸门，缺一不可**：
///
/// - 编译期 `#if compiler(>=6.2)`：`SpeechAnalyzer` 这批符号只存在于 Xcode 26 带的
///   SDK 里。本仓的 Mac 开发机还在 Xcode 16.4，不隔离的话那边**整个工程编不过**
///   （CI 用的是 Xcode 26.6，两边都要能编）。老 Xcode 下整段实现消失，只留下
///   「本机不支持」的应答——功能不可用，但构建不塌。
/// - 运行期 `if #available(iOS 26, macOS 26, *)`：部署目标是 iOS 15.1 / macOS 13.4，
///   绝大多数用户机器上这套 API 根本不存在。
///
/// **说清楚「不用下模型」的边界**：不用下我们那 1 GB ONNX，但系统的语言资产仍要下
/// （`AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`），
/// 而且要 `reserve(locale:)`、有 `maximumReservedLocales` 上限。区别是这份资产由
/// **系统**保管、多 app 共享、不占我们的包体。UI 上如实这么说，别吹成零下载。
enum FushiSpeechTranscriber {
  static let channelName = "app.fushi.reader/apple_speech"

  /// 反向通知进度用；`transcribe` 是长任务（整本有声书几小时）。
  private static var channel: FlutterMethodChannel?

  /// 进行中的转录任务，供 `cancel` 取消。
  private static var currentTask: Task<Void, Never>?

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let created = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: binaryMessenger)
    channel = created
    created.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(isAvailable())
    case "supportedLocales":
      localeList(installed: false, result: result)
    case "installedLocales":
      localeList(installed: true, result: result)
    case "prepare":
      prepare(call, result: result)
    case "transcribe":
      transcribe(call, result: result)
    case "cancel":
      currentTask?.cancel()
      currentTask = nil
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func unsupported(_ result: @escaping FlutterResult) {
    result(
      FlutterError(
        code: "UNSUPPORTED_OS",
        message: "Apple speech transcription requires iOS 26 / macOS 26",
        details: nil))
  }

  #if compiler(>=6.2)

    private static func isAvailable() -> Bool {
      if #available(iOS 26.0, macOS 26.0, *) {
        return true
      }
      return false
    }

    private static func localeList(
      installed: Bool,
      result: @escaping FlutterResult
    ) {
      guard #available(iOS 26.0, macOS 26.0, *) else {
        result([String]())
        return
      }
      Task {
        let locales =
          installed
          ? await SpeechTranscriber.installedLocales
          : await SpeechTranscriber.supportedLocales
        let ids = locales.map { $0.identifier(.bcp47) }
        await MainActor.run { result(ids) }
      }
    }

    /// 确保该语言的资产已装好。已装好时直接成功，不发任何网络请求。
    private static func prepare(
      _ call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) {
      guard #available(iOS 26.0, macOS 26.0, *) else {
        unsupported(result)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let tag = args["locale"] as? String
      else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENT", message: "locale is required", details: nil))
        return
      }
      Task {
        do {
          guard let locale = await matchedLocale(for: tag) else {
            await MainActor.run {
              result(
                FlutterError(
                  code: "LOCALE_UNSUPPORTED",
                  message: "no Apple speech model for \"\(tag)\"",
                  details: nil))
            }
            return
          }
          let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])
          if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
          {
            try await request.downloadAndInstall()
          }
          // 预留槽位（有 maximumReservedLocales 上限）；已预留时是幂等的。
          try await AssetInventory.reserve(locale: locale)
          await MainActor.run { result(true) }
        } catch {
          await MainActor.run {
            result(
              FlutterError(
                code: "ASSET_INSTALL_FAILED",
                message: error.localizedDescription,
                details: nil))
          }
        }
      }
    }

    private static func transcribe(
      _ call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) {
      guard #available(iOS 26.0, macOS 26.0, *) else {
        unsupported(result)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let tag = args["locale"] as? String
      else {
        result(
          FlutterError(
            code: "INVALID_ARGUMENT",
            message: "path and locale are required",
            details: nil))
        return
      }
      currentTask?.cancel()
      currentTask = Task {
        var replied = false
        // 「恰好回调一次」的闸门：下面有正常返回、抛错、取消三条出口。
        func reply(_ value: Any?) async {
          if replied { return }
          replied = true
          await MainActor.run { result(value) }
        }
        do {
          guard let locale = await matchedLocale(for: tag) else {
            await reply(
              FlutterError(
                code: "LOCALE_UNSUPPORTED",
                message: "no Apple speech model for \"\(tag)\"",
                details: nil))
            return
          }
          let url = URL(fileURLWithPath: path)
          let file = try AVAudioFile(forReading: url)
          let totalMs = Int(
            (Double(file.length) / file.fileFormat.sampleRate) * 1000)

          let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])
          let analyzer = SpeechAnalyzer(modules: [transcriber])

          // 结果流与分析同时跑：results 是 AsyncSequence，start 会把整份文件喂完。
          let collector = Task { () -> [[String: Any]] in
            var segments: [[String: Any]] = []
            for try await value in transcriber.results {
              guard value.isFinal else { continue }
              if let segment = segmentPayload(value) {
                segments.append(segment)
                let done = (segment["endMs"] as? Int) ?? 0
                await MainActor.run {
                  channel?.invokeMethod(
                    "progress",
                    arguments: ["processedMs": done, "totalMs": totalMs])
                }
              }
            }
            return segments
          }

          try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
          try await analyzer.finalizeAndFinishThroughEndOfInput()
          let segments = try await collector.value
          if Task.isCancelled {
            await reply(
              FlutterError(code: "CANCELLED", message: "cancelled", details: nil))
            return
          }
          await reply(["durationMs": totalMs, "segments": segments])
        } catch {
          await reply(
            FlutterError(
              code: Task.isCancelled ? "CANCELLED" : "TRANSCRIBE_FAILED",
              message: error.localizedDescription,
              details: nil))
        }
        currentTask = nil
      }
    }

    /// 把一条结果拍平成 Dart 侧认得的 map：句级区间 + 逐词区间。
    ///
    /// 句级来自 `Result.range`（不需要任何 attributeOption）；逐词来自
    /// `.audioTimeRange` 给 AttributedString 挂的 `TimeRangeAttribute`。两级都给，
    /// Dart 侧才能同时产出 SRT 与逐 token sidecar。
    @available(iOS 26.0, macOS 26.0, *)
    private static func segmentPayload(
      _ value: SpeechTranscriber.Result
    ) -> [String: Any]? {
      let text = String(value.text.characters)
      if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return nil
      }
      let start = CMTimeGetSeconds(value.range.start)
      let end = CMTimeGetSeconds(value.range.end)
      guard start.isFinite, end.isFinite, end > start else { return nil }

      var tokens: [[String: Any]] = []
      for run in value.text.runs {
        guard let range = run.audioTimeRange else { continue }
        let piece = String(value.text[run.range].characters)
        if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          continue
        }
        let tokenStart = CMTimeGetSeconds(range.start)
        guard tokenStart.isFinite else { continue }
        tokens.append([
          "text": piece,
          "startMs": Int(tokenStart * 1000),
        ])
      }
      return [
        "text": text,
        "startMs": Int(start * 1000),
        "endMs": Int(end * 1000),
        "tokens": tokens,
      ]
    }

    /// 把 BCP-47 主子标签（`ja` / `zh`…）配到 Apple 支持的 locale 上。
    ///
    /// 先用官方的 `supportedLocale(equivalentTo:)` 做等价匹配，不中再按主子标签
    /// 前缀在 `supportedLocales` 里找——`ja` 要能配上 `ja-JP`。
    @available(iOS 26.0, macOS 26.0, *)
    private static func matchedLocale(for tag: String) async -> Locale? {
      if let exact = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: tag))
      {
        return exact
      }
      let primary = primarySubtag(tag)
      if primary.isEmpty { return nil }
      for candidate in await SpeechTranscriber.supportedLocales {
        if primarySubtag(candidate.identifier(.bcp47)) == primary {
          return candidate
        }
      }
      return nil
    }

  #else

    // Xcode 26 之前的 SDK 里没有 SpeechAnalyzer 这批符号。整段实现消失，应答成
    // 「本机不支持」——功能不可用，但工程仍然编得过（本仓 Mac 开发机是 Xcode 16.4）。
    private static func isAvailable() -> Bool { false }

    private static func localeList(
      installed: Bool,
      result: @escaping FlutterResult
    ) {
      result([String]())
    }

    private static func prepare(
      _ call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) {
      unsupported(result)
    }

    private static func transcribe(
      _ call: FlutterMethodCall,
      result: @escaping FlutterResult
    ) {
      unsupported(result)
    }

  #endif

  private static func primarySubtag(_ tag: String) -> String {
    let lowered = tag.lowercased()
    guard let first = lowered.split(separator: "-").first else { return lowered }
    return String(first)
  }
}

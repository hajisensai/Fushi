import AVFoundation
import Flutter

/// 音乐输出的 iOS 半边（Dart 契约：lib/src/media/music/music_platform_output.dart）。
/// iOS 没有独占模式，只能把首选采样率设成源采样率并回报硬件实际值。
/// 不改 category：category 由 Dart 侧 audio_session 配置负责。
enum MusicOutputChannel {
  static let channelName = "app.fushi.reader/music_output"

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "setPreferredSampleRate":
        guard let args = call.arguments as? [String: Any],
          let rate = (args["sampleRate"] as? NSNumber)?.doubleValue
        else {
          result(FlutterError(code: "bad_args", message: "sampleRate required", details: nil))
          return
        }
        let session = AVAudioSession.sharedInstance()
        do {
          try session.setPreferredSampleRate(rate)
          result(["preferred": session.preferredSampleRate, "actual": session.sampleRate])
        } catch {
          result(FlutterError(code: "set_failed", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

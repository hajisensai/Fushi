import AVFoundation
import Flutter

/// iOS 的系统语音：`app.fushi.reader/tts` 通道上的 `ttsToFile` / `getVoices`。
///
/// Dart 侧（`lib/src/utils/misc/tts_channel.dart`）在 iOS 上只把这两个方法发到本通道；
/// 同名通道的其它方法（播放、本地音频库）iOS 走 Dart 自己的实现，这里一律
/// `FlutterMethodNotImplemented`。以前 iOS 根本没有合成到文件的实现，「系统语音」在
/// 朗读声音与制卡发音兜底里都不出现。
///
/// 合成用 `AVSpeechSynthesizer.write(_:toBufferCallback:)`：系统把 PCM 分块回调出来，
/// 我们写进 16-bit WAV（缓存层只认 WAV / MP3）。契约与 Android 原生逐字对齐：
/// - 入参 `text` / `outputPath` / `languageTag?` / `voice?`（`AVSpeechSynthesisVoice.identifier`）；
/// - 点名的声音不在 → `VOICE_UNAVAILABLE`；语言没有可用声音 → `LANGUAGE_NOT_SUPPORTED`；
///   合成没产出音频 → `SYNTHESIS_FAILED`。
///
/// 一次只合成一句（排队）：`write` 是异步的，合成器必须活到最后一块缓冲回来。
final class FushiSystemTts: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = FushiSystemTts()
  static let channelName = "app.fushi.reader/tts"

  /// 一句从开始到结束的上界：个别系统版本 `write` 既不回空缓冲也不回 didFinish，
  /// 队列不能就此卡死。
  private static let jobTimeout: TimeInterval = 30

  private struct Job {
    let text: String
    let outputPath: String
    let languageTag: String?
    let voiceId: String?
    let result: FlutterResult
  }

  private var queue: [Job] = []
  private var busy = false
  private var synthesizer: AVSpeechSynthesizer?
  private var file: AVAudioFile?
  private var tempUrl: URL?
  private var current: Job?
  private var generation = 0
  private var wroteFrames: AVAudioFramePosition = 0

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getVoices":
      result(Self.voiceList())
    case "ttsToFile":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let text = args["text"] as? String, !text.isEmpty,
        let outputPath = args["outputPath"] as? String, !outputPath.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "text and outputPath are required", details: nil))
        return
      }
      queue.append(
        Job(
          text: text, outputPath: outputPath,
          languageTag: (args["languageTag"] as? String).flatMap { $0.isEmpty ? nil : $0 },
          voiceId: (args["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 },
          result: result))
      pump()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func voiceList() -> [[String: Any]] {
    AVSpeechSynthesisVoice.speechVoices().map { v in
      let quality: String
      switch v.quality {
      case .enhanced: quality = "enhanced"
      case .premium: quality = "premium"
      default: quality = ""
      }
      return ["id": v.identifier, "name": v.name, "locale": v.language, "quality": quality]
    }
  }

  // MARK: - 合成队列（只在主线程读写）

  private func pump() {
    guard !busy, !queue.isEmpty else { return }
    let job = queue.removeFirst()
    let voice: AVSpeechSynthesisVoice?
    if let id = job.voiceId {
      guard let v = AVSpeechSynthesisVoice(identifier: id) else {
        job.result(FlutterError(code: "VOICE_UNAVAILABLE", message: id, details: nil))
        pump()
        return
      }
      voice = v
    } else if let tag = job.languageTag {
      guard let v = AVSpeechSynthesisVoice(language: tag) else {
        job.result(FlutterError(code: "LANGUAGE_NOT_SUPPORTED", message: tag, details: nil))
        pump()
        return
      }
      voice = v
    } else {
      voice = nil  // 系统当前语言的默认声音。
    }
    busy = true
    current = job
    generation += 1
    let myGeneration = generation
    wroteFrames = 0
    file = nil
    tempUrl = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fushi_tts_\(UUID().uuidString).wav")

    let utterance = AVSpeechUtterance(string: job.text)
    utterance.voice = voice
    let synth = AVSpeechSynthesizer()
    synth.delegate = self
    synthesizer = synth
    synth.write(utterance) { [weak self] buffer in
      // 回调线程不定：切回主线程，与队列状态同一线程读写。
      guard let pcm = buffer as? AVAudioPCMBuffer else { return }
      let copy = pcm.frameLength == 0 ? nil : Self.copyBuffer(pcm)
      DispatchQueue.main.async {
        guard let self = self, self.generation == myGeneration else { return }
        if let copy = copy {
          self.append(copy)
        } else {
          self.finish(generation: myGeneration)
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.jobTimeout) { [weak self] in
      guard let self = self, self.generation == myGeneration, self.busy else { return }
      self.fail("SYNTHESIS_FAILED", "speech synthesizer did not finish in time")
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let myGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.synthesizer === synthesizer else { return }
      self.finish(generation: myGeneration)
    }
  }

  /// 回调里的缓冲在回调返回后可能被系统复用：先拷一份再跨线程。
  private static func copyBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else {
      return nil
    }
    dst.frameLength = src.frameLength
    let frames = Int(src.frameLength)
    let channels = Int(src.format.channelCount)
    let interleaved = src.format.isInterleaved
    let perChannel = interleaved ? frames * channels : frames
    let planes = interleaved ? 1 : channels
    if let s = src.floatChannelData, let d = dst.floatChannelData {
      for c in 0..<planes { d[c].update(from: s[c], count: perChannel) }
    } else if let s = src.int16ChannelData, let d = dst.int16ChannelData {
      for c in 0..<planes { d[c].update(from: s[c], count: perChannel) }
    } else if let s = src.int32ChannelData, let d = dst.int32ChannelData {
      for c in 0..<planes { d[c].update(from: s[c], count: perChannel) }
    } else {
      return nil
    }
    return dst
  }

  private func append(_ buffer: AVAudioPCMBuffer) {
    guard busy, let url = tempUrl else { return }
    do {
      if file == nil {
        let format = buffer.format
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: format.sampleRate,
          AVNumberOfChannelsKey: format.channelCount,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(
          forWriting: url, settings: settings,
          commonFormat: format.commonFormat, interleaved: format.isInterleaved)
      }
      try file?.write(from: buffer)
      wroteFrames += AVAudioFramePosition(buffer.frameLength)
    } catch {
      fail("SYNTHESIS_FAILED", "write wav: \(error.localizedDescription)")
    }
  }

  private func finish(generation myGeneration: Int) {
    guard busy, generation == myGeneration, let job = current, let url = tempUrl else { return }
    // 释放 AVAudioFile 才会把 WAV 头里的长度写回、句柄关掉。
    file = nil
    guard wroteFrames > 0 else {
      fail("SYNTHESIS_FAILED", "no audio produced")
      return
    }
    let fm = FileManager.default
    let out = URL(fileURLWithPath: job.outputPath)
    do {
      try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
      try fm.moveItem(at: url, to: out)
    } catch {
      fail("SYNTHESIS_FAILED", "move wav: \(error.localizedDescription)")
      return
    }
    tempUrl = nil
    complete { job.result(job.outputPath) }
  }

  private func fail(_ code: String, _ message: String) {
    guard busy, let job = current else { return }
    file = nil
    if let url = tempUrl { try? FileManager.default.removeItem(at: url) }
    tempUrl = nil
    synthesizer?.stopSpeaking(at: .immediate)
    complete { job.result(FlutterError(code: code, message: message, details: nil)) }
  }

  private func complete(_ answer: () -> Void) {
    generation += 1  // 迟到的回调一律作废。
    synthesizer?.delegate = nil
    synthesizer = nil
    current = nil
    busy = false
    answer()
    pump()
  }
}

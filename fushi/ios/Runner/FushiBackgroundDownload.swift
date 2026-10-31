import Flutter
import Foundation
import UIKit

/// 词典包下载的 iOS 后台传输（BUG-3887）。Dart 契约：
/// lib/src/platform/mobile/ios_background_download.dart（方法名 / 参数名 / error kind
/// 是跨语言契约，改一边必须改另一边）。
///
/// app 切到后台几十秒即被挂起，进程内的 socket 随之停摆；系统后台 `URLSession` 的传输
/// 跑在系统守护进程里，挂起期间照常推进，下完系统把 app 唤醒到后台交付文件
/// （`handleEventsForBackgroundURLSession`，见 AppDelegate）。
///
/// 孤儿任务：会话里 taskDescription 不在 [liveIds] 里的任务是上一个进程（被系统回收）
/// 留下的——等它的 Dart Future 已经不存在了。新进程第一次建会话时全部取消，系统唤醒
/// 交付的孤儿文件直接丢弃，不往磁盘上留几 GB 没人要的包。
final class FushiBackgroundDownload: NSObject, URLSessionDownloadDelegate {
  static let shared = FushiBackgroundDownload()
  static let channelName = "app.fushi.reader/background_download"
  private static let identifierPrefix = "app.fushi.reader.dict-download"
  private static let progressInterval: TimeInterval = 0.25

  private var channel: FlutterMethodChannel?

  /// 委托队列（串行）。以下状态只在这条队列上读写。
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    q.name = "app.fushi.reader.background-download"
    return q
  }()
  private var sessions: [String: URLSession] = [:]
  /// Dart id → 本进程发起的任务。
  private var liveTasks: [String: URLSessionDownloadTask] = [:]
  private var destinations: [String: String] = [:]
  private var failures: [String: [String: Any]] = [:]
  private var lastProgressAt: [String: TimeInterval] = [:]

  /// 系统唤醒交付时给的完成回调（会话 identifier → 回调），只在主线程读写。
  private var completionHandlers: [String: () -> Void] = [:]

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    shared.channel = channel
    // 启动即挂上常用的两个会话，让上一个进程的孤儿任务现在就被取消，而不是等到
    // 用户下一次点下载（手动代理的会话按需建）。
    shared.queue.addOperation {
      for mode in ["system", "direct"] {
        let proxy = ProxyConfig(["proxyMode": mode])
        _ = shared.session(
          identifier: "\(identifierPrefix).\(proxy.signature)", proxy: proxy)
      }
    }
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start":
        guard let id = args["id"] as? String,
          let urlText = args["url"] as? String, let url = URL(string: urlText),
          let dest = args["dest"] as? String
        else {
          result(FlutterError(code: "bad_args", message: "id/url/dest required", details: nil))
          return
        }
        shared.start(id: id, url: url, dest: dest, proxy: ProxyConfig(args), result: result)
      case "cancel":
        guard let id = args["id"] as? String else {
          result(FlutterError(code: "bad_args", message: "id required", details: nil))
          return
        }
        shared.queue.addOperation {
          shared.liveTasks[id]?.cancel()
          DispatchQueue.main.async { result(nil) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// AppDelegate 的 `handleEventsForBackgroundURLSession` 转进来。不是本类的会话
  /// 返回 false，交回 FlutterAppDelegate 转给插件。
  @discardableResult
  func handleEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
    guard identifier.hasPrefix(Self.identifierPrefix) else { return false }
    completionHandlers[identifier] = completionHandler
    // 重新挂上会话，系统才会把积压的委托事件交过来。
    queue.addOperation { _ = self.session(identifier: identifier, proxy: nil) }
    return true
  }

  // MARK: - 会话

  struct ProxyConfig {
    let mode: String
    let host: String?
    let port: Int?

    init(_ args: [String: Any]) {
      mode = args["proxyMode"] as? String ?? "system"
      host = args["proxyHost"] as? String
      port = (args["proxyPort"] as? NSNumber)?.intValue
    }

    /// 会话配置建好后不可改，代理不同只能换会话；identifier 带上代理签名。
    var signature: String {
      switch mode {
      case "direct": return "direct"
      case "manual":
        let safeHost = (host ?? "").map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
        return "manual-\(String(safeHost))-\(port ?? 0)"
      default: return "system"
      }
    }

    var dictionary: [AnyHashable: Any]? {
      switch mode {
      case "direct":
        // 空字典 = 不走任何代理（nil 才是跟随系统）。
        return [:]
      case "manual":
        guard let host, let port else { return [:] }
        // iOS SDK 不导出 kCFNetworkProxiesHTTPS* 常量，按其字面键名写。
        return [
          kCFNetworkProxiesHTTPEnable as String: 1,
          kCFNetworkProxiesHTTPProxy as String: host,
          kCFNetworkProxiesHTTPPort as String: port,
          "HTTPSEnable": 1,
          "HTTPSProxy": host,
          "HTTPSPort": port,
        ]
      default:
        return nil
      }
    }
  }

  /// 取（或建）会话。只在 [queue] 上调。同一 identifier 在进程内只能建一次。
  private func session(identifier: String, proxy: ProxyConfig?) -> URLSession {
    if let existing = sessions[identifier] { return existing }
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    if let dictionary = proxy?.dictionary {
      config.connectionProxyDictionary = dictionary
    }
    let created = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    sessions[identifier] = created
    created.getAllTasks { tasks in
      self.queue.addOperation {
        for task in tasks where !self.isLive(task) {
          task.cancel()
        }
      }
    }
    return created
  }

  private func start(
    id: String, url: URL, dest: String, proxy: ProxyConfig,
    result: @escaping FlutterResult
  ) {
    queue.addOperation {
      let identifier = "\(Self.identifierPrefix).\(proxy.signature)"
      let session = self.session(identifier: identifier, proxy: proxy)
      let task = session.downloadTask(with: url)
      task.taskDescription = id
      self.liveTasks[id] = task
      self.destinations[id] = dest
      task.resume()
      DispatchQueue.main.async { result(nil) }
    }
  }

  /// id 由 Dart 按「微秒时间戳 + 进程内序号」生成，上一个进程的 id 不会在本进程复现。
  private func isLive(_ task: URLSessionTask) -> Bool {
    guard let id = task.taskDescription else { return false }
    return liveTasks[id] != nil
  }

  // MARK: - 委托（都在 queue 上）

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard isLive(downloadTask), let id = downloadTask.taskDescription else { return }
    let now = Date().timeIntervalSince1970
    let finished =
      totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
    if !finished, let last = lastProgressAt[id], now - last < Self.progressInterval { return }
    lastProgressAt[id] = now
    let total =
      totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown
      ? -1 : totalBytesExpectedToWrite
    send("progress", ["id": id, "received": totalBytesWritten, "total": total])
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // location 在本方法返回后即被系统删除：要留就得在这里同步挪走。孤儿直接丢弃。
    guard isLive(downloadTask), let id = downloadTask.taskDescription,
      let dest = destinations[id]
    else { return }
    if let http = downloadTask.response as? HTTPURLResponse,
      !(200..<300).contains(http.statusCode)
    {
      failures[id] = ["kind": "badResponse", "status": http.statusCode]
      return
    }
    let fm = FileManager.default
    let destUrl = URL(fileURLWithPath: dest)
    do {
      try fm.createDirectory(
        at: destUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fm.fileExists(atPath: dest) {
        try fm.removeItem(at: destUrl)
      }
      try fm.moveItem(at: location, to: destUrl)
    } catch {
      failures[id] = ["kind": "other", "message": error.localizedDescription]
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard isLive(task), let id = task.taskDescription else { return }
    var failure = failures[id]
    if let error = error as NSError? {
      failure = Self.failure(for: error)
    }
    liveTasks[id] = nil
    destinations[id] = nil
    failures[id] = nil
    lastProgressAt[id] = nil
    send("complete", ["id": id, "error": failure ?? NSNull()])
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier else { return }
    DispatchQueue.main.async {
      self.completionHandlers.removeValue(forKey: identifier)?()
    }
  }

  private static func failure(for error: NSError) -> [String: Any] {
    var kind = "other"
    if error.domain == NSURLErrorDomain {
      switch error.code {
      case NSURLErrorCancelled:
        kind = "cancel"
      case NSURLErrorTimedOut:
        kind = "stall"
      case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet, NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
        NSURLErrorCannotLoadFromNetwork, NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed:
        kind = "connection"
      default:
        break
      }
    }
    return ["kind": kind, "message": error.localizedDescription]
  }

  private func send(_ method: String, _ arguments: [String: Any]) {
    DispatchQueue.main.async {
      self.channel?.invokeMethod(method, arguments: arguments)
    }
  }
}

/// 下载保活的 iOS 半边（Dart 门面 android_download_keep_alive.dart 的
/// `ChannelDownloadKeepAlive`，通道 `app.fushi.reader/download_keep_alive`）。
///
/// iOS 没有前台服务；能做的只有 `beginBackgroundTask`：切走后多换约半分钟执行时间，
/// 够导入收尾 / 小文件下完。大文件的传输由上面的后台会话接管。
enum FushiDownloadKeepAlive {
  static let channelName = "app.fushi.reader/download_keep_alive"
  private static var task: UIBackgroundTaskIdentifier = .invalid

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "update":
        begin()
        result(nil)
      case "stop":
        end()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func begin() {
    guard task == .invalid else { return }
    task = UIApplication.shared.beginBackgroundTask(withName: "fushi.download") {
      end()
    }
  }

  private static func end() {
    guard task != .invalid else { return }
    let ending = task
    task = .invalid
    UIApplication.shared.endBackgroundTask(ending)
  }
}

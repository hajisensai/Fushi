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
/// 跨进程接管：带 `meta` 发起的任务登记进持久化注册表（[Record]，落在 Application
/// Support 的 [registryFileName]）。app 进程被系统回收后传输照常在守护进程里跑；新进程
/// 启动即重挂会话，把注册表里的任务接回 [liveTasks]（进度 / 交付照常处理，进程不在时
/// 交付的文件照样挪到目标路径并记成 delivered），等 Dart 经 `recover` / `attach` 接手。
/// 系统替我们取消的任务（用户划掉 app、系统资源不足）带着断点数据记下来并续上。
/// 只有注册表里没有的任务才是真孤儿：等它的人已经不存在了，取消，交付的文件丢弃。
/// 注册表条目由 Dart 拿到结局后 `forget`，或判定没人要时 `discard`（顺带删已交付文件）。
final class FushiBackgroundDownload: NSObject, URLSessionDownloadDelegate {
  static let shared = FushiBackgroundDownload()
  static let channelName = "app.fushi.reader/background_download"
  private static let identifierPrefix = "app.fushi.reader.dict-download"
  private static let progressInterval: TimeInterval = 0.25
  private static let registryFileName = "fushi_background_downloads.json"

  private enum State {
    static let running = "running"
    static let delivered = "delivered"
    static let failed = "failed"
  }

  /// 一条跨进程可接管的下载。
  private struct Record: Codable {
    var url: String
    var dest: String
    /// Dart 的接管描述（不透明 JSON 字符串，原样还给 Dart）。
    var meta: String
    var proxyMode: String
    var proxyHost: String?
    var proxyPort: Int?
    var state: String
    var errorKind: String?
    var errorStatus: Int?
    var errorMessage: String?
    /// 被系统取消时留下的断点，续传用一次即清。
    var resumeData: Data?

    var proxy: ProxyConfig { ProxyConfig(mode: proxyMode, host: proxyHost, port: proxyPort) }

    var errorDictionary: [String: Any] {
      var error: [String: Any] = ["kind": errorKind ?? "other"]
      if let errorStatus { error["status"] = errorStatus }
      if let errorMessage { error["message"] = errorMessage }
      return error
    }
  }

  private var channel: FlutterMethodChannel?

  /// 委托队列（串行）。以下状态只在这条队列上读写。
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    q.name = "app.fushi.reader.background-download"
    return q
  }()
  private var sessions: [String: URLSession] = [:]
  /// Dart id → 本进程发起或接回的任务。
  private var liveTasks: [String: URLSessionDownloadTask] = [:]
  private var destinations: [String: String] = [:]
  private var failures: [String: [String: Any]] = [:]
  private var lastProgressAt: [String: TimeInterval] = [:]
  /// 持久化注册表（Dart id → 记录）。
  private var records: [String: Record] = [:]
  /// 本进程发起的 id：`recover` 只交出上一个进程留下的，正在本进程里等着的不算。
  private var startedHere: Set<String> = []
  /// 各会话 `getAllTasks` 的接回扫描；`recover` / `attach` 等它们全部完成再答。
  private let scanGroup = DispatchGroup()

  /// 系统唤醒交付时给的完成回调（会话 identifier → 回调），只在主线程读写。
  private var completionHandlers: [String: () -> Void] = [:]

  override private init() {
    super.init()
    queue.addOperation { self.loadRecords() }
  }

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: binaryMessenger)
    shared.channel = channel
    // 启动即挂上常用的两个会话与注册表里用到的会话：接回上一个进程的在途任务、取消
    // 真孤儿，而不是等到 Dart 第一次来问（手动代理的新会话按需建）。
    shared.queue.addOperation {
      var proxies: [String: ProxyConfig] = [:]
      for mode in ["system", "direct"] {
        let proxy = ProxyConfig(mode: mode, host: nil, port: nil)
        proxies[Self.identifier(for: proxy)] = proxy
      }
      for record in shared.records.values {
        proxies[Self.identifier(for: record.proxy)] = record.proxy
      }
      for (identifier, proxy) in proxies {
        _ = shared.session(identifier: identifier, proxy: proxy)
      }
      shared.whenScanned {}
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
        shared.start(
          id: id, url: url, dest: dest, meta: args["meta"] as? String,
          proxy: ProxyConfig(args), result: result)
      case "cancel":
        guard let id = args["id"] as? String else {
          result(FlutterError(code: "bad_args", message: "id required", details: nil))
          return
        }
        shared.queue.addOperation {
          shared.liveTasks[id]?.cancel()
          DispatchQueue.main.async { result(nil) }
        }
      case "recover":
        shared.whenScanned {
          let list: [[String: Any]] = shared.records
            .filter { !shared.startedHere.contains($0.key) }
            .map { id, record -> [String: Any] in ["id": id, "meta": record.meta] }
          DispatchQueue.main.async { result(list) }
        }
      case "attach":
        guard let id = args["id"] as? String else {
          result(FlutterError(code: "bad_args", message: "id required", details: nil))
          return
        }
        shared.whenScanned {
          let state = shared.attachState(id: id)
          DispatchQueue.main.async { result(state) }
        }
      case "forget", "discard":
        guard let id = args["id"] as? String else {
          result(FlutterError(code: "bad_args", message: "id required", details: nil))
          return
        }
        let discard = call.method == "discard"
        shared.queue.addOperation {
          shared.releaseRecord(id: id, discard: discard)
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
    queue.addOperation {
      let proxy = self.records.values.map(\.proxy).first {
        Self.identifier(for: $0) == identifier
      }
      _ = self.session(identifier: identifier, proxy: proxy)
    }
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

    init(mode: String, host: String?, port: Int?) {
      self.mode = mode
      self.host = host
      self.port = port
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

  private static func identifier(for proxy: ProxyConfig) -> String {
    "\(identifierPrefix).\(proxy.signature)"
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
    scanGroup.enter()
    created.getAllTasks { tasks in
      self.queue.addOperation {
        for task in tasks where !self.isTracked(task) {
          // 注册表里没有：等它的进程已经不在了，没人接得住。
          task.cancel()
        }
        for case let task as URLSessionDownloadTask in tasks {
          guard let id = task.taskDescription, self.liveTasks[id] == nil,
            let record = self.records[id], record.state == State.running
          else { continue }
          self.liveTasks[id] = task
          self.destinations[id] = record.dest
        }
        self.scanGroup.leave()
      }
    }
    return created
  }

  /// 所有已建会话的接回扫描完成后，在 [queue] 上跑 [body]。先把「登记为在跑、却没有
  /// 任务」的记录续上（任务在进程不在时被系统丢了），保证 Dart 看到的 running 都有任务。
  private func whenScanned(_ body: @escaping () -> Void) {
    scanGroup.notify(queue: .global()) {
      self.queue.addOperation {
        for (id, record) in self.records
        where record.state == State.running && self.liveTasks[id] == nil {
          self.restart(id: id)
        }
        body()
      }
    }
  }

  private func start(
    id: String, url: URL, dest: String, meta: String?, proxy: ProxyConfig,
    result: @escaping FlutterResult
  ) {
    queue.addOperation {
      let session = self.session(identifier: Self.identifier(for: proxy), proxy: proxy)
      let task = session.downloadTask(with: url)
      task.taskDescription = id
      self.liveTasks[id] = task
      self.destinations[id] = dest
      self.startedHere.insert(id)
      if let meta {
        self.records[id] = Record(
          url: url.absoluteString, dest: dest, meta: meta, proxyMode: proxy.mode,
          proxyHost: proxy.host, proxyPort: proxy.port, state: State.running)
        self.saveRecords()
      }
      task.resume()
      DispatchQueue.main.async { result(nil) }
    }
  }

  /// 续上一条在跑却没有任务的记录：有断点从断点续，没有就从头再下同一个地址。
  private func restart(id: String) {
    guard var record = records[id] else { return }
    let proxy = record.proxy
    let session = self.session(identifier: Self.identifier(for: proxy), proxy: proxy)
    let task: URLSessionDownloadTask
    if let resumeData = record.resumeData {
      task = session.downloadTask(withResumeData: resumeData)
    } else if let url = URL(string: record.url) {
      task = session.downloadTask(with: url)
    } else {
      record.state = State.failed
      record.errorKind = "other"
      record.errorMessage = "invalid url \(record.url)"
      records[id] = record
      saveRecords()
      return
    }
    record.resumeData = nil
    record.state = State.running
    records[id] = record
    saveRecords()
    task.taskDescription = id
    liveTasks[id] = task
    destinations[id] = record.dest
    task.resume()
  }

  /// Dart 接手一条记录时它此刻的结局。
  private func attachState(id: String) -> [String: Any] {
    guard let record = records[id] else { return ["state": "missing"] }
    switch record.state {
    case State.delivered:
      return ["state": State.delivered]
    case State.failed:
      return ["state": State.failed, "error": record.errorDictionary]
    default:
      let task = liveTasks[id]
      let expected = task?.countOfBytesExpectedToReceive ?? NSURLSessionTransferSizeUnknown
      return [
        "state": State.running,
        "received": task?.countOfBytesReceived ?? 0,
        "total": expected == NSURLSessionTransferSizeUnknown ? -1 : expected,
      ]
    }
  }

  /// 释放一条记录。[discard] = 没人要了：任务还在跑就取消，已交付的文件删掉。
  private func releaseRecord(id: String, discard: Bool) {
    guard let record = records.removeValue(forKey: id) else {
      if discard { liveTasks[id]?.cancel() }
      return
    }
    saveRecords()
    guard discard else { return }
    liveTasks[id]?.cancel()
    if record.state == State.delivered {
      try? FileManager.default.removeItem(atPath: record.dest)
    }
  }

  /// 本进程发起 / 接回的任务，或注册表里登记为在跑的任务（接回扫描完成前委托事件
  /// 可能先到，不能因为还没进 [liveTasks] 就把交付的文件丢掉）。
  private func isTracked(_ task: URLSessionTask) -> Bool {
    guard let id = task.taskDescription else { return false }
    return liveTasks[id] != nil || records[id]?.state == State.running
  }

  // MARK: - 注册表持久化（都在 queue 上）

  private var registryUrl: URL? {
    guard
      let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    else { return nil }
    return support.appendingPathComponent(Self.registryFileName)
  }

  private func loadRecords() {
    guard let registryUrl, let data = try? Data(contentsOf: registryUrl) else { return }
    records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
  }

  private func saveRecords() {
    guard let registryUrl else { return }
    do {
      try FileManager.default.createDirectory(
        at: registryUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(records)
      // 系统可能在锁屏时把 app 唤醒到后台交付：首次解锁后即可读写。
      try data.write(
        to: registryUrl, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      NSLog("[BackgroundDownload] save registry failed: \(error.localizedDescription)")
    }
  }

  // MARK: - 委托（都在 queue 上）

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard isTracked(downloadTask), let id = downloadTask.taskDescription else { return }
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
    guard isTracked(downloadTask), let id = downloadTask.taskDescription,
      let dest = destinations[id] ?? records[id]?.dest
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
    guard isTracked(task), let id = task.taskDescription else { return }
    // 接回扫描前到达的旧任务事件：本进程已经为同一 id 续了新任务，旧任务的结局作废。
    if let live = liveTasks[id], live !== task { return }
    var failure = failures[id]
    let nsError = error as NSError?
    liveTasks[id] = nil
    destinations[id] = nil
    failures[id] = nil
    lastProgressAt[id] = nil
    if let nsError {
      // 系统替我们取消的（用户划掉 app、系统资源不足、后台 app 被停用），不是用户点的
      // 取消：登记过的就带着断点续上，Dart 那边看到的是同一条任务接着走。
      if nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] != nil,
        var record = records[id]
      {
        record.resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        record.state = State.running
        records[id] = record
        restart(id: id)
        return
      }
      failure = Self.failure(for: nsError)
    }
    if var record = records[id] {
      if let failure {
        record.state = State.failed
        record.errorKind = failure["kind"] as? String
        record.errorStatus = failure["status"] as? Int
        record.errorMessage = failure["message"] as? String
      } else {
        record.state = State.delivered
      }
      records[id] = record
      saveRecords()
    }
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

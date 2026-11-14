import Flutter
import Network

/// 「系统默认网络变了」事件流（`app.fushi.reader/network_change`，EventChannel），给互联
/// P2P 隧道（iroh 端点）用：Dart 侧 `interconnect_p2p_app.dart` 收到一次事件就调一次
/// `fp2p_network_change`。iroh 在 iOS 上的睡眠检测一小时才轮询一次，切网后连接没断而
/// 路径已失效时隧道会长时间不通。
///
/// `NWPathMonitor` 在任何路径属性变化时都会回调；这里只比较 `(status, 可用接口的名字 +
/// 类型)`，变了才发事件。启动后的第一次回调是当前网络，只记作基线。
final class FushiNetworkChange: NSObject, FlutterStreamHandler {
  static let channelName = "app.fushi.reader/network_change"
  private static let shared = FushiNetworkChange()

  private let queue = DispatchQueue(label: "app.fushi.reader.network_change")
  private var monitor: NWPathMonitor?
  /// [monitor] 与 [sink] 只在主线程读写。
  private var sink: FlutterEventSink?

  static func register(binaryMessenger: FlutterBinaryMessenger) {
    FlutterEventChannel(name: channelName, binaryMessenger: binaryMessenger)
      .setStreamHandler(shared)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    stop()
    sink = events
    // NWPathMonitor 取消后不能再启动，每次订阅新建一个。
    let m = NWPathMonitor()
    // 基线随监视器走：回调只在串行 queue 上跑，捕获的局部变量不会并发读写。
    var lastKey: String?
    m.pathUpdateHandler = { [weak self, weak m] path in
      let key = Self.pathKey(path)
      let changed = lastKey != nil && lastKey != key
      lastKey = key
      guard changed else { return }
      DispatchQueue.main.async {
        guard let self, let m, self.monitor === m else { return }
        self.sink?(nil)
      }
    }
    monitor = m
    m.start(queue: queue)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop()
    return nil
  }

  private func stop() {
    monitor?.cancel()
    monitor = nil
    sink = nil
  }

  private static func pathKey(_ path: NWPath) -> String {
    let status: String
    switch path.status {
    case .satisfied: status = "satisfied"
    case .unsatisfied: status = "unsatisfied"
    case .requiresConnection: status = "requiresConnection"
    @unknown default: status = "unknown"
    }
    let interfaces = path.availableInterfaces
      .map { "\($0.name):\(typeName($0.type))" }
      .sorted()
      .joined(separator: ",")
    return "\(status)|\(interfaces)"
  }

  private static func typeName(_ type: NWInterface.InterfaceType) -> String {
    switch type {
    case .wifi: return "wifi"
    case .cellular: return "cellular"
    case .wiredEthernet: return "wired"
    case .loopback: return "loopback"
    case .other: return "other"
    @unknown default: return "unknown"
    }
  }
}

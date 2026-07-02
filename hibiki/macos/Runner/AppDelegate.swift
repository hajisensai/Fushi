import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var activeSecurityScopedURLs: [String: URL] = [:]

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "app.hibiki/data_root_access",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleDataRootAccess(call, result: result)
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    for url in activeSecurityScopedURLs.values {
      url.stopAccessingSecurityScopedResource()
    }
    activeSecurityScopedURLs.removeAll()
    super.applicationWillTerminate(notification)
  }

  private func handleDataRootAccess(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(
        code: "bad_args",
        message: "Missing data root access arguments",
        details: nil))
      return
    }

    switch call.method {
    case "createBookmark":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "bad_path", message: "Missing path", details: nil))
        return
      }
      do {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
          if didStart {
            url.stopAccessingSecurityScopedResource()
          }
        }
        let data = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        result(data.base64EncodedString())
      } catch {
        result(FlutterError(
          code: "bookmark_failed",
          message: "Failed to create data root bookmark",
          details: error.localizedDescription))
      }

    case "startAccessingBookmark":
      guard let encoded = args["bookmark"] as? String,
            let data = Data(base64Encoded: encoded) else {
        result(FlutterError(code: "bad_bookmark", message: "Invalid bookmark", details: nil))
        return
      }
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &stale)
        let key = url.path
        if activeSecurityScopedURLs[key] == nil {
          let ok = url.startAccessingSecurityScopedResource()
          guard ok else {
            result(FlutterError(
              code: "access_denied",
              message: "Failed to access security-scoped data root",
              details: key))
            return
          }
          activeSecurityScopedURLs[key] = url
        }
        result(["path": key, "stale": stale])
      } catch {
        result(FlutterError(
          code: "resolve_failed",
          message: "Failed to resolve data root bookmark",
          details: error.localizedDescription))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

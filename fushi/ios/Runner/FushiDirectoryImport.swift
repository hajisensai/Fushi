import Flutter
import UIKit
import UniformTypeIdentifiers

/// iOS 半边的 `app.fushi.reader/saf` channel：「选一个文件夹，把整棵树拷进 app 自己的
/// 容器再交回」（BUG-2786）。
///
/// 为什么不能直接用 file_picker 的 `getDirectoryPath()`：它返回的是沙盒**外**的路径，
/// 插件从不调 `startAccessingSecurityScopedResource()`，`dart:io` 列目录直接被拒。而
/// `pickFiles()` 用的是 import 模式，只把被选中的**那一个文件**挪进
/// `NSTemporaryDirectory()`——`.mokuro` 的同级页图文件夹根本不会跟过来。
///
/// 所以目录导入在 iOS 上只能是「拿到安全作用域 URL → 在访问窗口内整卷拷进来 →
/// 交回拷贝后的路径」。与 Android 的 `pickAndCopyDirectory` 同名同契约：
/// - 入参 `{destPath}`：app 自己可写的暂存根；先删后建。
/// - 返回：**拷贝后树的根**（iOS 是 `destPath/<文件夹名>`，保留卷名给标题派生用）；
///   调用方必须用返回值、不许自己拼；导入结束后由调用方删掉 `destPath`。
/// - 取消 / 下拉关掉 → `nil`；拷贝失败 → `COPY_FAILED`（半截拷贝已删）；
///   已有一个选择器挂着 → `BUSY`。
///
/// 同一 channel 还承载**常驻来源文件夹**的安全作用域书签（BUG-3665，反馈 Tz04dfBf2f）：
/// 常驻来源要反复复扫、视频还要原地播放，不能整卷拷，只能记住用户的授权、每次用前
/// 重新激活。Dart 门面是 `fushi/lib/src/media/source_library/source_folder_access.dart`。
/// 契约：
/// - `pickDirectoryBookmark()` → `{path, bookmark}`（bookmark 是 base64）；取消 → `nil`；
///   建书签失败 → `BOOKMARK_FAILED`；`BUSY` / `NO_PRESENTER` 同上。返回时访问已停止，
///   用之前必须先 `startAccessingBookmark`。
/// - `startAccessingBookmark({bookmark})` → `{path, stale, refreshedBookmark?}`；
///   解析失败 → `RESOLVE_FAILED`；系统拒绝访问 → `ACCESS_DENIED`。同一路径重复调用
///   只加计数、不重复 `startAccessing…`。
/// - `stopAccessingBookmark({path})` → `Bool`（该路径此前是否在访问中）。计数归零才
///   真正 `stopAccessingSecurityScopedResource()`。
final class FushiDirectoryImport: NSObject, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  static let channelName = "app.fushi.reader/saf"

  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private var pendingResult: FlutterResult?
  /// 当前挂着的选择器要做什么：`.copy` = 整卷拷进暂存（BUG-2786）；`.bookmark` =
  /// 只建书签交回（常驻来源）。
  private var pendingMode: PendingPick?

  private enum PendingPick {
    case copy(destPath: String)
    case bookmark
  }

  private enum BookmarkAccessError: LocalizedError {
    case invalidEncoding
    case denied(String)

    var errorDescription: String? {
      switch self {
      case .invalidEncoding: return "Bookmark is not valid base64"
      case .denied(let path): return "Access to \(path) was denied"
      }
    }
  }

  /// 正在访问中的安全作用域 URL，按解析后的路径计数。
  ///
  /// 为什么计数而不是 Set：书 / 漫画 / 视频三个来源可以指向同一个文件夹，Dart 侧按来源
  /// 行各自 start / stop；若按路径去重，删掉其中一个来源就会把另外两个的访问一起停掉。
  /// 只在 [accessQueue] 上读写。
  private var activeAccess: [String: (url: URL, count: Int)] = [:]
  private let accessQueue = DispatchQueue(label: "app.fushi.reader.saf.bookmark-access")

  init(
    binaryMessenger: FlutterBinaryMessenger,
    presenter: @escaping () -> UIViewController?
  ) {
    self.presenter = presenter
    channel = FlutterMethodChannel(
      name: FushiDirectoryImport.channelName, binaryMessenger: binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickAndCopyDirectory":
      guard let args = call.arguments as? [String: Any],
        let destPath = args["destPath"] as? String, !destPath.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARG", message: "destPath required", details: nil))
        return
      }
      presentPicker(mode: .copy(destPath: destPath), result: result)
    case "pickDirectoryBookmark":
      presentPicker(mode: .bookmark, result: result)
    case "startAccessingBookmark":
      guard let args = call.arguments as? [String: Any],
        let encoded = args["bookmark"] as? String, !encoded.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARG", message: "bookmark required", details: nil))
        return
      }
      startAccessing(bookmarkBase64: encoded, result: result)
    case "stopAccessingBookmark":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String, !path.isEmpty
      else {
        result(FlutterError(code: "INVALID_ARG", message: "path required", details: nil))
        return
      }
      stopAccessing(path: path, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentPicker(mode: PendingPick, result: @escaping FlutterResult) {
    // 与 Android 同口径：同一时刻只允许一个选择器挂着，否则前一个调用方的结果会被
    // 悄悄吞掉（它的 Future 永不完成）。
    guard pendingResult == nil else {
      result(FlutterError(
        code: "BUSY", message: "A directory pick is already in progress", details: nil))
      return
    }
    guard let host = presenter() else {
      result(FlutterError(
        code: "NO_PRESENTER", message: "No view controller to present the picker", details: nil))
      return
    }
    pendingResult = result
    pendingMode = mode

    // asCopy: false = open 模式：拿到的是原位置的安全作用域 URL，由下面自己拷整棵树
    // （或对它建书签）。asCopy: true 对文件夹不会递归拷贝子项、也拿不到原位置，不能用。
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.presentationController?.delegate = self
    host.present(picker, animated: true)
  }

  // MARK: - UIDocumentPickerDelegate

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let source = urls.first, let mode = pendingMode else {
      finish(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let outcome: Any?
      switch mode {
      case .copy(let destPath):
        do {
          outcome = try Self.copyTree(from: source, intoStagingRoot: destPath)
        } catch {
          outcome = FlutterError(
            code: "COPY_FAILED", message: error.localizedDescription, details: nil)
        }
      case .bookmark:
        do {
          let data = try Self.makeBookmark(for: source)
          outcome = [
            "path": source.path,
            "bookmark": data.base64EncodedString(),
          ]
        } catch {
          outcome = FlutterError(
            code: "BOOKMARK_FAILED", message: error.localizedDescription, details: nil)
        }
      }
      DispatchQueue.main.async { self.finish(outcome) }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  // MARK: - UIAdaptivePresentationControllerDelegate

  /// 下拉手势关掉表单时有的系统版本不回调 `documentPickerWasCancelled`，
  /// 不接这条的话 Dart 那边的 Future 永远挂着、之后再点一律 BUSY。
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(nil)
  }

  /// FlutterResult 恰好回调一次（取消与下拉关闭可能先后到达）。必须在主线程调。
  private func finish(_ value: Any?) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    pendingMode = nil
    result(value)
  }

  // MARK: - Security-scoped bookmarks（常驻来源，BUG-3665）

  /// 在访问窗口内为 [url] 建书签。
  ///
  /// 选项用默认值 `[]`：`.withSecurityScope` 是 macOS 专有（iOS SDK 上不可用）；iOS 上
  /// 在 `startAccessingSecurityScopedResource()` 生效期间建出的普通书签本身就带着安全
  /// 作用域，解析回来的 URL 可以再 `startAccessing…`。`.minimalBookmark` 不用——它
  /// 省掉的元数据正是跨重启 / 文件提供者重新定位文件夹所需的。
  private static func makeBookmark(for url: URL) throws -> Data {
    let accessing = url.startAccessingSecurityScopedResource()
    defer {
      if accessing { url.stopAccessingSecurityScopedResource() }
    }
    return try url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  /// 解析书签并开始访问；同一路径已在访问中只加计数。书签过期（`isStale`）时在
  /// 访问窗口内重建一份交回，由 Dart 回写 configJson。
  private func startAccessing(bookmarkBase64: String, result: @escaping FlutterResult) {
    accessQueue.async {
      let outcome: Any
      do {
        guard let data = Data(base64Encoded: bookmarkBase64) else {
          throw BookmarkAccessError.invalidEncoding
        }
        var stale = false
        let url = try URL(
          resolvingBookmarkData: data, options: [], relativeTo: nil,
          bookmarkDataIsStale: &stale)
        let path = url.path
        if let entry = self.activeAccess[path] {
          self.activeAccess[path] = (url: entry.url, count: entry.count + 1)
        } else {
          guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkAccessError.denied(path)
          }
          self.activeAccess[path] = (url: url, count: 1)
        }
        var payload: [String: Any] = ["path": path, "stale": stale]
        if stale {
          // 此刻正处于访问窗口内，可以重建；失败不影响本次访问，只是下次还会是 stale。
          if let refreshed = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
          {
            payload["refreshedBookmark"] = refreshed.base64EncodedString()
          }
        }
        outcome = payload
      } catch BookmarkAccessError.denied(let path) {
        outcome = FlutterError(
          code: "ACCESS_DENIED", message: "Access to \(path) was denied", details: nil)
      } catch {
        outcome = FlutterError(
          code: "RESOLVE_FAILED", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async { result(outcome) }
    }
  }

  private func stopAccessing(path: String, result: @escaping FlutterResult) {
    accessQueue.async {
      var wasActive = false
      if let entry = self.activeAccess[path] {
        wasActive = true
        if entry.count <= 1 {
          entry.url.stopAccessingSecurityScopedResource()
          self.activeAccess.removeValue(forKey: path)
        } else {
          self.activeAccess[path] = (url: entry.url, count: entry.count - 1)
        }
      }
      DispatchQueue.main.async { result(wasActive) }
    }
  }

  /// 在安全作用域访问窗口内，把 [source] 整棵树拷到 `stagingRoot/<文件夹名>` 并返回
  /// 该路径。失败时删掉整个暂存根（它是调用方专门给这次导入的，不会误删别的东西）。
  private static func copyTree(from source: URL, intoStagingRoot stagingRoot: String) throws
    -> String
  {
    let fileManager = FileManager.default
    let rootURL = URL(fileURLWithPath: stagingRoot, isDirectory: true)
    // 返回 false 不一定读不了（沙盒内的 URL 本就不需要），读不了时下面的拷贝会报错。
    let accessing = source.startAccessingSecurityScopedResource()
    defer {
      if accessing { source.stopAccessingSecurityScopedResource() }
    }
    do {
      if fileManager.fileExists(atPath: rootURL.path) {
        try fileManager.removeItem(at: rootURL)
      }
      try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
      let name = source.lastPathComponent.isEmpty ? "picked" : source.lastPathComponent
      let target = rootURL.appendingPathComponent(name, isDirectory: true)

      // 协调读：iCloud / 第三方文件提供者要靠它把内容就位，裸 copyItem 可能读到占位。
      var coordinationError: NSError?
      var copyError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(
        readingItemAt: source, options: [], error: &coordinationError
      ) { readableURL in
        do {
          try fileManager.copyItem(at: readableURL, to: target)
        } catch {
          copyError = error
        }
      }
      if let error = coordinationError ?? copyError {
        throw error
      }
      return target.path
    } catch {
      try? fileManager.removeItem(at: rootURL)
      throw error
    }
  }
}

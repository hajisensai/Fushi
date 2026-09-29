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
final class FushiDirectoryImport: NSObject, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  static let channelName = "app.fushi.reader/saf"

  private let channel: FlutterMethodChannel
  private let presenter: () -> UIViewController?
  private var pendingResult: FlutterResult?
  private var pendingDestPath: String?

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
    guard call.method == "pickAndCopyDirectory" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let destPath = args["destPath"] as? String, !destPath.isEmpty
    else {
      result(FlutterError(code: "INVALID_ARG", message: "destPath required", details: nil))
      return
    }
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
    pendingDestPath = destPath

    // asCopy: false = open 模式：拿到的是原位置的安全作用域 URL，由下面自己拷整棵树。
    // asCopy: true 对文件夹不会递归拷贝子项，不能用。
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
    guard let source = urls.first, let destPath = pendingDestPath else {
      finish(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let outcome: Any?
      do {
        outcome = try Self.copyTree(from: source, intoStagingRoot: destPath)
      } catch {
        outcome = FlutterError(
          code: "COPY_FAILED", message: error.localizedDescription, details: nil)
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
    pendingDestPath = nil
    result(value)
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

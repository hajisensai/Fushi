import XCTest

/// BUG-3482 真 WebKit 真触摸对照实验：对 `/tmp/fushi-xaxis/variants/*.html` 逐页装进
/// WebProbe（纯 WKWebView，配置对齐 flutter_inappwebview 在阅读器上的设置），做 5 次
/// 真触摸拖动（上 / 下 / 左 / 右 / 斜），WebProbe 把 UIScrollView 的 contentOffset /
/// contentSize 写进 `/tmp/fushi-xaxis/offsets.log`，这里在其中插 VARIANT / STEP 标记。
///
/// 为什么不直接拖 Fushi：Flutter 平台视图在模拟器上收不到 XCUITest 合成的触摸
/// （框架侧手势竞技场已判给 WebView，WKWebView 的 JS 仍一次 touchstart 都没收到），
/// 只能把 WebKit 那一层单独拿出来测。
final class WebProbeTests: XCTestCase {
  func testProbeVariants() throws {
    let dir = "/tmp/fushi-xaxis"
    let fm = FileManager.default
    let names = try fm.contentsOfDirectory(atPath: "\(dir)/variants")
      .filter { $0.hasSuffix(".html") }.sorted()
    XCTAssertFalse(names.isEmpty, "no variants under \(dir)/variants")
    let log = "\(dir)/offsets.log"
    func mark(_ s: String) {
      let line = s + "\n"
      if let h = FileHandle(forWritingAtPath: log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
      } else {
        try? line.write(toFile: log, atomically: true, encoding: .utf8)
      }
    }
    // 起止点避开顶部状态栏与底部 home indicator 的系统手势区。
    let drags: [(String, CGVector, CGVector)] = [
      ("up", CGVector(dx: 0.5, dy: 0.62), CGVector(dx: 0.5, dy: 0.32)),
      ("down", CGVector(dx: 0.5, dy: 0.32), CGVector(dx: 0.5, dy: 0.62)),
      ("left", CGVector(dx: 0.72, dy: 0.5), CGVector(dx: 0.38, dy: 0.5)),
      ("right", CGVector(dx: 0.38, dy: 0.5), CGVector(dx: 0.72, dy: 0.5)),
      ("diag", CGVector(dx: 0.7, dy: 0.7), CGVector(dx: 0.35, dy: 0.3)),
    ]
    let app = XCUIApplication()
    for n in names {
      try? fm.removeItem(atPath: "\(dir)/page.html")
      try fm.copyItem(atPath: "\(dir)/variants/\(n)", toPath: "\(dir)/page.html")
      mark("VARIANT \(n)")
      app.launch()
      Thread.sleep(forTimeInterval: 3.0)
      for (name, a, b) in drags {
        mark("STEP \(name)")
        app.coordinate(withNormalizedOffset: a).press(
          forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: b),
          withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.5)
      }
      mark("END \(n)")
      app.terminate()
    }
  }
}

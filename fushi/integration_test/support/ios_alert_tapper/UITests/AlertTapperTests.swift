import XCTest

/// 模拟器上的「系统弹窗自动放行」——BUG-2493 iOS 实测的辅助进程。
///
/// ssh 起的进程没有辅助功能授权，CGEvent / AppleScript 投不进 Simulator.app；
/// idb-companion 又要 Xcode 27。XCUITest 走的是模拟器内部的 AX 通道，不需要 Mac 侧
/// 授权，能点到 SpringBoard 呈现的系统弹窗：
///   * 「"Fushi" 想要打开 "FakeAnki"」/ 「在 "FakeAnki" 中打开?」→ 打开
///   * 「允许粘贴」（iOS 16+ 跨 app 读剪贴板）→ 允许粘贴
/// 循环到 TAPPER_SECONDS 秒为止，被 flutter test 的编排脚本并行拉起、结束时 kill。
final class AlertTapperTests: XCTestCase {
  func testTapSystemAlerts() {
    let env = ProcessInfo.processInfo.environment
    let seconds = TimeInterval(env["TAPPER_SECONDS"] ?? "") ?? 900
    let deadline = Date().addingTimeInterval(seconds)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    // 优先级：先放行「打开」，再放行「允许粘贴」；中英文都认。
    let labels = ["打开", "Open", "允许粘贴", "Allow Paste", "允许", "Allow"]
    var taps = 0
    var lastDump = Date.distantPast
    while Date() < deadline {
      var tapped = false
      for label in labels {
        let button = springboard.buttons[label]
        if button.exists && button.isHittable {
          button.tap()
          taps += 1
          NSLog("[tapper] tapped '%@' (#%d)", label, taps)
          tapped = true
          break
        }
      }
      if !tapped && Date().timeIntervalSince(lastDump) > 10 {
        // 每 10 秒吐一次 SpringBoard 当前可见按钮，便于事后知道哪个弹窗没被认出来。
        let names = springboard.buttons.allElementsBoundByIndex.prefix(12).map { $0.label }
        NSLog("[tapper] springboard buttons: %@", names.joined(separator: " | "))
        lastDump = Date()
      }
      Thread.sleep(forTimeInterval: tapped ? 1.0 : 0.4)
    }
    NSLog("[tapper] done, taps=%d", taps)
  }
}

import XCTest

/// iOS 模拟器「真实触摸」投递器（BUG-1692 iOS 浮层侧验证）。
///
/// 读宿主文件 `$TAP_DIR/req`（一行：`<seq> <x> <y> [press=<秒>] [drag=<x2>,<y2>]`，
/// 坐标是 iOS point = Flutter 逻辑 px，屏幕坐标），用 XCUITest 在该点投一次真实触摸——
/// 走模拟器 HID 通道，经 UIKit hitTest → FlutterTouchInterceptingView → WKWebView，
/// 与手指点按同一路径；处理完把 seq 写进 `$TAP_DIR/ack`。
///
/// 编排见 `../run_sim_touch_itest.sh`：Dart 侧打印 `[ios-touch] TAP ...`，桥脚本转成 req。
final class TouchTapperTests: XCTestCase {
  func testTapLoop() {
    let env = ProcessInfo.processInfo.environment
    let dir = env["TAP_DIR"] ?? "/tmp/fushi-ios-touch"
    let seconds = TimeInterval(env["TAPPER_SECONDS"] ?? "") ?? 900
    let deadline = Date().addingTimeInterval(seconds)
    let fushi = XCUIApplication(bundleIdentifier: env["TAP_BUNDLE"] ?? "app.fushi.reader")
    // XCUITest runner 起来时可能把被测 app 顶到后台；先拉回前台（不重启进程）。
    fushi.activate()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var last = ""
    NSLog("[touchtap] ready dir=%@", dir)
    try? "ready".write(toFile: dir + "/tapper_ready", atomically: true, encoding: .utf8)
    while Date() < deadline {
      if let req = try? String(contentsOfFile: dir + "/req", encoding: .utf8) {
        let line = req.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty && line != last {
          last = line
          let p = line.split(separator: " ")
          if p.count >= 3, let x = Double(p[1]), let y = Double(p[2]) {
            // 以 SpringBoard 的原点做屏幕坐标系，不依赖被测 app 的无障碍树快照。
            let origin = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let pt = origin.withOffset(CGVector(dx: x, dy: y))
            var press: Double = 0
            var drag: CGVector?
            for tok in p.dropFirst(3) {
              if tok.hasPrefix("press=") { press = Double(tok.dropFirst(6)) ?? 0 }
              if tok.hasPrefix("drag=") {
                let xy = tok.dropFirst(5).split(separator: ",")
                if xy.count == 2, let dx = Double(xy[0]), let dy = Double(xy[1]) {
                  drag = CGVector(dx: dx, dy: dy)
                }
              }
            }
            if let to = drag {
              pt.press(
                forDuration: max(press, 0.05), thenDragTo: origin.withOffset(to),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            } else if press > 0 {
              pt.press(forDuration: press)
            } else {
              pt.tap()
            }
            NSLog("[touchtap] done %@ at %.1f,%.1f", String(p[0]), x, y)
            try? String(p[0]).write(toFile: dir + "/ack", atomically: true, encoding: .utf8)
          }
        }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }
}

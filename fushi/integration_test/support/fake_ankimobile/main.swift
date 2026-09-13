// FakeAnkiMobile —— AnkiMobile 的模拟器替身（BUG-2493 iOS 实测用）。
//
// AnkiMobile 是付费 App Store app，装不进模拟器，所以 `infoForAdding` 往返的
// 「另一个 app 写系统剪贴板 + x-success 回跳」这两步在模拟器上没有真实对手。
// 本 app 只做这两步（与 AnkiMobile 官方手册 URL Schemes 一节逐字一致）：
//   anki://x-callback-url/infoForAdding?x-success=<url>
//   → 把 {"decks":[…],"notetypes":[…]} 以类型 `net.ankimobile.json` 写进
//     UIPasteboard.general → 打开 x-success。
//
// 为了在一条集成测试里覆盖三种回跳形态，按「本进程内第 N 次请求」切换行为
// （计数持久化在 UserDefaults，`defaults delete app.fushi.fakeankimobile` 归零）：
//   1 → 不写剪贴板 + 打开 x-success             （用户没同意 / AnkiMobile 没写）
//   2 → 写剪贴板 + 打开 x-success               （正常往返）
//   3 → 写剪贴板 + 打开 fushi://return-without-callback（回到前台但 x-success 没送达）
//   ≥4 → 同 2
// 「不写」排第一：模拟器上跨 app 读剪贴板会弹系统「允许粘贴」提示，没法自动点，
// 先把不需要提示的那一形态跑完，证据最多。
// 牌组名带上 rN，测试据此分辨落地的是哪一轮的数据。
//
// 用 swiftc 直接编成模拟器 .app，不走 Xcode 工程：见同目录 build_install.sh。

import UIKit

let pasteboardType = "net.ankimobile.json"
let requestCountKey = "requestCount"
let lastActionKey = "lastAction"

final class FakeAnkiViewController: UIViewController {
  let label = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(red: 0.16, green: 0.42, blue: 0.86, alpha: 1)
    label.numberOfLines = 0
    label.textAlignment = .center
    label.textColor = .white
    label.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
    label.text = "FakeAnkiMobile\nwaiting for infoForAdding"
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
    ])
  }

  func show(_ text: String) {
    label.text = text
    UserDefaults.standard.set(text, forKey: lastActionKey)
  }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let controller = FakeAnkiViewController()

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return true
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard url.scheme == "anki", url.host == "x-callback-url",
      url.path == "/infoForAdding"
    else {
      controller.show("ignored URL:\n\(url.absoluteString)")
      return false
    }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let success = components?.queryItems?.first { $0.name == "x-success" }?.value
    let defaults = UserDefaults.standard
    let n = defaults.integer(forKey: requestCountKey) + 1
    defaults.set(n, forKey: requestCountKey)

    let mode = n == 1 ? "noWrite" : (n == 3 ? "foregroundOnly" : "success")
    var target: URL? = success.flatMap(URL.init(string:))
    if mode == "foregroundOnly" {
      target = URL(string: "fushi://return-without-callback")
    }
    if mode != "noWrite" {
      let json = """
        {"decks":[{"name":"FakeDeck r\(n)"},{"name":"FakeDeck r\(n)::Sub"}],
         "notetypes":[{"name":"FakeBasic r\(n)","fields":[{"name":"Front"},{"name":"Back"},{"name":"Audio"}]}]}
        """
      UIPasteboard.general.setData(Data(json.utf8), forPasteboardType: pasteboardType)
    }
    controller.show("request #\(n) mode=\(mode)\nx-success=\(success ?? "nil")\nopening \(target?.absoluteString ?? "nil")")

    // AnkiMobile 那边有一次「允许 Fushi 读取牌组信息？」的确认，这里用 600 ms
    // 模拟那段停留，让 Fushi 真的退到后台、再被 URL 拉回前台。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      if let target = target {
        app.open(target, options: [:]) { ok in
          self.controller.show("request #\(n) mode=\(mode)\nopened \(target.absoluteString): \(ok)")
        }
      }
    }
    return true
  }
}

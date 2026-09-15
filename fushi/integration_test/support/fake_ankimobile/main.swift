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
// BUG-2532：替身也受理 addnote / search，好让「制卡 → 回跳 → Fushi 落账 → ✓ 亮」
// 这条链在模拟器上真的跑一遍。计数与最后一次内容同样持久化，测试结束后由
// run_sim_itest.sh 从替身容器的 plist 里读出来当证据。
let addNoteCountKey = "addNoteCount"
let lastAddNoteKey = "lastAddNote"
let lastSearchKey = "lastSearch"

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
    // 证据必须落盘：编排脚本是从替身容器的 plist 里读这些键的，而 UserDefaults
    // 平时攒着批量写——app 没被挂起就可能一个键都没落，让「什么都没发生」和
    // 「发生了但没刷盘」长得一模一样（BUG-2532 首轮实测就只看到 addNoteCount）。
    UserDefaults.standard.synchronize()
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
    guard url.scheme == "anki", url.host == "x-callback-url" else {
      controller.show("ignored URL:\n\(url.absoluteString)")
      return false
    }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    switch url.path {
    case "/infoForAdding":
      return handleInfoForAdding(app, components)
    case "/addnote":
      return handleAddNote(app, components)
    case "/search":
      return handleSearch(app, components)
    default:
      controller.show("ignored path: " + url.path)
      return false
    }
  }

  private func handleInfoForAdding(
    _ app: UIApplication,
    _ components: URLComponents?
  ) -> Bool {
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
  /// BUG-2532：手册对 addnote 的 `x-success` 定义是「after the note is added」，
  /// 所以替身也只在**收下这张卡之后**才回跳——Fushi 正是拿这一下当「已制卡」的
  /// 落账依据。字段原样存进 UserDefaults，测试后可从容器 plist 里取出当证据。
  private func handleAddNote(
    _ app: UIApplication,
    _ components: URLComponents?
  ) -> Bool {
    let items = components?.queryItems ?? []
    func value(_ name: String) -> String? {
      return items.first { $0.name == name }?.value
    }
    let defaults = UserDefaults.standard
    let n = defaults.integer(forKey: addNoteCountKey) + 1
    defaults.set(n, forKey: addNoteCountKey)
    let fields = items.filter { $0.name.hasPrefix("fld") }
      .map { "\($0.name.dropFirst(3))=\($0.value ?? "")" }
      .joined(separator: " | ")
    let summary = "deck=" + (value("deck") ?? "nil")
      + " type=" + (value("type") ?? "nil") + " | " + fields
    defaults.set(summary, forKey: lastAddNoteKey)
    defaults.synchronize()
    let success = value("x-success")
    controller.show("addnote #\(n)\n" + summary)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      guard let target = success.flatMap(URL.init(string:)) else { return }
      app.open(target, options: [:]) { ok in
        self.controller.show("addnote #\(n)\nopened " + target.absoluteString + ": " + String(ok))
      }
    }
    return true
  }

  /// `search` 手册里只有 `query` 一个参数，没有 x-success：真 AnkiMobile 会停在浏览
  /// 界面等用户自己切回去。替身立刻把 Fushi 拉回前台，免得集成测试卡在后台。
  private func handleSearch(
    _ app: UIApplication,
    _ components: URLComponents?
  ) -> Bool {
    let query = components?.queryItems?.first { $0.name == "query" }?.value ?? ""
    UserDefaults.standard.set(query, forKey: lastSearchKey)
    UserDefaults.standard.synchronize()
    controller.show("search\nquery=" + query)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      guard let back = URL(string: "fushi://return-without-callback") else { return }
      app.open(back, options: [:], completionHandler: nil)
    }
    return true
  }
}

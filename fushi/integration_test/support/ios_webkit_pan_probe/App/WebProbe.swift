import UIKit
import WebKit

// 最小 WKWebView 宿主：配置对齐 flutter_inappwebview（bounces=false、
// contentInsetAdjustmentBehavior=never、isTextInteractionEnabled=false），
// 全屏加载 /tmp/fushi-xaxis/page.html，把 scrollView 的 contentOffset / contentSize
// 每次变化追加到 /tmp/fushi-xaxis/offsets.log。
final class VC: UIViewController {
  var web: WKWebView!
  var obs: [NSKeyValueObservation] = []
  let log = "/tmp/fushi-xaxis/offsets.log"
  func append(_ s: String) {
    let line = s + "\n"
    if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: log, atomically: true, encoding: .utf8) }
  }
  override func viewDidLoad() {
    super.viewDidLoad()
    let cfg = WKWebViewConfiguration()
    if #available(iOS 14.5, *) { cfg.preferences.isTextInteractionEnabled = false }
    web = WKWebView(frame: view.bounds, configuration: cfg)
    web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    web.scrollView.bounces = false
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.scrollView.showsVerticalScrollIndicator = false
    web.scrollView.showsHorizontalScrollIndicator = false
    view.addSubview(web)
    let sv = web.scrollView
    obs.append(sv.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
      self?.append(String(format: "off %.1f %.1f size %.1f %.1f bounds %.1f %.1f drag %d",
        s.contentOffset.x, s.contentOffset.y, s.contentSize.width, s.contentSize.height,
        s.bounds.width, s.bounds.height, s.isDragging ? 1 : 0))
    })
    let url = URL(fileURLWithPath: "/tmp/fushi-xaxis/page.html")
    web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: "/tmp/fushi-xaxis"))
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let s = self?.web.scrollView else { return }
      self?.append(String(format: "loaded off %.1f %.1f size %.1f %.1f bounds %.1f %.1f",
        s.contentOffset.x, s.contentOffset.y, s.contentSize.width, s.contentSize.height,
        s.bounds.width, s.bounds.height))
    }
  }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let w = UIWindow(frame: UIScreen.main.bounds)
    w.rootViewController = VC()
    w.makeKeyAndVisible()
    window = w
    return true
  }
}

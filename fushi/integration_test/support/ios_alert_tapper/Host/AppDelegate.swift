import UIKit

// 只为让 XCUITest bundle 有一个宿主 app；测试本身只操作 SpringBoard。
final class HostViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGray
  }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = HostViewController()
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}

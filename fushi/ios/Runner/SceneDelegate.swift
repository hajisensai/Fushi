import UIKit
import Flutter

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let url = connectionOptions.urlContexts.first?.url {
      deliverUrl(url)
    }
    // 冷启动经 Home Screen quick action 进来：系统只放在 connectionOptions 里，
    // 不会再回调下面的 windowScene(_:performActionFor:)。
    if let shortcut = connectionOptions.shortcutItem {
      appDelegate?.deliverShortcut(shortcut)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // 热启动（app 已在后台）点 quick action。本 app 发布的快捷方式由我们消费；
  // 其余交回 FlutterSceneDelegate 转发给插件的 scene 生命周期。
  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    if appDelegate?.deliverShortcut(shortcutItem) == true {
      completionHandler(true)
      return
    }
    super.windowScene(
      windowScene, performActionFor: shortcutItem, completionHandler: completionHandler)
  }

  // 界面方向变了（含横屏左 ↔ 右翻转）：告诉应用内悬浮球灵动岛换到了哪条边
  // （BUG-2911，见 FushiFloatingBall.interfaceOrientationDidChange）。
  // 写 override 只是因为 FlutterSceneDelegate 声明遵守 UIWindowSceneDelegate，
  // Swift 把这条可选协议方法算作继承成员；它的 .mm 并没有实现这条回调。所以
  // **绝不能调 super**：UIKit 在建 scene 时就会回调这里，super 是向不存在的实现
  // 发消息，unrecognized selector 直接 abort（2.9.0 TestFlight 打开即闪退）。
  override func windowScene(
    _ windowScene: UIWindowScene,
    didUpdate previousCoordinateSpace: UICoordinateSpace,
    interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
    traitCollection previousTraitCollection: UITraitCollection
  ) {
    guard windowScene.interfaceOrientation != previousInterfaceOrientation else { return }
    FushiFloatingBall.interfaceOrientationDidChange(windowScene.interfaceOrientation)
  }

  private var appDelegate: AppDelegate? {
    UIApplication.shared.delegate as? AppDelegate
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    for context in URLContexts {
      deliverUrl(context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  private func deliverUrl(_ url: URL) {
    (UIApplication.shared.delegate as? AppDelegate)?.deliverUrl(url.absoluteString)
  }
}

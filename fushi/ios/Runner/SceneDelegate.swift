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

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
    super.scene(scene, willConnectTo: session, options: connectionOptions)
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

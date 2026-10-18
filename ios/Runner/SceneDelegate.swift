import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if !connectionOptions.urlContexts.isEmpty {
      (UIApplication.shared.delegate as? AppDelegate)?.handleOpenURLContexts(
        connectionOptions.urlContexts)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    (UIApplication.shared.delegate as? AppDelegate)?.handleOpenURLContexts(URLContexts)
  }
}

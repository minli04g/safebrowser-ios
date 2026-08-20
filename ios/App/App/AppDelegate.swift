import UIKit
import Capacitor
import WebKit
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DispatchQueue.main.async { [weak self] in
            self?.installNativeShellIfNeeded()
        }
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Claim the notification-center delegate so notification taps are handled
        // natively (see userNotificationCenter(_:didReceive:)). Re-asserted on
        // every foreground because @capacitor/push-notifications sets itself as the
        // delegate during WebView load; this runs before the tap's didReceive on a
        // background wake, so our handler wins. We deliberately don't rely on the
        // plugin's JS notification events — both the APNs token and the tap are
        // delivered via native evaluateJavaScript, the only reliable path for a
        // WebView loading a remote server.url.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // The @capacitor/push-notifications `registration` JS event doesn't reach a
        // remotely-loaded (server.url) WebView, so hand the lowercase hex token to
        // the dashboard global (window.__sbApnsToken) directly.
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        DispatchQueue.main.async {
            let js = "window.__sbApnsToken && window.__sbApnsToken('\(hex)')"
            if let nativeShell = self.nativeShell {
                nativeShell.evaluateJavaScript(js)
            } else {
                self.bridgeViewController?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Show the notification banner even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // Notification tapped. Like the token, the plugin's pushNotificationActionPerformed
    // JS event doesn't reliably reach a remote server.url WebView (especially on a
    // background wake), so deliver the identifier to the dashboard global via
    // evaluateJavaScript instead.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        // apns2 puts custom `data` at the payload root. Message taps take
        // precedence when both identifiers are present.
        if let conversationId = userInfo["conversationId"] as? String, !conversationId.isEmpty {
            openNativeMessage(conversationId)
        } else if let requestId = userInfo["requestId"] as? String, !requestId.isEmpty {
            openRequest(requestId)
        }
        completionHandler()
    }

    private func openRequest(_ requestId: String, attemptsLeft: Int = 30) {
        DispatchQueue.main.async {
            if let nativeShell = self.nativeShell {
                nativeShell.openRequest(requestId)
            } else if attemptsLeft > 0 {
                self.installNativeShellIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.openRequest(requestId, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    private func openNativeMessage(_ conversationId: String, attemptsLeft: Int = 30) {
        DispatchQueue.main.async {
            if let nativeShell = self.nativeShell {
                nativeShell.openMessage(conversationId)
            } else if attemptsLeft > 0 {
                self.installNativeShellIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.openNativeMessage(conversationId, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    private var nativeShell: NativeShellViewController? {
        window?.rootViewController as? NativeShellViewController
    }

    private var bridgeViewController: CAPBridgeViewController? {
        window?.rootViewController as? CAPBridgeViewController
    }

    private func installNativeShellIfNeeded(attemptsLeft: Int = 30) {
        guard nativeShell == nil else { return }
        guard let bridgeViewController else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.installNativeShellIfNeeded(attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        guard let shell = NativeShellViewController(bridgeViewController: bridgeViewController) else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.installNativeShellIfNeeded(attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }
        window?.rootViewController = shell
        window?.makeKeyAndVisible()
    }

}

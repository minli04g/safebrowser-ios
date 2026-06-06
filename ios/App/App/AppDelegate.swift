import UIKit
import Capacitor
import WebKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
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

    // Forward APNs registration callbacks to Capacitor so the
    // @capacitor/push-notifications `registration` / `registrationError` JS
    // events fire. Without these, iOS registers the app (it shows in Settings)
    // but the device token never reaches the web layer.
    // TEMP diagnostic: truly-native popup (independent of the WebView) so we can
    // see whether the APNs callbacks fire at all. Remove once push is verified.
    private func sbDiag(_ msg: String) {
        DispatchQueue.main.async {
            guard let root = self.window?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            let alert = UIAlertController(title: "native push", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            top.present(alert, animated: true)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let bridgeOk = (self.window?.rootViewController as? CAPBridgeViewController) != nil
        sbDiag("didRegister ✓ len=\(deviceToken.count) bridgeVC=\(bridgeOk)")
        DispatchQueue.main.async {
            let js = "window.__sbApnsToken && window.__sbApnsToken('\(hex)')"
            (self.window?.rootViewController as? CAPBridgeViewController)?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
        sbDiag("didFail: \(error.localizedDescription)")
    }

}

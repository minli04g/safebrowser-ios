import Capacitor
import Combine
import SwiftUI
import UIKit
import WebKit

private enum NativeShellTab: Int {
    case manage = 0
    case shortcutOne = 1
    case shortcutTwo = 2
    case shortcutThree = 3
    case messages = 4

    var shortcutIndex: Int? {
        switch self {
        case .shortcutOne: return 0
        case .shortcutTwo: return 1
        case .shortcutThree: return 2
        case .manage, .messages: return nil
        }
    }
}

private struct NativeManagementShortcut: Equatable {
    let slug: String
    let label: String
    let systemImage: String

    static let fallback: [NativeManagementShortcut] = [
        NativeManagementShortcut(slug: "usage", label: "Usage", systemImage: "chart.bar"),
        NativeManagementShortcut(slug: "allowlist", label: "Allowlist", systemImage: "checkmark.circle"),
        NativeManagementShortcut(slug: "time-limits", label: "Limits", systemImage: "clock")
    ]

    static func make(slug: String) -> NativeManagementShortcut? {
        switch slug {
        case "usage": return NativeManagementShortcut(slug: slug, label: "Usage", systemImage: "chart.bar")
        case "allowlist": return NativeManagementShortcut(slug: slug, label: "Allowlist", systemImage: "checkmark.circle")
        case "blacklist": return NativeManagementShortcut(slug: slug, label: "Blacklist", systemImage: "nosign")
        case "bookmarks": return NativeManagementShortcut(slug: slug, label: "Bookmarks", systemImage: "bookmark")
        case "youtube": return NativeManagementShortcut(slug: slug, label: "YouTube", systemImage: "play.rectangle")
        case "bilibili": return NativeManagementShortcut(slug: slug, label: "Bilibili", systemImage: "play.tv")
        case "time-limits": return NativeManagementShortcut(slug: slug, label: "Limits", systemImage: "clock")
        case "activity": return NativeManagementShortcut(slug: slug, label: "Activity", systemImage: "waveform.path.ecg")
        case "requests": return NativeManagementShortcut(slug: slug, label: "Requests", systemImage: "bell")
        default: return nil
        }
    }
}

final class NativeShellViewController: UIViewController, UITabBarDelegate, WKScriptMessageHandler {
    let bridgeViewController: CAPBridgeViewController

    private let webContainer = UIView()
    private let messagesContainer = UIView()
    private let tabBar = UITabBar()
    private let messageStore: NativeMessageStore
    private let messagesViewController: UIHostingController<NativeMessagesRootView>
    private var tabBarHeightConstraint: NSLayoutConstraint?
    private var shortcuts = NativeManagementShortcut.fallback
    private var currentDeviceId: String?
    private var cancellables = Set<AnyCancellable>()

    var webView: WKWebView? { bridgeViewController.webView }

    init?(bridgeViewController: CAPBridgeViewController) {
        bridgeViewController.loadViewIfNeeded()
        guard
            let webView = bridgeViewController.webView,
            let api = NativeMessageAPI(cookieStore: webView.configuration.websiteDataStore.httpCookieStore)
        else { return nil }

        let messageStore = NativeMessageStore(api: api)
        self.bridgeViewController = bridgeViewController
        self.messageStore = messageStore
        self.messagesViewController = UIHostingController(rootView: NativeMessagesRootView(
            store: messageStore,
            onOpenManage: {}
        ))
        super.init(nibName: nil, bundle: nil)

        messagesViewController.rootView = NativeMessagesRootView(store: messageStore) { [weak self] in
            self?.selectManage()
        }
        webView.configuration.userContentController.add(self, name: "safeBrowserShell")

        let nativeMarker = WKUserScript(
            source: "document.documentElement.dataset.safeBrowserNativeShell = 'true';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(nativeMarker)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "safeBrowserShell")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureChildren()
        configureTabBar()
        observeMessages()
        messageStore.start()
        showWebContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        evaluateJavaScript("window.dispatchEvent(new CustomEvent('sb:native-shell-ready'));")
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        tabBarHeightConstraint?.constant = 49 + view.safeAreaInsets.bottom
    }

    func openMessage(_ conversationId: String?) {
        messageStore.start()
        if let conversationId, !conversationId.isEmpty {
            messageStore.openConversation(conversationId)
        }
        showMessages()
        tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.messages.rawValue })
    }

    func openRequestInWebView(_ requestId: String) {
        selectManage()
        deliverIdentifierToWebView(requestId, global: "__sbOpenRequest")
    }

    func evaluateJavaScript(_ source: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        webView?.evaluateJavaScript(source, completionHandler: completionHandler)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "safeBrowserShell", let payload = message.body as? [String: Any] else { return }
        switch payload["type"] as? String {
        case "state":
            applyWebState(payload)
        case "openMessages":
            openMessage(payload["conversationId"] as? String)
        case "auth":
            if (payload["signedIn"] as? Bool) == false {
                messageStore.signOut()
            } else {
                messageStore.signIn()
            }
        default:
            break
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let destination = NativeShellTab(rawValue: item.tag) else { return }
        switch destination {
        case .manage:
            showWebContent()
        case .messages:
            openMessage(nil)
        case .shortcutOne, .shortcutTwo, .shortcutThree:
            guard let index = destination.shortcutIndex, shortcuts.indices.contains(index) else {
                selectManage()
                return
            }
            openManagementShortcut(shortcuts[index])
        }
    }

    private func configureChildren() {
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        messagesContainer.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)
        view.addSubview(messagesContainer)
        view.addSubview(tabBar)

        let tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 49)
        self.tabBarHeightConstraint = tabBarHeightConstraint
        NSLayoutConstraint.activate([
            webContainer.topAnchor.constraint(equalTo: view.topAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            messagesContainer.topAnchor.constraint(equalTo: view.topAnchor),
            messagesContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            messagesContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messagesContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabBarHeightConstraint
        ])

        embed(bridgeViewController, in: webContainer)
        embed(messagesViewController, in: messagesContainer)
    }

    private func embed(_ child: UIViewController, in container: UIView) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        child.didMove(toParent: self)
    }

    private func configureTabBar() {
        tabBar.delegate = self
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) { tabBar.scrollEdgeAppearance = appearance }
        rebuildTabItems()
        tabBar.selectedItem = tabBar.items?.first
    }

    private func rebuildTabItems() {
        let manage = UITabBarItem(title: "Manage", image: UIImage(systemName: "rectangle.grid.2x2"), tag: NativeShellTab.manage.rawValue)
        let shortcutItems = shortcuts.prefix(3).enumerated().map { index, shortcut in
            UITabBarItem(
                title: shortcut.label,
                image: UIImage(systemName: shortcut.systemImage),
                tag: NativeShellTab.shortcutOne.rawValue + index
            )
        }
        let messages = UITabBarItem(title: "Messages", image: UIImage(systemName: "message"), tag: NativeShellTab.messages.rawValue)
        let selectedTag = tabBar.selectedItem?.tag ?? NativeShellTab.manage.rawValue
        tabBar.items = [manage] + shortcutItems + [messages]
        tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == selectedTag }) ?? manage
    }

    private func observeMessages() {
        messageStore.$conversations
            .map { conversations in conversations.reduce(0) { $0 + $1.unreadCount } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                guard let item = self?.tabBar.items?.first(where: { $0.tag == NativeShellTab.messages.rawValue }) else { return }
                item.badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
            }
            .store(in: &cancellables)
    }

    private func applyWebState(_ payload: [String: Any]) {
        if let deviceId = payload["deviceId"] as? String, !deviceId.isEmpty {
            currentDeviceId = deviceId
            UserDefaults.standard.set(deviceId, forKey: "SafeBrowser.NativeShell.lastDeviceId")
        } else if currentDeviceId == nil {
            currentDeviceId = UserDefaults.standard.string(forKey: "SafeBrowser.NativeShell.lastDeviceId")
        }

        if let rawTabs = payload["tabs"] as? [String] {
            let configured = rawTabs.compactMap(NativeManagementShortcut.make(slug:))
            if configured.count == 3, configured != shortcuts {
                shortcuts = configured
                rebuildTabItems()
            }
        }

        guard messagesContainer.isHidden, let path = payload["path"] as? String else { return }
        if let index = shortcuts.firstIndex(where: { path.hasSuffix("/\($0.slug)") || path.contains("/\($0.slug)/") }) {
            tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.shortcutOne.rawValue + index })
        } else {
            tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.manage.rawValue })
        }
    }

    private func openManagementShortcut(_ shortcut: NativeManagementShortcut) {
        guard let deviceId = currentDeviceId ?? UserDefaults.standard.string(forKey: "SafeBrowser.NativeShell.lastDeviceId") else {
            selectManage()
            return
        }
        showWebContent()
        let path = "/devices/\(encodePathComponent(deviceId))/\(shortcut.slug)"
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let source = "window.history.pushState({}, '', '\(escaped)'); window.dispatchEvent(new PopStateEvent('popstate'));"
        evaluateJavaScript(source)
    }

    private func selectManage() {
        showWebContent()
        tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.manage.rawValue })
    }

    private func showWebContent() {
        messagesViewController.view.endEditing(true)
        webContainer.isHidden = false
        messagesContainer.isHidden = true
    }

    private func showMessages() {
        bridgeViewController.view.endEditing(true)
        webContainer.isHidden = true
        messagesContainer.isHidden = false
    }

    private func deliverIdentifierToWebView(_ identifier: String, global: String, attemptsLeft: Int = 30) {
        let escaped = identifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let source = "(window.\(global) ? (window.\(global)('\(escaped)'), true) : false)"
        evaluateJavaScript(source) { [weak self] result, _ in
            guard !((result as? Bool) ?? false), attemptsLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.deliverIdentifierToWebView(identifier, global: global, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    private func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

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
    private let manageContainer = UIView()
    private let messagesContainer = UIView()
    private let tabBar = UITabBar()
    private let messageStore: NativeMessageStore
    private let manageStore: NativeManageStore
    private let messagesViewController: UIHostingController<NativeMessagesRootView>
    private let manageViewController: UIHostingController<NativeManageRootView>
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
        let manageStore = NativeManageStore(api: api)
        self.bridgeViewController = bridgeViewController
        self.messageStore = messageStore
        self.manageStore = manageStore
        self.messagesViewController = UIHostingController(rootView: NativeMessagesRootView(
            store: messageStore,
            onOpenManage: {}
        ))
        self.manageViewController = UIHostingController(rootView: NativeManageRootView(
            store: manageStore,
            onOpenDevice: { _ in },
            onOpenAccount: {},
            onOpenSignIn: {}
        ))
        super.init(nibName: nil, bundle: nil)

        messagesViewController.rootView = NativeMessagesRootView(store: messageStore) { [weak self] in
            self?.selectManage()
        }
        manageViewController.rootView = NativeManageRootView(
            store: manageStore,
            onOpenDevice: { [weak self] deviceId in self?.openDevice(deviceId) },
            onOpenAccount: { [weak self] in self?.openWebRoute("/account") },
            onOpenSignIn: { [weak self] in self?.openWebRoute("/login") }
        )
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
        manageStore.start()
        showManageSummary()
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
            rememberDeviceFromConversation(conversationId)
            messageStore.openConversation(conversationId)
        }
        showMessages()
        tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.messages.rawValue })
    }

    func openRequest(_ requestId: String) {
        manageStore.focusRequest(requestId)
        selectManage()
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
        case "openManage":
            if let requestId = payload["requestId"] as? String, !requestId.isEmpty {
                openRequest(requestId)
            } else {
                selectManage()
            }
        case "auth":
            if (payload["signedIn"] as? Bool) == false {
                messageStore.signOut()
                manageStore.signOut()
            } else {
                messageStore.signIn()
                manageStore.signIn()
            }
        default:
            break
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let destination = NativeShellTab(rawValue: item.tag) else { return }
        switch destination {
        case .manage:
            showManageSummary()
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
        manageContainer.translatesAutoresizingMaskIntoConstraints = false
        messagesContainer.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webContainer)
        view.addSubview(manageContainer)
        view.addSubview(messagesContainer)
        view.addSubview(tabBar)

        let tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 49)
        self.tabBarHeightConstraint = tabBarHeightConstraint
        NSLayoutConstraint.activate([
            webContainer.topAnchor.constraint(equalTo: view.topAnchor),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
            manageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            manageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            manageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            manageContainer.bottomAnchor.constraint(equalTo: tabBar.topAnchor),
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
        embed(manageViewController, in: manageContainer)
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

        manageStore.$requests
            .receive(on: RunLoop.main)
            .sink { [weak self] requests in
                guard let self, let item = self.tabBar.items?.first(where: { $0.tag == NativeShellTab.manage.rawValue }) else { return }
                let count = requests.count
                item.badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
                if
                    let focusRequestId = self.manageStore.focusRequestId,
                    let request = requests.first(where: { $0.id == focusRequestId })
                {
                    self.rememberDevice(request.deviceId)
                }
            }
            .store(in: &cancellables)

        manageStore.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self, !devices.isEmpty else { return }
                let savedDeviceId = UserDefaults.standard.string(forKey: "SafeBrowser.NativeShell.lastDeviceId")
                if
                    let candidate = self.currentDeviceId ?? savedDeviceId,
                    devices.contains(where: { $0.id == candidate })
                {
                    self.currentDeviceId = candidate
                } else if let firstDevice = devices.first {
                    self.rememberDevice(firstDevice.id)
                }
            }
            .store(in: &cancellables)

        messageStore.$parentEventVersion
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.messageStore.lastParentEventType == "request.created" ||
                    self.messageStore.lastParentEventType == "request.resolved" ||
                    self.messageStore.lastParentEventType == "presence.changed"
                {
                    Task { await self.manageStore.refresh() }
                }
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

        guard !webContainer.isHidden, let path = payload["path"] as? String else { return }
        if path == "/" {
            selectManage()
            return
        }
        if let index = shortcuts.firstIndex(where: { path.hasSuffix("/\($0.slug)") || path.contains("/\($0.slug)/") }) {
            tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.shortcutOne.rawValue + index })
        } else {
            tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.manage.rawValue })
        }
    }

    private func openManagementShortcut(_ shortcut: NativeManagementShortcut) {
        guard let deviceId = currentDeviceId
            ?? UserDefaults.standard.string(forKey: "SafeBrowser.NativeShell.lastDeviceId")
            ?? manageStore.devices.first?.id
        else {
            selectManage()
            return
        }
        rememberDevice(deviceId)
        let path = "/devices/\(encodePathComponent(deviceId))/\(shortcut.slug)"
        openWebRoute(path)
    }

    private func selectManage() {
        showManageSummary()
        tabBar.selectedItem = tabBar.items?.first(where: { $0.tag == NativeShellTab.manage.rawValue })
    }

    private func openDevice(_ deviceId: String) {
        rememberDevice(deviceId)
        openManagementShortcut(shortcuts[0])
    }

    private func rememberDeviceFromConversation(_ conversationId: String) {
        let prefix = "direct:parent:"
        guard conversationId.hasPrefix(prefix) else { return }
        let deviceId = String(conversationId.dropFirst(prefix.count))
        if !deviceId.isEmpty { rememberDevice(deviceId) }
    }

    private func rememberDevice(_ deviceId: String) {
        currentDeviceId = deviceId
        UserDefaults.standard.set(deviceId, forKey: "SafeBrowser.NativeShell.lastDeviceId")
    }

    private func openWebRoute(_ path: String) {
        showWebContent()
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let source = "window.__sbNativeNavigate ? window.__sbNativeNavigate('\(escaped)') : window.location.assign('\(escaped)');"
        evaluateJavaScript(source)
    }

    private func showWebContent() {
        messagesViewController.view.endEditing(true)
        webContainer.isHidden = false
        manageContainer.isHidden = true
        messagesContainer.isHidden = true
    }

    private func showManageSummary() {
        messagesViewController.view.endEditing(true)
        bridgeViewController.view.endEditing(true)
        webContainer.isHidden = true
        manageContainer.isHidden = false
        messagesContainer.isHidden = true
        manageStore.start()
    }

    private func showMessages() {
        bridgeViewController.view.endEditing(true)
        webContainer.isHidden = true
        manageContainer.isHidden = true
        messagesContainer.isHidden = false
    }

    private func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

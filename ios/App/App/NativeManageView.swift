import SwiftUI

struct NativeDeviceSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatarLabel: String?
    let avatarUrl: String?
    let registeredAt: Double
    let lastSeenAt: Double?

    var isOnline: Bool {
        guard let lastSeenAt else { return false }
        return Date().timeIntervalSince1970 * 1_000 - lastSeenAt < 120_000
    }
}

struct NativeAccessRequest: Codable, Identifiable, Hashable {
    let id: String
    let deviceId: String
    let deviceName: String
    let kind: String
    let status: String
    let requestedMinutes: Int
    let target: String?
    let targetLabel: String?
    let videoTitle: String?
    let createdAt: Double
    let staleAt: Double

    var approvalMinutes: Int {
        if kind == "allow-download" || kind == "allow-video" { return 1 }
        return min(240, max(1, requestedMinutes))
    }

    var kindLabel: String {
        switch kind {
        case "extend-daily": return "More browsing time"
        case "allow-site": return "Allow site"
        case "extend-site": return "More site time"
        case "extend-pool": return "More group time"
        case "allow-download": return "Allow download"
        case "allow-video": return "Allow video"
        default: return kind
        }
    }

    var targetText: String? {
        videoTitle ?? targetLabel ?? target
    }
}

struct NativeDevicesResponse: Codable {
    let devices: [NativeDeviceSummary]
}

struct NativePendingRequestsResponse: Codable {
    let requests: [NativeAccessRequest]
}

struct NativeApproveRequestBody: Codable {
    let minutes: Int
}

struct NativeApproveRequestResponse: Codable {
    let effectiveMinutes: Int
}

@MainActor
final class NativeManageStore: ObservableObject {
    @Published private(set) var devices: [NativeDeviceSummary] = []
    @Published private(set) var requests: [NativeAccessRequest] = []
    @Published private(set) var isLoading = false
    @Published private(set) var actionRequestId: String?
    @Published var errorText: String?
    @Published var noticeText: String?
    @Published private(set) var requiresSignIn = false
    @Published var focusRequestId: String?

    let api: NativeMessageAPI
    private var signedOut = false

    init(api: NativeMessageAPI) {
        self.api = api
    }

    func start() {
        guard !signedOut else { return }
        Task { await refresh() }
    }

    func signIn() {
        signedOut = false
        requiresSignIn = false
        errorText = nil
        start()
    }

    func signOut() {
        signedOut = true
        requiresSignIn = true
        devices = []
        requests = []
        focusRequestId = nil
        errorText = nil
        noticeText = nil
    }

    func focusRequest(_ requestId: String) {
        focusRequestId = requestId
        Task { await refresh() }
    }

    func refresh() async {
        guard !signedOut else { return }
        isLoading = devices.isEmpty && requests.isEmpty
        defer { isLoading = false }
        do {
            async let fetchedDevices = api.listDevices()
            async let fetchedRequests = api.listPendingRequests()
            let (deviceRows, requestRows) = try await (fetchedDevices, fetchedRequests)
            devices = deviceRows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            requests = requestRows.sorted { $0.createdAt > $1.createdAt }
            requiresSignIn = false
            errorText = nil
        } catch {
            if let apiError = error as? NativeMessageAPIError {
                if case .unauthorized = apiError { requiresSignIn = true }
            }
            errorText = error.localizedDescription
        }
    }

    func approve(_ request: NativeAccessRequest, minutes: Int) async {
        guard actionRequestId == nil else { return }
        actionRequestId = request.id
        defer { actionRequestId = nil }
        do {
            let effective = try await api.approveRequest(
                deviceId: request.deviceId,
                requestId: request.id,
                minutes: minutes
            )
            if request.kind == "allow-download" || request.kind == "allow-video" {
                noticeText = "Request approved."
            } else {
                noticeText = "Approved for \(effective) min."
            }
            focusRequestId = nil
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func reject(_ request: NativeAccessRequest) async {
        guard actionRequestId == nil else { return }
        actionRequestId = request.id
        defer { actionRequestId = nil }
        do {
            try await api.rejectRequest(deviceId: request.deviceId, requestId: request.id)
            noticeText = "Request rejected."
            focusRequestId = nil
            await refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct NativeManageRootView: View {
    @StateObject private var store: NativeManageStore
    let onOpenDevice: (String) -> Void
    let onOpenAccount: () -> Void
    let onOpenSignIn: () -> Void

    init(
        store: NativeManageStore,
        onOpenDevice: @escaping (String) -> Void,
        onOpenAccount: @escaping () -> Void,
        onOpenSignIn: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: store)
        self.onOpenDevice = onOpenDevice
        self.onOpenAccount = onOpenAccount
        self.onOpenSignIn = onOpenSignIn
    }

    var body: some View {
        NavigationView {
            Group {
                if store.requiresSignIn {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 42))
                            .foregroundColor(.secondary)
                        Text("Sign in to manage your family devices.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open Sign In", action: onOpenSignIn)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(28)
                } else if store.isLoading {
                    ProgressView("Loading summary...")
                } else {
                    summaryList
                }
            }
            .navigationTitle("Manage")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onOpenAccount) {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account settings")
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { store.start() }
        .alert("Manage", isPresented: Binding(
            get: { store.noticeText != nil },
            set: { if !$0 { store.noticeText = nil } }
        )) {
            Button("OK", role: .cancel) { store.noticeText = nil }
        } message: {
            Text(store.noticeText ?? "")
        }
    }

    private var summaryList: some View {
        ScrollViewReader { proxy in
            List {
                if let error = store.errorText {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
                Section("Pending approvals") {
                    if store.requests.isEmpty {
                        Label("No pending requests", systemImage: "checkmark.circle")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.requests) { request in
                            NativeRequestSummaryRow(
                                request: request,
                                isFocused: store.focusRequestId == request.id,
                                isWorking: store.actionRequestId == request.id,
                                onApprove: { minutes in Task { await store.approve(request, minutes: minutes) } },
                                onReject: { Task { await store.reject(request) } }
                            )
                            .id(request.id)
                            .listRowBackground(
                                store.focusRequestId == request.id
                                    ? Color.accentColor.opacity(0.10)
                                    : Color(.systemBackground)
                            )
                        }
                    }
                }
                Section("Devices") {
                    ForEach(store.devices) { device in
                        Button { onOpenDevice(device.id) } label: {
                            HStack(spacing: 12) {
                                ZStack(alignment: .bottomTrailing) {
                                    NativeAvatar(
                                        url: store.api.absoluteURL(device.avatarUrl),
                                        label: device.avatarLabel ?? device.name,
                                        size: 42
                                    )
                                    Circle()
                                        .fill(device.isOnline ? Color.green : Color(.systemGray4))
                                        .frame(width: 11, height: 11)
                                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name).font(.headline).foregroundColor(.primary)
                                    Text(device.isOnline ? "Online" : lastSeenText(device.lastSeenAt))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
            .onAppear { scrollToFocusedRequest(proxy) }
            .onChange(of: store.focusRequestId) { _ in scrollToFocusedRequest(proxy) }
            .onChange(of: store.requests.count) { _ in scrollToFocusedRequest(proxy) }
        }
    }

    private func scrollToFocusedRequest(_ proxy: ScrollViewProxy) {
        guard let requestId = store.focusRequestId else { return }
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(requestId, anchor: .center) }
        }
    }

    private func lastSeenText(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "Never connected" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last seen \(formatter.localizedString(for: Date(timeIntervalSince1970: milliseconds / 1_000), relativeTo: Date()))"
    }
}

private struct NativeRequestSummaryRow: View {
    let request: NativeAccessRequest
    let isFocused: Bool
    let isWorking: Bool
    let onApprove: (Int) -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(request.deviceName).font(.headline)
                Spacer()
                Text(relativeTime(request.createdAt)).font(.caption).foregroundColor(.secondary)
            }
            Text(request.kindLabel).font(.subheadline.weight(.medium))
            if let target = request.targetText {
                Text(target).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
            }
            if request.kind != "allow-download" && request.kind != "allow-video" {
                Text("Requests \(request.requestedMinutes) min")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                Spacer()
                if request.kind == "allow-download" || request.kind == "allow-video" {
                    Button("Approve") { onApprove(1) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                } else {
                    Button("Approve \(request.approvalMinutes)m") { onApprove(request.approvalMinutes) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                    Menu {
                        Button("15 minutes") { onApprove(15) }
                        Button("30 minutes") { onApprove(30) }
                        Button("60 minutes") { onApprove(60) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isWorking)
                }
            }
            if isWorking { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .leading) {
            if isFocused {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
            }
        }
    }

    private func relativeTime(_ milliseconds: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: milliseconds / 1_000), relativeTo: Date())
    }
}

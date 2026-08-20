import SwiftUI
import UIKit

struct NativeDeviceSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatarLabel: String?
    let avatarUrl: String?
    let registeredAt: Double
    let lastSeenAt: Double?
    let lastClientOs: String?

    var isOnline: Bool {
        guard let lastSeenAt else { return false }
        return Date().timeIntervalSince1970 * 1_000 - lastSeenAt < 120_000
    }

    var systemImage: String {
        let platform = lastClientOs?.lowercased() ?? ""
        if platform.contains("ios") || platform.contains("ipad") { return "ipad" }
        if platform.contains("darwin") || platform.contains("mac") { return "laptopcomputer" }
        if platform.contains("win") { return "pc" }
        return "desktopcomputer"
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
    let videoOwnerName: String?
    let videoAiRating: String?
    let videoEffectiveRating: String?
    let videoAiReason: String?
    let timeZone: String?
    let targetUsageTodayMs: Double?
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        dismissKeyboard()
                    } label: {
                        Label("Done", systemImage: "keyboard.chevron.compact.down")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { store.start() }
        .overlay {
            if let notice = store.noticeText {
                NativeManageNoticeOverlay(message: notice) {
                    store.noticeText = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.noticeText)
    }

    private var summaryList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let error = store.errorText {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    NativeManageSectionHeader(
                        title: "Pending approvals",
                        count: store.requests.count,
                        systemImage: "bell.badge"
                    )

                    if store.requests.isEmpty {
                        Label("No pending requests", systemImage: "checkmark.circle")
                            .foregroundColor(.secondary)
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        ForEach(store.requests) { request in
                            NativeRequestSummaryCard(
                                request: request,
                                api: store.api,
                                isFocused: store.focusRequestId == request.id,
                                isWorking: store.actionRequestId == request.id,
                                onApprove: { minutes in Task { await store.approve(request, minutes: minutes) } },
                                onReject: { Task { await store.reject(request) } }
                            )
                            .id(request.id)
                        }
                    }

                    NativeManageSectionHeader(
                        title: "Devices",
                        count: store.devices.count,
                        systemImage: "desktopcomputer"
                    )

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 154), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(store.devices) { device in
                            Button { onOpenDevice(device.id) } label: {
                                NativeDeviceManagementCard(device: device)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
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

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

}

private struct NativeManageNoticeOverlay: View {
    let message: String
    let onDismiss: () -> Void

    private var wasRejected: Bool {
        message.localizedCaseInsensitiveContains("rejected")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                Image(systemName: wasRejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundColor(wasRejected ? Color(.systemOrange) : Color(.systemGreen))

                VStack(spacing: 6) {
                    Text(wasRejected ? "Request rejected" : "Request approved")
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: onDismiss) {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(wasRejected ? Color(.systemOrange) : Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 310)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.5), lineWidth: 0.7)
            }
            .shadow(color: Color.black.opacity(0.18), radius: 24, y: 10)
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct NativeManageSectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
            Text(title)
                .font(.title3.weight(.bold))
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemFill))
                .clipShape(Capsule())
            Spacer()
        }
    }
}

private struct NativeDeviceManagementCard: View {
    let device: NativeDeviceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: device.systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Circle()
                        .fill(device.isOnline ? Color.green : Color(.systemGray3))
                        .frame(width: 7, height: 7)
                    Text(device.isOnline ? "Online" : "Offline")
                }
                .font(.caption2.weight(.semibold))
                .foregroundColor(device.isOnline ? .green : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(device.isOnline ? "Seen just now" : lastSeenText(device.lastSeenAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Divider()

            HStack {
                Text("Open management")
                    .font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(.accentColor)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.7)
        }
    }

    private func lastSeenText(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "Never connected" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Seen \(formatter.localizedString(for: Date(timeIntervalSince1970: milliseconds / 1_000), relativeTo: Date()))"
    }
}

private struct NativeSelectAllNumberField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.keyboardType = .numberPad
        textField.textAlignment = .center
        textField.font = .systemFont(ofSize: 16, weight: .semibold)
        textField.textColor = .systemBlue
        textField.borderStyle = .none
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        if textField.text != text { textField.text = text }

        if isFocused, !textField.isFirstResponder {
            DispatchQueue.main.async {
                guard isFocused else { return }
                textField.becomeFirstResponder()
                textField.selectAll(nil)
            }
        } else if !isFocused, textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeSelectAllNumberField

        init(parent: NativeSelectAllNumberField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isFocused { parent.isFocused = true }
            DispatchQueue.main.async { textField.selectAll(nil) }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}

private struct NativeBilibiliRequestCover: View {
    let api: NativeMessageAPI
    let deviceId: String
    let bvid: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: "play.rectangle.fill")
                .font(.title2)
                .foregroundColor(.secondary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: 112, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: bvid) {
            image = nil
            guard let bvid, !bvid.isEmpty else { return }
            guard
                let data = try? await api.bilibiliCoverData(deviceId: deviceId, bvid: bvid),
                !Task.isCancelled
            else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }
}

private struct NativeVideoRatingMetric: View {
    let label: String
    let rating: String?
    let presentsAsBadge: Bool

    private var value: String { rating ?? "Unavailable" }

    private var tone: Color {
        switch rating {
        case "不适合": return Color(.systemRed)
        case "需家长陪同": return Color(.systemOrange)
        case "适合儿童": return Color(.systemGreen)
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(0.4)

            if presentsAsBadge {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(tone)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(tone.opacity(0.11))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tone)
                        .frame(width: 7, height: 7)
                    Text(value)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
                .frame(minHeight: 24)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct NativeRequestSummaryCard: View {
    let request: NativeAccessRequest
    let api: NativeMessageAPI
    let isFocused: Bool
    let isWorking: Bool
    let onApprove: (Int) -> Void
    let onReject: () -> Void

    @State private var selectedMinutes = 30
    @State private var customMode = false
    @State private var customInput = ""
    @State private var customFieldFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(request.deviceName)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(relativeTime(request.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 7) {
                    Text("PENDING")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Color(.systemOrange))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(.systemOrange).opacity(0.11))
                        .clipShape(Capsule())
                    Text(request.kindLabel)
                        .font(.subheadline.weight(.medium))
                    if let target = request.targetText {
                        Text(target)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))

            Divider()

            requestBody
                .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if requestNeedsDuration {
                    Text("DURATION")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                        .tracking(0.8)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach([15, 30, 60], id: \.self) { minutes in
                                durationChip("\(minutes)m", active: !customMode && selectedMinutes == minutes) {
                                    selectedMinutes = minutes
                                    customMode = false
                                    customInput = ""
                                    customFieldFocused = false
                                }
                            }
                            if customMode {
                                customDurationChip
                            } else {
                                durationChip("+ Custom", active: false) {
                                    customMode = true
                                    customInput = ""
                                    DispatchQueue.main.async { customFieldFocused = true }
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    actionButton("Reject", systemImage: "xmark", primary: false, action: onReject)
                    actionButton(approveLabel, systemImage: "checkmark", primary: true) {
                        onApprove(requestNeedsDuration ? selectedMinutes : 1)
                    }
                    .disabled(!canApprove)
                    .opacity(canApprove ? 1 : 0.5)
                }

                if isWorking {
                    ProgressView("Updating request...")
                        .font(.caption)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(
                    isFocused ? Color.accentColor : Color(.separator).opacity(0.38),
                    lineWidth: isFocused ? 2 : 0.7
                )
        }
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
        .disabled(isWorking)
    }

    @ViewBuilder
    private var requestBody: some View {
        if request.kind == "allow-download" {
            VStack(alignment: .leading, spacing: 5) {
                Text("DOWNLOAD REQUEST")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                Text("Wants to download a file from \(request.target ?? "an unknown page")")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }
        } else if request.kind == "allow-video" {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    NativeBilibiliRequestCover(
                        api: api,
                        deviceId: request.deviceId,
                        bvid: request.target
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(request.videoTitle ?? request.target ?? "Bilibili video")
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(request.videoOwnerName ?? "Unknown uploader") · \(request.target ?? "Unknown BVID")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 22) {
                    NativeVideoRatingMetric(
                        label: "AI RATING",
                        rating: request.videoAiRating,
                        presentsAsBadge: false
                    )
                    NativeVideoRatingMetric(
                        label: "EFFECTIVE RATING",
                        rating: request.videoEffectiveRating,
                        presentsAsBadge: true
                    )
                }

                if let reason = request.videoAiReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(videoExpiryText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            HStack(spacing: 28) {
                requestMetric(label: "REQUEST", value: "+\(request.requestedMinutes)", unit: "min")
                if request.kind == "allow-site" || request.kind == "extend-site" {
                    requestMetric(label: "USED TODAY", value: usageTodayText, unit: "")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var requestNeedsDuration: Bool {
        request.kind != "allow-download" && request.kind != "allow-video"
    }

    private var videoExpiryText: String {
        let suffix = request.timeZone.map { " (\($0))" } ?? ""
        return "Access expires at midnight on the child device\(suffix)."
    }

    private var approveLabel: String {
        if request.kind == "allow-video" { return "Allow until midnight" }
        if request.kind == "allow-download" { return "Approve" }
        return "Approve · \(canApprove ? String(selectedMinutes) : "–")m"
    }

    private var canApprove: Bool {
        guard customMode else { return true }
        guard let minutes = Int(customInput) else { return false }
        return (1...240).contains(minutes)
    }

    private var usageTodayText: String {
        let totalMinutes = max(0, Int(((request.targetUsageTodayMs ?? 0) / 60_000).rounded()))
        guard totalMinutes >= 60 else { return "\(totalMinutes) min" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }

    private func durationChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(active ? .accentColor : .primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(active ? Color.accentColor.opacity(0.10) : Color(.systemBackground))
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(
                        active ? Color.accentColor.opacity(0.25) : Color(.separator).opacity(0.45),
                        lineWidth: 0.7
                    )
                }
        }
        .buttonStyle(.plain)
    }

    private var customDurationChip: some View {
        HStack(spacing: 2) {
            NativeSelectAllNumberField(
                text: $customInput,
                isFocused: $customFieldFocused
            )
                .frame(width: 44, height: 32)
                .onChange(of: customInput) { value in
                    if let minutes = Int(value), (1...240).contains(minutes) {
                        selectedMinutes = minutes
                    }
                }
            Text("m")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundColor(.accentColor)
        .padding(.horizontal, 10)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Custom approval minutes")
    }

    private func actionButton(
        _ label: String,
        systemImage: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .foregroundColor(primary ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 43)
                .background(primary ? Color.accentColor : Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(.separator).opacity(0.45), lineWidth: 0.7)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func requestMetric(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundColor(.secondary)
                .tracking(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func relativeTime(_ milliseconds: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: milliseconds / 1_000), relativeTo: Date())
    }
}

import AVFoundation
import SwiftUI

@MainActor
final class NativeMessageStore: ObservableObject {
    @Published private(set) var conversations: [NativeMessageConversation] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    @Published var selectedConversationId: String?
    @Published private(set) var changeVersion = 0
    @Published private(set) var changedConversationId: String?
    @Published private(set) var parentEventVersion = 0
    @Published private(set) var lastParentEventType: String?

    let api: NativeMessageAPI
    private var started = false
    private var socketTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var signedOut = false

    init(api: NativeMessageAPI) {
        self.api = api
    }

    func start() {
        guard !signedOut else { return }
        guard !started else {
            Task { await refresh() }
            return
        }
        started = true
        Task { await refresh() }
        socketTask = Task { await runSocketLoop() }
    }

    func signIn() {
        signedOut = false
        errorText = nil
        start()
    }

    func signOut() {
        signedOut = true
        started = false
        socketTask?.cancel()
        socketTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        conversations = []
        selectedConversationId = nil
        changedConversationId = nil
        lastParentEventType = nil
        errorText = "Sign in from Manage to use Messages."
    }

    func refresh() async {
        guard !signedOut else { return }
        isLoading = conversations.isEmpty
        defer { isLoading = false }
        do {
            conversations = try await api.listConversations().sorted {
                ($0.latest?.createdAt ?? 0) > ($1.latest?.createdAt ?? 0)
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    func clearUnread(conversationId: String) {
        conversations = conversations.map { conversation in
            guard conversation.id == conversationId else { return conversation }
            return NativeMessageConversation(
                id: conversation.id,
                kind: conversation.kind,
                label: conversation.label,
                avatarUrl: conversation.avatarUrl,
                canSend: conversation.canSend,
                latest: conversation.latest,
                unreadCount: 0,
                presence: conversation.presence,
                members: conversation.members
            )
        }
    }

    func openConversation(_ conversationId: String) {
        guard !signedOut else { return }
        selectedConversationId = conversationId
        Task { await refresh() }
    }

    private func runSocketLoop() async {
        while !Task.isCancelled {
            do {
                let socket = try await api.makeParentWebSocket()
                webSocket = socket
                socket.resume()
                await refresh()
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    guard let event = try? JSONDecoder().decode(NativeParentSocketEvent.self, from: data) else { continue }
                    lastParentEventType = event.type
                    parentEventVersion += 1
                    if event.type == "messages.changed" {
                        changedConversationId = event.conversationId
                        changeVersion += 1
                        await refresh()
                    }
                }
            } catch {
                webSocket?.cancel(with: .goingAway, reason: nil)
                webSocket = nil
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

struct NativeMessagesRootView: View {
    @StateObject private var store: NativeMessageStore
    let onOpenManage: () -> Void

    init(store: NativeMessageStore, onOpenManage: @escaping () -> Void) {
        _store = StateObject(wrappedValue: store)
        self.onOpenManage = onOpenManage
    }

    var body: some View {
        NavigationView {
            Group {
                if store.isLoading && store.conversations.isEmpty {
                    ProgressView("Loading messages...")
                } else if store.conversations.isEmpty, let error = store.errorText {
                    NativeMessagesErrorView(message: error, onOpenManage: onOpenManage) {
                        Task { await store.refresh() }
                    }
                } else {
                    List(store.conversations) { conversation in
                        NavigationLink(
                            destination: NativeMessageThreadView(conversation: conversation, store: store),
                            tag: conversation.id,
                            selection: $store.selectedConversationId
                        ) {
                            NativeConversationRow(conversation: conversation, api: store.api)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle("Messages")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh messages")
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { store.start() }
    }
}

private struct NativeMessagesErrorView: View {
    let message: String
    let onOpenManage: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.badge")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Open Manage", action: onOpenManage)
                .buttonStyle(.borderedProminent)
            Button("Try Again", action: onRetry)
        }
        .padding(28)
    }
}

private struct NativeConversationRow: View {
    let conversation: NativeMessageConversation
    let api: NativeMessageAPI

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                NativeAvatar(url: api.absoluteURL(conversation.avatarUrl), label: conversation.displayLabel, size: 48)
                Circle()
                    .fill(conversation.presence.onlineCount > 0 ? Color.green : Color(.systemGray4))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(conversation.displayLabel).font(.headline)
                    Spacer()
                    if let date = conversation.latest?.date {
                        Text(date, style: .time).font(.caption).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount > 99 ? "99+" : String(conversation.unreadCount))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .frame(minHeight: 20)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        guard let message = conversation.latest else { return "No messages yet" }
        let content = message.voice == nil ? message.text : "Voice message"
        if message.isOwn { return "You: \(content)" }
        if conversation.kind == "family" { return "\(message.senderLabel): \(content)" }
        return content
    }
}

private enum NativeDeliveryState: Equatable {
    case sending
    case sent
    case failed
}

private struct NativeDisplayMessage: Identifiable {
    let id: String
    var record: NativeMessageRecord
    var delivery: NativeDeliveryState
}

private struct NativeMessageThreadView: View {
    let conversation: NativeMessageConversation
    @ObservedObject var store: NativeMessageStore

    @State private var messages: [NativeDisplayMessage] = []
    @State private var nextBefore: String?
    @State private var loading = false
    @State private var draft = ""
    @State private var selectedMentions: [NativeMessageActor] = []
    @State private var sendError: String?
    @State private var quickEmojisVisible = false
    @State private var hasScrolledToLatest = false
    @State private var pendingScrollTask: Task<Void, Never>?
    @StateObject private var recorder = NativeVoiceRecorder()
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageHistory
            if conversation.canSend { composer }
        }
        .navigationTitle(conversation.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(conversation.displayLabel).font(.headline)
                    Text(conversation.presence.onlineCount > 0 ? "Online" : "Offline")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .task { await loadMessages() }
        .onChange(of: store.changeVersion) { _ in
            guard store.changedConversationId == conversation.id else { return }
            Task { await loadMessages() }
        }
        .alert("Message Error", isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button("OK", role: .cancel) { sendError = nil }
        } message: {
            Text(sendError ?? "Unknown error")
        }
    }

    private var messageHistory: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if nextBefore != nil {
                        Button("Load older messages") { Task { await loadOlder() } }
                            .font(.caption)
                    }
                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]
                        if shouldShowTimestamp(at: index) {
                            Text(message.record.date, style: .time)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        NativeMessageBubble(message: message, api: store.api).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("native-message-bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            // Keep the first layout hidden until it has been positioned at the
            // bottom. This prevents the thread from briefly painting at the
            // top and visibly jumping when a conversation is opened.
            .opacity(messages.isEmpty || hasScrolledToLatest ? 1 : 0)
            .background(Color(.systemGroupedBackground))
            .onAppear { scrollToLatest(using: proxy) }
            .onChange(of: messages.last?.id) { _ in scrollToLatest(using: proxy) }
            .onDisappear { pendingScrollTask?.cancel() }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !mentionCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentionCandidates) { member in
                            Button {
                                chooseMention(member)
                            } label: {
                                HStack(spacing: 6) {
                                    NativeAvatar(url: store.api.absoluteURL(member.avatarUrl), label: member.label, size: 26)
                                    Text(member.label)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                Divider()
            }
            if quickEmojisVisible {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["😀", "😂", "🥰", "👍", "👏", "❤️", "🎉"], id: \.self) { emoji in
                            Button {
                                draft += emoji
                                composerFocused = true
                            } label: {
                                Text(emoji)
                                    .font(.title2)
                                    .frame(width: 38, height: 38)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Insert \(emoji)")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .background(Color(.secondarySystemBackground))
            }
            HStack(alignment: .bottom, spacing: 7) {
                TextField("Write a message", text: $draft)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit { sendText() }
                    .textFieldStyle(.roundedBorder)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        quickEmojisVisible.toggle()
                    }
                    composerFocused = true
                } label: {
                    Image(systemName: quickEmojisVisible ? "face.smiling.fill" : "face.smiling")
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(quickEmojisVisible ? "Hide emojis" : "Show emojis")
                if conversation.kind == "family" {
                    Button {
                        if !draft.hasSuffix(" ") && !draft.isEmpty { draft += " " }
                        draft += "@"
                        composerFocused = true
                    } label: {
                        Image(systemName: "at")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Mention a family member")
                }
                NativeVoiceRecordButton(recorder: recorder) { capture in
                    sendVoice(capture)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Color(.secondarySystemBackground))
        }
    }

    private var mentionCandidates: [NativeMessageMember] {
        guard conversation.kind == "family", let marker = draft.lastIndex(of: "@") else { return [] }
        let suffix = String(draft[draft.index(after: marker)...])
        if suffix.contains(where: { $0.isWhitespace }) { return [] }
        let query = suffix.lowercased()
        return (conversation.members ?? []).filter { query.isEmpty || $0.label.lowercased().contains(query) }
    }

    private func chooseMention(_ member: NativeMessageMember) {
        guard let marker = draft.lastIndex(of: "@") else { return }
        draft.replaceSubrange(marker..., with: "@\(member.label) ")
        if !selectedMentions.contains(member.actor) { selectedMentions.append(member.actor) }
        composerFocused = true
    }

    private func shouldShowTimestamp(at index: Int) -> Bool {
        guard messages.indices.contains(index) else { return false }
        guard index > 0 else { return true }
        return messages[index].record.date.timeIntervalSince(messages[index - 1].record.date) >= 5 * 60
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard !messages.isEmpty else { return }
        pendingScrollTask?.cancel()
        let animated = hasScrolledToLatest
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("native-message-bottom", anchor: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("native-message-bottom", anchor: .bottom)
                }
                // SwiftUI can need one more layout pass after an async message
                // load before the final content height is known.
                await Task.yield()
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard !Task.isCancelled else { return }
                withTransaction(transaction) {
                    proxy.scrollTo("native-message-bottom", anchor: .bottom)
                    hasScrolledToLatest = true
                }
            }
        }
    }

    private func loadMessages() async {
        loading = true
        defer { loading = false }
        do {
            let page = try await store.api.listMessages(conversationId: conversation.id)
            let pending = messages.filter { $0.delivery != .sent }
            let serverMessages = page.messages.map { NativeDisplayMessage(id: $0.id, record: $0, delivery: .sent) }
            messages = serverMessages + pending.filter { pendingMessage in
                !serverMessages.contains(where: { $0.id == pendingMessage.id })
            }
            nextBefore = page.nextBefore
            try await store.api.markSeen(conversationId: conversation.id, messageId: page.messages.last?.id)
            store.clearUnread(conversationId: conversation.id)
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func loadOlder() async {
        guard let cursor = nextBefore, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await store.api.listMessages(conversationId: conversation.id, before: cursor)
            messages = page.messages.map { NativeDisplayMessage(id: $0.id, record: $0, delivery: .sent) } + messages
            nextBefore = page.nextBefore
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func sendText() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_000 else { return }
        let clientId = "local-\(UUID().uuidString)"
        let optimistic = NativeMessageRecord(
            id: clientId,
            conversationId: conversation.id,
            actor: NativeMessageActor(kind: "parent", deviceId: nil),
            senderLabel: "Parent",
            senderAvatarUrl: nil,
            text: text,
            mentions: selectedMentions.isEmpty ? nil : selectedMentions,
            readReceipts: nil,
            voice: nil,
            createdAt: Date().timeIntervalSince1970 * 1_000
        )
        messages.append(NativeDisplayMessage(id: clientId, record: optimistic, delivery: .sending))
        let mentions = selectedMentions.filter { actor in
            guard let member = conversation.members?.first(where: { $0.actor == actor }) else { return false }
            return text.contains("@\(member.label)")
        }
        draft = ""
        selectedMentions = []
        DispatchQueue.main.async { composerFocused = true }

        Task {
            do {
                let sent = try await store.api.sendMessage(conversationId: conversation.id, text: text, mentions: mentions)
                if let index = messages.firstIndex(where: { $0.id == clientId }) {
                    messages[index].record = sent
                    messages[index].delivery = .sent
                } else if !messages.contains(where: { $0.id == sent.id }) {
                    messages.append(NativeDisplayMessage(id: sent.id, record: sent, delivery: .sent))
                }
                await store.refresh()
            } catch {
                if let index = messages.firstIndex(where: { $0.id == clientId }) {
                    messages[index].delivery = .failed
                }
                sendError = error.localizedDescription
            }
        }
    }

    private func sendVoice(_ capture: NativeVoiceCapture) {
        Task {
            do {
                let sent = try await store.api.sendVoiceMessage(
                    conversationId: conversation.id,
                    data: capture.data,
                    durationMs: capture.durationMs
                )
                if !messages.contains(where: { $0.id == sent.id }) {
                    messages.append(NativeDisplayMessage(id: sent.id, record: sent, delivery: .sent))
                }
                await store.refresh()
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

private struct NativeMessageBubble: View {
    let message: NativeDisplayMessage
    let api: NativeMessageAPI

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.record.isOwn { Spacer(minLength: 48) }
            if !message.record.isOwn {
                NativeAvatar(url: api.absoluteURL(message.record.senderAvatarUrl), label: message.record.senderLabel, size: 34)
            }
            VStack(alignment: message.record.isOwn ? .trailing : .leading, spacing: 4) {
                if let voice = message.record.voice {
                    NativeVoicePlaybackButton(message: message.record, voice: voice, api: api)
                } else {
                    Text(message.record.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(message.record.isOwn ? Color.accentColor.opacity(0.18) : Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                if message.record.isOwn {
                    Text(deliveryLabel)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if message.record.isOwn {
                NativeAvatar(url: api.absoluteURL(message.record.senderAvatarUrl), label: message.record.senderLabel, size: 34)
            } else {
                Spacer(minLength: 48)
            }
        }
    }

    private var deliveryLabel: String {
        switch message.delivery {
        case .sending: return "Sending..."
        case .failed: return "Failed"
        case .sent:
            guard let receipts = message.record.readReceipts, !receipts.isEmpty else { return "Sent" }
            let read = receipts.filter(\.read)
            if receipts.count == 1 { return read.isEmpty ? "Unread" : "Read" }
            if read.count == receipts.count { return "Read by \(read.map(\.label).joined(separator: ", "))" }
            if read.isEmpty { return "Unread" }
            return "\(read.count)/\(receipts.count) read"
        }
    }
}

struct NativeAvatar: View {
    let url: URL?
    let label: String
    let size: CGFloat
    @StateObject private var loader = NativeAvatarLoader()

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            Text(String(label.prefix(1)).uppercased()).font(.caption.weight(.medium))
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear { loader.load(url) }
        .onChange(of: url) { loader.load($0) }
    }
}

private struct NativeVoicePlaybackButton: View {
    let message: NativeMessageRecord
    let voice: NativeMessageVoice
    let api: NativeMessageAPI
    @StateObject private var player = NativeVoicePlayer()

    var body: some View {
        Button {
            Task { await player.toggle(message: message, api: api) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: player.isPlaying ? "pause.fill" : "waveform")
                Text("\(max(1, Int(round(Double(voice.durationMs) / 1_000))))s")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(message.isOwn ? Color.accentColor.opacity(0.18) : Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class NativeVoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(message: NativeMessageRecord, api: NativeMessageAPI) async {
        if let player, player.isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        do {
            let data = try await api.voiceData(conversationId: message.conversationId, messageId: message.id)
            let audio = try AVAudioPlayer(data: data)
            audio.delegate = self
            audio.prepareToPlay()
            audio.play()
            player = audio
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}

struct NativeVoiceCapture {
    let data: Data
    let durationMs: Int
}

@MainActor
final class NativeVoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var starting = false

    func start() async {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        guard await recordPermission() else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.prepareToRecord()
            recorder.record(forDuration: 60)
            self.recorder = recorder
            isRecording = true
        } catch {
            recorder = nil
            isRecording = false
        }
    }

    func stop() -> NativeVoiceCapture? {
        guard let recorder, isRecording else { return nil }
        let durationMs = max(1, Int(recorder.currentTime * 1_000))
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        isRecording = false
        guard durationMs >= 250, let data = try? Data(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.removeItem(at: url)
        return NativeVoiceCapture(data: data, durationMs: durationMs)
    }

    func cancel() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        isRecording = false
        try? FileManager.default.removeItem(at: url)
    }

    private func recordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private struct NativeVoiceRecordButton: View {
    @ObservedObject var recorder: NativeVoiceRecorder
    let onFinished: (NativeVoiceCapture) -> Void
    @State private var holding = false

    var body: some View {
        Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
            .font(.system(size: 27))
            .foregroundColor(recorder.isRecording ? .red : .secondary)
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
                        holding = true
                        Task {
                            await recorder.start()
                            if !holding { recorder.cancel() }
                        }
                    }
                    .onEnded { _ in
                        holding = false
                        if let capture = recorder.stop() { onFinished(capture) }
                    }
            )
            .accessibilityLabel("Hold to record a voice message")
    }
}

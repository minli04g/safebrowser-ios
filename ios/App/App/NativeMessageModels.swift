import Foundation

struct NativeMessageActor: Codable, Hashable {
    let kind: String
    let deviceId: String?

    var key: String {
        kind == "parent" ? "parent" : "device:\(deviceId ?? "")"
    }
}

struct NativeMessageMember: Codable, Hashable, Identifiable {
    let actor: NativeMessageActor
    let label: String
    let avatarUrl: String?

    var id: String { actor.key }
}

struct NativeMessageReadReceipt: Codable, Hashable {
    let actor: NativeMessageActor
    let label: String
    let avatarUrl: String?
    let read: Bool
}

struct NativeMessageVoice: Codable, Hashable {
    let url: String
    let durationMs: Int
    let mimeType: String
    let sizeBytes: Int
    let transcript: String?
}

struct NativeMessageRecord: Codable, Hashable, Identifiable {
    let id: String
    let conversationId: String
    let actor: NativeMessageActor
    let senderLabel: String
    let senderAvatarUrl: String?
    let text: String
    let mentions: [NativeMessageActor]?
    let readReceipts: [NativeMessageReadReceipt]?
    let voice: NativeMessageVoice?
    let createdAt: Double

    var date: Date { Date(timeIntervalSince1970: createdAt / 1_000) }
    var isOwn: Bool { actor.kind == "parent" }
}

struct NativeMessagePresence: Codable, Hashable {
    let onlineCount: Int
    let totalCount: Int
}

struct NativeMessageConversation: Codable, Hashable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let avatarUrl: String?
    let canSend: Bool
    let latest: NativeMessageRecord?
    let unreadCount: Int
    let presence: NativeMessagePresence
    let members: [NativeMessageMember]?

    var displayLabel: String { id == "family" ? "Family" : label }
}

struct NativeConversationsResponse: Codable {
    let conversations: [NativeMessageConversation]
}

struct NativeMessagesResponse: Codable {
    let messages: [NativeMessageRecord]
    let nextBefore: String?
}

struct NativeSendMessageResponse: Codable {
    let message: NativeMessageRecord
}

typealias NativeSendVoiceMessageResponse = NativeSendMessageResponse

struct NativeSeenMessageResponse: Codable {
    let seenThrough: String?
}

struct NativeParentSocketEvent: Codable {
    let type: String
    let conversationId: String?
}

struct NativeSendMessageBody: Codable {
    let text: String
    let mentions: [NativeMessageActor]?
}

struct NativeSeenMessageBody: Codable {
    let messageId: String?
}

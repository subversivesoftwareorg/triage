import Foundation

struct AccountSnapshot: Identifiable, Sendable {
    let id: String
    let name: String
    let email: String
    let unreadCount: Int
    let totalInboxCount: Int
    let sentCount: Int
    let trashCount: Int
    let timestamp: Date

    init(
        name: String,
        email: String,
        unreadCount: Int,
        totalInboxCount: Int,
        sentCount: Int = 0,
        trashCount: Int = 0,
        timestamp: Date = .now
    ) {
        self.id = name
        self.name = name
        self.email = email
        self.unreadCount = unreadCount
        self.totalInboxCount = totalInboxCount
        self.sentCount = sentCount
        self.trashCount = trashCount
        self.timestamp = timestamp
    }

    var hasNewMail: Bool { unreadCount > 0 }
}

import Foundation

enum Constants {
    static let bundleIdentifier = "com.subversivesoftware.triage"
    // Team-ID prefixed: macOS 27 denies Developer ID apps access to "group."-prefixed containers.
    static let appGroupIdentifier = "84CC987JU3.com.subversivesoftware.triage"
    // Pre-1.2.0 app group. Only read to migrate the old store on macOS 26 and earlier.
    static let legacyAppGroupIdentifier = "group.com.subversivesoftware.triage"
    static let snoozeMailboxName = "Triage Snoozed"
    static let defaultPollInterval: TimeInterval = 60
    // Dashboard shows at most 30 days; one extra day keeps that window full.
    static let historyRetentionDays = 31
    static let keyboardShortcutsEnabled = "keyboardShortcutsEnabled"
    static let mailBundleID = "com.apple.mail"
}

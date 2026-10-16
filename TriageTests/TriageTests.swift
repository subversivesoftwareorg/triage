import Foundation
import SwiftData
import Testing
@testable import Triage

@Suite("Snooze Duration")
struct SnoozeDurationTests {

    @Test func oneDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let wake = SnoozeDuration.oneDay.wakeDate(from: now)
        #expect(wake.timeIntervalSince(now) == 86400)
    }

    @Test func threeDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let wake = SnoozeDuration.threeDays.wakeDate(from: now)
        #expect(wake.timeIntervalSince(now) == 86400 * 3)
    }

    @Test func oneWeek() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let wake = SnoozeDuration.oneWeek.wakeDate(from: now)
        #expect(wake.timeIntervalSince(now) == 86400 * 7)
    }

    @Test func nextMondayFromWednesday() {
        // 2026-01-07 is a Wednesday
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let wed = cal.date(from: DateComponents(year: 2026, month: 1, day: 7, hour: 14))!
        let wake = SnoozeDuration.nextMonday.wakeDate(from: wed)
        let weekday = cal.component(.weekday, from: wake)
        #expect(weekday == 2) // Monday
        #expect(cal.component(.hour, from: wake) == 9)
        #expect(wake > wed)
    }
}

@Suite("Account Output Parsing")
struct AccountParsingTests {

    @Test func parsesMultipleAccounts() {
        let output = "iCloud\tuser@icloud.com\t3\t10\t5\t2\nGMail\tuser@gmail.com\t0\t50\t20\t8"
        let accounts = MailQueryService.parseAccountOutput(output)
        #expect(accounts.count == 2)
        #expect(accounts[0].name == "iCloud")
        #expect(accounts[0].email == "user@icloud.com")
        #expect(accounts[0].unreadCount == 3)
        #expect(accounts[0].totalInboxCount == 10)
        #expect(accounts[0].sentCount == 5)
        #expect(accounts[0].trashCount == 2)
        #expect(accounts[1].name == "GMail")
        #expect(accounts[1].unreadCount == 0)
        #expect(accounts[1].sentCount == 20)
        #expect(accounts[1].trashCount == 8)
    }

    @Test func defaultsSentAndTrashWhenMissing() {
        let accounts = MailQueryService.parseAccountOutput("iCloud\tuser@icloud.com\t3\t10")
        #expect(accounts.count == 1)
        #expect(accounts[0].sentCount == 0)
        #expect(accounts[0].trashCount == 0)
    }

    @Test func handlesEmptyOutput() {
        let accounts = MailQueryService.parseAccountOutput("")
        #expect(accounts.isEmpty)
    }

    @Test func skipsMalformedLines() {
        let output = "iCloud\tuser@icloud.com\t3\t10\t5\t2\nbadline\nGMail\tuser@gmail.com\t0\t50\t20\t8"
        let accounts = MailQueryService.parseAccountOutput(output)
        #expect(accounts.count == 2)
    }
}

@Suite("Keyboard Shortcut Key Mapping")
struct KeyMappingTests {

    @Test func allShortcutKeysAreMapped() {
        // a=0, d=2, f=3, h=4, r=15, t=17, j=38, k=40, /=44
        #expect(KeyboardShortcutService.keyActions[0] == .archive)
        #expect(KeyboardShortcutService.keyActions[2] == .delete)
        #expect(KeyboardShortcutService.keyActions[3] == .forward)
        #expect(KeyboardShortcutService.keyActions[4] == .remindTonight)
        #expect(KeyboardShortcutService.keyActions[15] == .reply)
        #expect(KeyboardShortcutService.keyActions[17] == .createTask)
        #expect(KeyboardShortcutService.keyActions[38] == .remindTomorrow)
        #expect(KeyboardShortcutService.keyActions[40] == .remindLater)
        #expect(KeyboardShortcutService.keyActions[44] == .search)
    }

    @Test func unmappedKeysReturnNil() {
        #expect(KeyboardShortcutService.keyActions[1] == nil) // s
        #expect(KeyboardShortcutService.keyActions[5] == nil) // g
        #expect(KeyboardShortcutService.keyActions[99] == nil)
    }

    @Test func exactlyNineShortcuts() {
        #expect(KeyboardShortcutService.keyActions.count == 9)
    }

    @Test func cmdSKeyCodeIsNotInSingleKeyMap() {
        // keyCode 1 = S. Must NOT be in the single-key map (it's a Cmd+S remap, not a bare key)
        #expect(KeyboardShortcutService.keyActions[1] == nil)
    }
}

@Suite("Email Extraction")
struct EmailExtractionTests {

    @Test func extractsEmailFromNameAngleBrackets() {
        let email = MailQueryService.extractEmail(from: "John Doe <john@example.com>")
        #expect(email == "john@example.com")
    }

    @Test func extractsBareEmail() {
        let email = MailQueryService.extractEmail(from: "john@example.com")
        #expect(email == "john@example.com")
    }

    @Test func extractsEmailWithDisplayNameQuotes() {
        let email = MailQueryService.extractEmail(from: "\"Doe, John\" <john@example.com>")
        #expect(email == "john@example.com")
    }

    @Test func extractsDomainFromEmail() {
        let domain = MailQueryService.extractDomain(from: "john@example.com")
        #expect(domain == "@example.com")
    }

    @Test func extractsDomainFromSubdomain() {
        let domain = MailQueryService.extractDomain(from: "alerts@mail.example.com")
        #expect(domain == "@mail.example.com")
    }

    @Test func returnsNilDomainForBareString() {
        let domain = MailQueryService.extractDomain(from: "no-at-sign")
        #expect(domain == nil)
    }
}

@Suite("Mail URL Construction")
struct MailURLTests {

    @Test func constructsFromAngleBrackets() {
        let url = KeyboardShortcutService.mailURL(from: "<ABC123@mail.gmail.com>")
        #expect(url == "message://%3CABC123@mail.gmail.com%3E")
    }

    @Test func constructsFromBareID() {
        let url = KeyboardShortcutService.mailURL(from: "ABC123@mail.gmail.com")
        #expect(url == "message://%3CABC123@mail.gmail.com%3E")
    }

    @Test func handlesWhitespace() {
        let url = KeyboardShortcutService.mailURL(from: "  <ABC@test.com>  \n")
        #expect(url == "message://%3CABC@test.com%3E")
    }
}

@Suite("AccountSnapshot")
struct AccountSnapshotTests {

    @Test func hasNewMailWhenUnread() {
        let account = AccountSnapshot(name: "Test", email: "test@test.com", unreadCount: 5, totalInboxCount: 10)
        #expect(account.hasNewMail == true)
    }

    @Test func noNewMailWhenZero() {
        let account = AccountSnapshot(name: "Test", email: "test@test.com", unreadCount: 0, totalInboxCount: 10)
        #expect(account.hasNewMail == false)
    }

    @Test func idMatchesName() {
        let account = AccountSnapshot(name: "GMail", email: "", unreadCount: 0, totalInboxCount: 0)
        #expect(account.id == "GMail")
    }
}

@Suite("Legacy Store Migration")
struct LegacyStoreMigrationTests {

    private let journalSuffixes = ["", "-wal", "-shm"]

    private func makeStoreURLs() throws -> (root: URL, source: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = root.appending(path: "old/Triage.store")
        let destination = root.appending(path: "new/Triage.store")
        for url in [source, destination] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return (root, source, destination)
    }

    @Test func copiesStoreAndJournalFiles() throws {
        let (root, source, destination) = try makeStoreURLs()
        defer { try? FileManager.default.removeItem(at: root) }
        for suffix in journalSuffixes {
            try Data("old\(suffix)".utf8).write(to: URL(fileURLWithPath: source.path + suffix))
        }

        #expect(TriageStore.migrateLegacyStore(from: source, to: destination))
        for suffix in journalSuffixes {
            #expect(try String(contentsOfFile: destination.path + suffix, encoding: .utf8) == "old\(suffix)")
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func leavesExistingStoreAlone() throws {
        let (root, source, destination) = try makeStoreURLs()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: source)
        try Data("new".utf8).write(to: destination)

        #expect(!TriageStore.migrateLegacyStore(from: source, to: destination))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
    }

    @Test func skipsWhenNoLegacyStore() throws {
        let (root, source, destination) = try makeStoreURLs()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!TriageStore.migrateLegacyStore(from: source, to: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Suite("History Pruning")
struct HistoryPruningTests {

    @MainActor @Test func deletesOnlyRecordsBeforeCutoff() throws {
        // On-disk store: SwiftData's batch delete behaves differently in memory.
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let config = ModelConfiguration(schema: TriageStore.schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: TriageStore.schema, configurations: [config])
        let context = ModelContext(container)
        let now = Date.now
        context.insert(ActivityRecord(accountName: "old", timestamp: now.addingTimeInterval(-40 * 86_400)))
        context.insert(ActivityRecord(accountName: "recent", timestamp: now.addingTimeInterval(-86_400)))
        try context.save()

        StatsStore.pruneHistory(in: ModelContext(container), before: now.addingTimeInterval(-31 * 86_400))

        let remaining = try ModelContext(container).fetch(FetchDescriptor<ActivityRecord>())
        #expect(remaining.map(\.accountName) == ["recent"])
    }
}

@Suite("AppleScript Runner")
struct AppleScriptRunnerTests {

    @Test func returnsOutputLargerThanPipeBuffer() async throws {
        // 10 * 2^14 = 163,840 characters, well past the 64 KB pipe buffer.
        let script = """
        set s to "0123456789"
        repeat 14 times
            set s to s & s
        end repeat
        return s
        """
        let output = try await AppleScriptRunner.run(script, timeout: 20)
        #expect(output.count == 163_840)
    }

    @Test func killsScriptAfterTimeout() async {
        let start = Date.now
        let error = await #expect(throws: MailQueryError.self) {
            try await AppleScriptRunner.run("delay 10", timeout: 1)
        }
        if case .timedOut? = error {} else {
            Issue.record("Expected .timedOut, got \(String(describing: error))")
        }
        #expect(Date.now.timeIntervalSince(start) < 5)
    }

    @Test func reportsScriptErrors() async {
        let error = await #expect(throws: MailQueryError.self) {
            try await AppleScriptRunner.run("error \"boom\"")
        }
        guard case .scriptFailed(let message)? = error else {
            Issue.record("Expected .scriptFailed, got \(String(describing: error))")
            return
        }
        #expect(message.contains("boom"))
    }
}

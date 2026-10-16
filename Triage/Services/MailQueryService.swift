import Foundation
import os

final class MailQueryService: Sendable {

    // MARK: - Account Queries

    // Inbox, Sent and Trash are app-level unified mailboxes with one child per account,
    // matched here by account id. Accounts have no `sent mailbox` of their own, and their
    // inbox isn't always named "INBOX" (Exchange uses "Inbox").
    func fetchAccountStats() async throws -> [AccountSnapshot] {
        let script = """
        on countsByAccount(topBox)
            tell application "Mail"
                set ids to {}
                set totals to {}
                set unreads to {}
                try
                    repeat with mb in mailboxes of topBox
                        try
                            set mbID to id of account of mb
                            set mbTotal to count of messages of mb
                            set mbUnread to unread count of mb
                            set end of ids to mbID
                            set end of totals to mbTotal
                            set end of unreads to mbUnread
                        end try
                    end repeat
                end try
                return {ids, totals, unreads}
            end tell
        end countsByAccount

        on countFor(acctID, counts, column)
            set ids to item 1 of counts
            repeat with j from 1 to (count of ids)
                if item j of ids is acctID then return item j of (item column of counts)
            end repeat
            return 0
        end countFor

        tell application "Mail"
            set inboxCounts to my countsByAccount(inbox)
            set sentCounts to my countsByAccount(sent mailbox)
            set trashCounts to my countsByAccount(trash mailbox)
            set output to ""
            repeat with acct in every account
                try
                    set aID to id of acct
                    if (item 1 of inboxCounts) contains aID then
                        set aEmail to email addresses of acct
                        set firstEmail to ""
                        if (count of aEmail) > 0 then
                            set firstEmail to item 1 of aEmail
                        end if
                        set unreadNum to my countFor(aID, inboxCounts, 3)
                        set msgCount to my countFor(aID, inboxCounts, 2)
                        set sentNum to my countFor(aID, sentCounts, 2)
                        set trashNum to my countFor(aID, trashCounts, 2)
                        set output to output & (name of acct) & "\\t" & firstEmail & "\\t" & unreadNum & "\\t" & msgCount & "\\t" & sentNum & "\\t" & trashNum & linefeed
                    end if
                end try
            end repeat
            return output
        end tell
        """
        let output = try await runAppleScript(script)
        return Self.parseAccountOutput(output)
    }

    // MARK: - Selection

    struct SelectedMessage {
        let subject: String
        let accountName: String
        let mailboxName: String
    }

    func fetchSelectedMessage() async throws -> SelectedMessage? {
        let script = """
        tell application "Mail"
            set sel to selection
            if (count of sel) > 0 then
                set msg to item 1 of sel
                set subj to subject of msg
                set mbox to mailbox of msg
                set mboxName to name of mbox
                set acctName to name of account of mbox
                return subj & "\\t" & acctName & "\\t" & mboxName
            else
                return ""
            end if
        end tell
        """
        let output = try await runAppleScript(script)
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return SelectedMessage(subject: parts[0], accountName: parts[1], mailboxName: parts[2])
    }

    func holdSelectedMessage(snoozeMailbox: String) async throws -> SelectedMessage? {
        let script = """
        tell application "Mail"
            set sel to selection
            if (count of sel) = 0 then
                return ""
            end if
            set msg to item 1 of sel
            set subj to subject of msg
            set mbox to mailbox of msg
            set mboxName to name of mbox
            set acct to account of mbox
            set acctName to name of acct
            set boxNames to name of every mailbox of acct
            if boxNames does not contain "\(Self.escaped(snoozeMailbox))" then
                make new mailbox with properties {name:"\(Self.escaped(snoozeMailbox))"} at acct
            end if
            set destBox to mailbox "\(Self.escaped(snoozeMailbox))" of acct
            move msg to destBox
            return subj & "\\t" & acctName & "\\t" & mboxName
        end tell
        """
        let output = try await runAppleScript(script)
        guard !output.isEmpty else { return nil }
        let parts = output.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return SelectedMessage(subject: parts[0], accountName: parts[1], mailboxName: parts[2])
    }

    func forwardSelectedMessage() async throws {
        let script = """
        tell application "Mail"
            set sel to selection
            if (count of sel) > 0 then
                forward (item 1 of sel)
            end if
        end tell
        """
        _ = try await runAppleScript(script)
    }

    // MARK: - Blocking

    private static let blockRuleName = "Triage Blocks"

    func fetchSelectedSender() async throws -> String? {
        let script = """
        tell application "Mail"
            set sel to selection
            if (count of sel) > 0 then
                return sender of (item 1 of sel)
            else
                return ""
            end if
        end tell
        """
        let output = try await runAppleScript(script)
        return output.isEmpty ? nil : output
    }

    func addBlock(expression: String) async throws {
        let expr = Self.escaped(expression)
        let ruleName = Self.escaped(Self.blockRuleName)
        let script = """
        tell application "Mail"
            try
                set blockRule to rule "\(ruleName)"
            on error
                set blockRule to make new rule with properties {name:"\(ruleName)", all conditions must be met:false, delete message:true, stop evaluating rules:true}
                set enabled of blockRule to true
            end try
            make new rule condition at end of rule conditions of blockRule with properties {rule type:from header, qualifier:does contain value, expression:"\(expr)"}
        end tell
        """
        _ = try await runAppleScript(script)
    }

    func listBlocks() async throws -> [String] {
        let ruleName = Self.escaped(Self.blockRuleName)
        let script = """
        tell application "Mail"
            try
                set blockRule to rule "\(ruleName)"
                set conds to every rule condition of blockRule
                set output to ""
                repeat with i from 1 to (count of conds)
                    set c to item i of conds
                    set output to output & expression of c & linefeed
                end repeat
                return output
            on error
                return ""
            end try
        end tell
        """
        let output = try await runAppleScript(script)
        guard !output.isEmpty else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func removeBlock(expression: String) async throws {
        let ruleName = Self.escaped(Self.blockRuleName)
        let existing = try await listBlocks()
        let remaining = existing.filter { $0 != expression }

        let script: String
        if remaining.isEmpty {
            script = """
            tell application "Mail"
                try
                    delete rule "\(ruleName)"
                end try
            end tell
            """
        } else {
            let conditionLines = remaining.map { expr in
                "make new rule condition at end of rule conditions of blockRule with properties {rule type:from header, qualifier:does contain value, expression:\"\(Self.escaped(expr))\"}"
            }.joined(separator: "\n            ")

            script = """
            tell application "Mail"
                try
                    delete rule "\(ruleName)"
                end try
                set blockRule to make new rule with properties {name:"\(ruleName)", all conditions must be met:false, delete message:true, stop evaluating rules:true}
                set enabled of blockRule to true
                \(conditionLines)
            end tell
            """
        }
        _ = try await runAppleScript(script)
    }

    static func extractEmail(from sender: String) -> String {
        if let open = sender.lastIndex(of: "<"),
           let close = sender.lastIndex(of: ">"),
           open < close {
            return String(sender[sender.index(after: open)..<close])
        }
        return sender.trimmingCharacters(in: .whitespaces)
    }

    static func extractDomain(from email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        return String(email[at...])
    }

    // MARK: - Message Operations

    func moveMessageToMailbox(subject: String, fromMailbox: String, toMailbox: String, account: String) async throws {
        let script = """
        tell application "Mail"
            set acct to account "\(Self.escaped(account))"
            set srcBox to mailbox "\(Self.escaped(fromMailbox))" of acct
            set destBox to mailbox "\(Self.escaped(toMailbox))" of acct
            set matchingMessages to (every message of srcBox whose subject is "\(Self.escaped(subject))")
            repeat with msg in matchingMessages
                move msg to destBox
            end repeat
        end tell
        """
        _ = try await runAppleScript(script)
    }

    func ensureSnoozeMailbox(account: String) async throws {
        let script = """
        tell application "Mail"
            set acct to account "\(Self.escaped(account))"
            set boxNames to name of every mailbox of acct
            if boxNames does not contain "\(Constants.snoozeMailboxName)" then
                make new mailbox with properties {name:"\(Constants.snoozeMailboxName)"} at acct
            end if
        end tell
        """
        _ = try await runAppleScript(script)
    }

    // MARK: - Private

    private func runAppleScript(_ source: String) async throws -> String {
        try await AppleScriptRunner.run(source)
    }

    static func parseAccountOutput(_ output: String) -> [AccountSnapshot] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> AccountSnapshot? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 4 else { return nil }
                return AccountSnapshot(
                    name: parts[0],
                    email: parts.count > 1 ? parts[1] : "",
                    unreadCount: Int(parts[2]) ?? 0,
                    totalInboxCount: Int(parts[3]) ?? 0,
                    sentCount: parts.count > 4 ? Int(parts[4]) ?? 0 : 0,
                    trashCount: parts.count > 5 ? Int(parts[5]) ?? 0 : 0
                )
            }
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - AppleScript Runner

enum AppleScriptRunner {
    /// Runs `source` with osascript and returns its trimmed stdout.
    ///
    /// Both pipes are drained while osascript runs: reading only after it exits deadlocks once
    /// the output fills the 64 KB pipe buffer (e.g. a long email body). osascript is killed
    /// after `timeout` so a stalled Mail.app can't hang polling forever.
    static func run(_ source: String, timeout: TimeInterval = 60) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let watchdog = DispatchWorkItem {
                    timedOut.withLock { $0 = true }
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                var errData = Data()
                let errRead = DispatchGroup()
                errRead.enter()
                DispatchQueue.global().async {
                    errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    errRead.leave()
                }
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                errRead.wait()
                process.waitUntilExit()
                watchdog.cancel()

                if timedOut.withLock({ $0 }) {
                    continuation.resume(throwing: MailQueryError.timedOut)
                } else if process.terminationStatus == 0 {
                    let output = String(decoding: outData, as: UTF8.self)
                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let errMsg = String(decoding: errData, as: UTF8.self)
                    continuation.resume(throwing: MailQueryError.scriptFailed(errMsg.isEmpty ? "osascript failed" : errMsg))
                }
            }
        }
    }
}

// MARK: - Errors

enum MailQueryError: Error, LocalizedError {
    case scriptFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): "Triage query failed: \(msg)"
        case .timedOut: "Triage query failed: Mail.app didn't respond in time"
        }
    }
}

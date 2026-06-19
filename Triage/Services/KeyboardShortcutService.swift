import AppKit
import ApplicationServices
import UserNotifications

@Observable
@MainActor
final class KeyboardShortcutService {

    var isEnabled = UserDefaults.standard.bool(forKey: Constants.keyboardShortcutsEnabled) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Constants.keyboardShortcutsEnabled)
            if isEnabled { startMonitoring() } else { stopMonitoring() }
        }
    }

    private(set) var isAccessibilityGranted = false
    private(set) var isMonitoring = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollTask: Task<Void, Never>?
    private let queryService = MailQueryService()

    // CGKeyCode values: a=0  d=2  f=3  h=4  j=38  k=40  r=15  t=17  /=44
    nonisolated(unsafe) static let keyActions: [UInt16: Action] = [
        0: .archive, 2: .delete, 3: .forward, 4: .remindTonight,
        15: .reply, 17: .createTask, 38: .remindTomorrow, 40: .remindLater,
        44: .search,
    ]

    enum Action {
        case delete, archive, reply, forward, createTask, search
        case remindTonight, remindTomorrow, remindLater
    }

    init() {
        if UserDefaults.standard.bool(forKey: Constants.keyboardShortcutsEnabled) {
            DispatchQueue.main.async { [weak self] in
                self?.startMonitoring()
            }
        }
    }

    // MARK: - Accessibility

    @discardableResult
    func checkAccessibility(prompt: Bool = true) -> Bool {
        let opts: NSDictionary = prompt
            ? [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
            : [:]
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(opts)
        return isAccessibilityGranted
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil

        if checkAccessibility() {
            installEventTap()
            return
        }

        accessibilityPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isEnabled else { return }
                if self.checkAccessibility(prompt: false) {
                    self.installEventTap()
                    return
                }
            }
        }
    }

    private func installEventTap() {
        removeEventTap()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            isMonitoring = false
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isMonitoring = true
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isMonitoring = false
    }

    private func stopMonitoring() {
        accessibilityPollTask?.cancel()
        accessibilityPollTask = nil
        removeEventTap()
    }

    // MARK: - Event tap callback

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passRetained(event) }
        let service = Unmanaged<KeyboardShortcutService>.fromOpaque(userInfo).takeUnretainedValue()

        // Re-enable tap if macOS disabled it (happens if callback takes too long)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = service.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // Only intercept when Mail.app is frontmost
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Constants.mailBundleID else {
            return Unmanaged.passRetained(event)
        }

        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Cmd+Shift+S → Send + Follow Up (must check before Cmd+S)
        if keyCode == 1
            && flags.contains(.maskCommand)
            && flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) {
            Task { @MainActor in
                await service.sendAndFollowUp()
            }
            return nil
        }

        // Cmd+S → Send (remap to Cmd+Shift+D)
        if keyCode == 1
            && flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) {
            postKeystrokeStatic(keyCode: 2, flags: [.maskCommand, .maskShift])
            return nil
        }

        // b/B → Block sender (b) or domain (Shift+B)
        if keyCode == 11
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate) {
            if !isTextInputFocusedStatic() {
                let blockDomain = flags.contains(.maskShift)
                Task { @MainActor in
                    await service.blockSender(domain: blockDomain)
                }
                return nil
            }
        }

        // Pass through if modifier keys are held (real shortcuts like Cmd+R)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return Unmanaged.passRetained(event)
        }

        // Check if this is one of our shortcut keys
        guard let action = keyActions[keyCode] else {
            return Unmanaged.passRetained(event)
        }

        // Don't intercept if a text field is focused
        if isTextInputFocusedStatic() {
            return Unmanaged.passRetained(event)
        }

        // Suppress the original keystroke and fire our action
        switch action {
        case .delete:
            postKeystrokeStatic(keyCode: 51, flags: .maskCommand)
        case .archive:
            postKeystrokeStatic(keyCode: 0, flags: [.maskControl, .maskCommand])
        case .reply:
            postKeystrokeStatic(keyCode: 15, flags: .maskCommand)
        case .forward:
            Task { @MainActor in
                try? await service.queryService.forwardSelectedMessage()
            }
        case .remindTonight:
            clickRemindMenuItem("Remind Me Tonight")
        case .remindTomorrow:
            clickRemindMenuItem("Remind Me Tomorrow")
        case .remindLater:
            clickRemindMenuItem("Remind Me Later\u{2026}")
        case .createTask:
            Task { @MainActor in
                await service.createTaskFromEmail()
            }
        case .search:
            postKeystrokeStatic(keyCode: 3, flags: [.maskCommand, .maskAlternate])
        }
        return nil
    }

    // MARK: - Text input detection (called from C callback, must be static)

    private static func isTextInputFocusedStatic() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return true }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else {
            return true
        }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""

        if roleStr == kAXTextFieldRole as String
            || roleStr == kAXTextAreaRole as String
            || roleStr == "AXComboBox" {
            return true
        }

        if roleStr == "AXWebArea" {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element as! AXUIElement, kAXValueAttribute as CFString, &settable) == .success {
                return settable.boolValue
            }
            return true
        }

        return false
    }

    // MARK: - Actions

    private static func clickRemindMenuItem(_ itemName: String) {
        Task { @MainActor in
            let script = """
            tell application "System Events"
                tell process "Mail"
                    click menu item "\(itemName)" of menu 1 of menu item "Remind Me" of menu 1 of menu bar item "Message" of menu bar 1
                end tell
            end tell
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }

    func sendAndFollowUp() async {
        let script = """
        tell application "Mail"
            set outMsg to outgoing message of front window
            set subj to subject of outMsg
            set recipAddrs to {}
            repeat with r in (every to recipient of outMsg)
                set end of recipAddrs to address of r
            end repeat
            set AppleScript's text item delimiters to ", "
            set recipStr to recipAddrs as string
            return subj & "\\t" & recipStr
        end tell
        """
        guard let output = try? await runScript(script), !output.isEmpty else {
            Self.postKeystrokeStatic(keyCode: 2, flags: [.maskCommand, .maskShift])
            return
        }
        let parts = output.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let subject = parts[0]
        let recipients = parts.count > 1 ? parts[1] : ""

        Self.postKeystrokeStatic(keyCode: 2, flags: [.maskCommand, .maskShift])

        let createScript = """
        tell application "Reminders"
            set taskList to default list
            set dueDate to (current date) + 7 * days
            set hours of dueDate to 9
            set minutes of dueDate to 0
            set seconds of dueDate to 0
            make new reminder in taskList with properties {name:"Follow up: \(Self.escaped(subject))", body:"Sent to: \(Self.escaped(recipients))", due date:dueDate}
        end tell
        """
        if (try? await runScript(createScript)) != nil {
            let content = UNMutableNotificationContent()
            content.title = "Follow-up Set — 1 Week"
            content.body = subject
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: "followup-\(Date.now.timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func createTaskFromEmail() async {
        let script = """
        tell application "Mail"
            set sel to selection
            if (count of sel) = 0 then
                return ""
            end if
            set msg to item 1 of sel
            set subj to subject of msg
            set sndr to sender of msg
            return subj & "\\t" & sndr
        end tell
        """
        guard let output = try? await runScript(script), !output.isEmpty else {
            NSSound.beep()
            return
        }
        let parts = output.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { NSSound.beep(); return }
        let subject = parts[0]
        let sender = parts[1]

        let createScript = """
        tell application "Reminders"
            set taskList to default list
            set dueDate to (current date) + 1 * days
            set hours of dueDate to 9
            set minutes of dueDate to 0
            set seconds of dueDate to 0
            make new reminder in taskList with properties {name:"Follow up: \(Self.escaped(subject))", body:"From: \(Self.escaped(sender))", due date:dueDate}
        end tell
        """
        if (try? await runScript(createScript)) != nil {
            let content = UNMutableNotificationContent()
            content.title = "Task Created"
            content.body = subject
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: "task-\(Date.now.timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        } else {
            NSSound.beep()
        }
    }

    private func runScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { proc in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0, let out = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "osascript failed"
                    continuation.resume(throwing: MailQueryError.scriptFailed(errMsg))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func blockSender(domain: Bool) async {
        guard let sender = try? await queryService.fetchSelectedSender() else {
            NSSound.beep()
            return
        }
        let email = MailQueryService.extractEmail(from: sender)
        let expression: String
        if domain, let domainPart = MailQueryService.extractDomain(from: email) {
            expression = domainPart
        } else {
            expression = email
        }

        do {
            try await queryService.addBlock(expression: expression)
            Self.postKeystrokeStatic(keyCode: 51, flags: .maskCommand)
            let content = UNMutableNotificationContent()
            content.title = domain ? "Domain Blocked" : "Sender Blocked"
            content.body = expression
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: "block-\(Date.now.timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        } catch {
            NSSound.beep()
        }
    }

    static func postKeystrokeStatic(keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

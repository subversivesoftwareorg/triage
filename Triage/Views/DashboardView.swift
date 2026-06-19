import SwiftUI
import SwiftData
import Sparkle

struct DashboardView: View {
    @Environment(StatsStore.self) private var store
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var selection: String = "overview"
    @State private var historyDays = 7
    let updater: SPUUpdater

    private static let overviewTag = "overview"
    private static let shortcutsTag = "shortcuts"
    private static let blocksTag = "blocks"

    var body: some View {
        Group {
            if !hasSeenIntro {
                IntroView { hasSeenIntro = true }
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detailView
                }
                .navigationTitle("Triage")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        CheckForUpdatesView(updater: updater)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isLoading)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "square.grid.2x2")
                .tag(Self.overviewTag)
            Label("Blocks", systemImage: "hand.raised")
                .tag(Self.blocksTag)
            Label("Shortcuts", systemImage: "keyboard")
                .tag(Self.shortcutsTag)

            Section("Accounts") {
                ForEach(store.accounts) { account in
                    AccountRow(account: account)
                        .tag(account.name)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if selection == Self.shortcutsTag {
            shortcutsView
        } else if selection == Self.blocksTag {
            BlocksView()
        } else if selection != Self.overviewTag,
                  let account = store.accounts.first(where: { $0.name == selection }) {
            AccountDetailView(account: account, store: store, historyDays: $historyDays)
        } else {
            summaryView
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(store.totalUnread)")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("unread across \(store.accounts.count) accounts")
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastRefresh = store.lastRefresh {
                    Text("Updated \(lastRefresh, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .padding(.horizontal)
            }

            if let summary = store.todaySummary() {
                daySummaryCards(summary)
            }

            Divider()

            Table(store.accounts) {
                TableColumn("Account") { account in
                    HStack(spacing: 8) {
                        Image(systemName: account.hasNewMail ? "envelope.badge.fill" : "envelope")
                            .foregroundStyle(account.hasNewMail ? .blue : .secondary)
                        VStack(alignment: .leading) {
                            Text(account.name)
                                .fontWeight(account.hasNewMail ? .semibold : .regular)
                            if !account.email.isEmpty {
                                Text(account.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .width(min: 160, ideal: 240)

                TableColumn("Unread") { account in
                    if account.unreadCount > 0 {
                        Text("\(account.unreadCount)")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                    } else {
                        Text("0")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .width(60)

                TableColumn("Inbox") { account in
                    Text("\(account.totalInboxCount)")
                        .monospacedDigit()
                }
                .width(60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func daySummaryCards(_ summary: StatsStore.DaySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today")
                .font(.headline)
            HStack(spacing: 16) {
                DeltaCard(title: "Unread", delta: summary.unreadChange, icon: "envelope.badge")
                DeltaCard(title: "Inbox", delta: summary.inboxChange, icon: "tray")
                StatCard(title: "Peak Unread", value: "\(summary.peakUnread)", icon: "chart.line.uptrend.xyaxis", color: .purple)
                StatCard(title: "Snapshots", value: "\(summary.snapshotCount)", icon: "clock.arrow.circlepath", color: .gray)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    // MARK: - Shortcuts reference

    private var shortcutsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.title2.bold())
                .padding()

            Text("When Mail.app is focused and no text field is active, these single keys trigger actions on the selected message.")
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 12)

            Divider()

            Table(shortcutRows) {
                TableColumn("Key") { row in
                    Text(row.key)
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .width(60)

                TableColumn("Action") { row in
                    Text(row.action)
                        .fontWeight(.medium)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Description") { row in
                    Text(row.detail)
                        .foregroundStyle(.secondary)
                }
                .width(min: 160, ideal: 300)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Shortcuts are disabled in compose windows, search fields, and text inputs.", systemImage: "shield.checkered")
                Label("Archive requires an IMAP or Gmail account.", systemImage: "info.circle")
                Label("Hold moves the message to a snooze mailbox and resurfaces it after 24 hours.", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var shortcutRows: [ShortcutRow] {
        [
            ShortcutRow(key: "D", action: "Delete", detail: "Move selected message to Trash"),
            ShortcutRow(key: "A", action: "Archive", detail: "Archive selected message"),
            ShortcutRow(key: "R", action: "Reply", detail: "Open reply to selected message"),
            ShortcutRow(key: "F", action: "Forward", detail: "Open forward for selected message"),
            ShortcutRow(key: "T", action: "Create Task", detail: "Add a Reminder from the selected message — due tomorrow 9am"),
            ShortcutRow(key: "B", action: "Block Sender", detail: "Block this email address — future mail auto-deleted"),
            ShortcutRow(key: "⇧B", action: "Block Domain", detail: "Block the entire domain — future mail auto-deleted"),
            ShortcutRow(key: "H", action: "Remind Tonight", detail: "Mail.app Remind Me — tonight"),
            ShortcutRow(key: "J", action: "Remind Tomorrow", detail: "Mail.app Remind Me — tomorrow"),
            ShortcutRow(key: "K", action: "Remind Later", detail: "Mail.app Remind Me — opens date picker"),
            ShortcutRow(key: "/", action: "Search", detail: "Focus the search field to search all mail"),
            ShortcutRow(key: "⌘S", action: "Send", detail: "Send the message being composed"),
            ShortcutRow(key: "⇧⌘S", action: "Send + Follow Up", detail: "Send and create a 1-week follow-up reminder"),
        ]
    }
}

private struct ShortcutRow: Identifiable {
    let id: String
    let key: String
    let action: String
    let detail: String

    init(key: String, action: String, detail: String) {
        self.id = key
        self.key = key
        self.action = action
        self.detail = detail
    }
}

struct DeltaCard: View {
    let title: String
    let delta: Int
    let icon: String

    private var color: Color {
        if delta < 0 { .green } else if delta > 0 { .orange } else { .secondary }
    }

    private var deltaText: String {
        if delta > 0 { "+\(delta)" } else if delta < 0 { "\(delta)" } else { "—" }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(deltaText)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 120, height: 100)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

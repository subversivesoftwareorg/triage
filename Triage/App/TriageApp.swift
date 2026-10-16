import SwiftUI
import SwiftData
import Sparkle

@main
struct TriageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    let modelContainer: ModelContainer
    let statsStore: StatsStore
    let snoozeService: SnoozeService
    let keyboardService: KeyboardShortcutService

    init() {
        let (container, storageError) = TriageStore.makeContainer()

        let snooze = SnoozeService(modelContainer: container)
        let stats = StatsStore(modelContainer: container)
        if let storageError {
            stats.storageWarning = "History isn't being saved: \(storageError.localizedDescription)"
        }

        self.modelContainer = container
        self.statsStore = stats
        self.snoozeService = snooze
        self.keyboardService = KeyboardShortcutService()

        DispatchQueue.main.async {
            stats.startPolling()
            snooze.startChecking()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(updater: updaterController.updater)
                .environment(statsStore)
                .environment(keyboardService)
        } label: {
            HStack(spacing: 4) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                if statsStore.totalUnread > 0 {
                    Text("\(statsStore.totalUnread)")
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Triage Dashboard", id: "dashboard") {
            DashboardView(updater: updaterController.updater)
                .environment(statsStore)
                .environment(snoozeService)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 800, height: 500)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Triage") { appDelegate.showAboutPanel(nil) }
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

// MARK: - Store

/// Builds the SwiftData container at a fixed path in Application Support.
///
/// Before 1.2.0 the store sat in the "group." app group container, picked implicitly by
/// SwiftData's `.automatic` group container default. macOS 27 denies Developer ID apps access
/// to that container, so `ModelContainer` threw and the app crashed at launch.
enum TriageStore {
    static let schema = Schema([ActivityRecord.self, SnoozedMessage.self])

    static var storeURL: URL {
        URL.applicationSupportDirectory
            .appending(path: Constants.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Triage.store")
    }

    static var legacyStoreURL: URL {
        URL.homeDirectory
            .appending(path: "Library/Group Containers/\(Constants.legacyAppGroupIdentifier)")
            .appending(path: "Library/Application Support/Triage.store")
    }

    /// Returns an on-disk container, or an in-memory one plus the error if the store can't be
    /// opened, so unread counts and shortcuts keep working without saved history.
    static func makeContainer() -> (ModelContainer, Error?) {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // macOS 27 blocks the legacy container without prompting, so don't touch it there.
            if #unavailable(macOS 27) {
                migrateLegacyStore(from: legacyStoreURL, to: storeURL)
            }
            let config = ModelConfiguration("Triage", schema: schema, url: storeURL, cloudKitDatabase: .none)
            return (try ModelContainer(for: schema, configurations: [config]), nil)
        } catch {
            let config = ModelConfiguration(
                "Triage", schema: schema, isStoredInMemoryOnly: true,
                groupContainer: .none, cloudKitDatabase: .none
            )
            return (try! ModelContainer(for: schema, configurations: [config]), error)
        }
    }

    /// Copies the store and its -wal/-shm files from `source` when `destination` doesn't exist yet.
    /// Copies rather than moves so an older build still finds its data after a downgrade.
    @discardableResult
    static func migrateLegacyStore(from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: source.path) else {
            return false
        }
        let suffixes = ["", "-wal", "-shm"]
        do {
            for suffix in suffixes where fm.fileExists(atPath: source.path + suffix) {
                try fm.copyItem(atPath: source.path + suffix, toPath: destination.path + suffix)
            }
            return true
        } catch {
            // A store copied without its WAL is missing recent writes; start fresh instead.
            for suffix in suffixes {
                try? fm.removeItem(atPath: destination.path + suffix)
            }
            return false
        }
    }
}

# Triage

A macOS menu bar app that adds power-user keyboard shortcuts and account monitoring to Mail.app.

## Features

### Keyboard Shortcuts

Gmail-style single-key shortcuts when Mail.app is focused. Shortcuts are intercepted before they reach Mail.app (no type-to-select interference).

| Key | Action | Details |
|-----|--------|---------|
| `d` | Delete | Move to Trash |
| `a` | Archive | Archive message (IMAP/Gmail) |
| `r` | Reply | Open reply |
| `f` | Forward | Open forward |
| `t` | Task | Create a Reminder — due tomorrow 9am |
| `b` | Block sender | Add sender to block rule, trash message |
| `⇧B` | Block domain | Block the entire `@domain` |
| `h` | Remind tonight | Mail.app Remind Me — tonight |
| `j` | Remind tomorrow | Mail.app Remind Me — tomorrow |
| `k` | Remind later | Mail.app Remind Me — opens date picker |
| `/` | Search | Focus the search field to search all mail |
| `⌘S` | Send | Remaps to `⌘⇧D` (Mail.app Send) |
| `⇧⌘S` | Send + Follow Up | Send and create a 1-week follow-up reminder |

Single-key shortcuts are automatically disabled in compose windows, search fields, and text inputs.

### Account Dashboard

- **Menu bar** — unread count badge, one-click access
- **Overview** — per-account unread/inbox counts in a table
- **Today summary** — unread change, inbox change, peak unread
- **Activity history** — aggregated hourly (24h) or daily (7d/30d)
- **Per-account detail** — select an account for stats and history

### Blocking

Press `b` to block a sender or `⇧B` to block an entire domain. Blocks are stored as a single Mail.app rule ("Triage Blocks") with `delete message` enabled — no parallel data, works across all accounts. The dashboard Blocks page shows the block list with unblock support.

### Reminders Integration

Press `t` to create a Reminder from the selected message. Sets "Follow up: [subject]" with the sender and a `message://` deep link in the body, due tomorrow at 9am, in the default Reminders list.

### Send + Follow Up

Press `⇧⌘S` in a compose window to send the message and automatically create a follow-up reminder due in one week. Triage captures the subject and recipients before sending, then polls the Sent mailbox to include a `message://` deep link back to the original message.

### Remind Me

Press `h`/`j`/`k` to use Mail.app's native Remind Me feature. Reminders appear in Mail.app's own UI.

## Setup

### Build & Run

```bash
open Triage.xcodeproj    # Xcode development (includes MailKit extension)
swift build               # SPM build (main app only)
swift test                # Run tests
```

Build and run from Xcode (Cmd+R). The app lives in the menu bar.

### Permissions

On first launch, macOS prompts for each permission as needed:

| Permission | Where to grant | Why |
|------------|---------------|-----|
| **Automation (Mail.app)** | System Settings > Privacy > Automation | Read accounts, move messages |
| **Accessibility** | System Settings > Privacy > Accessibility | Keyboard shortcuts (CGEvent tap) |
| **Automation (System Events)** | System Settings > Privacy > Automation | Remind Me, block via menu items |
| **Reminders** | System Settings > Privacy > Reminders | Create tasks from emails |
| **Notifications** | System Settings > Notifications > Triage | Block/task confirmation alerts |

### Enable the Mail Extension

1. Open **Mail.app** > **Settings** > **Extensions**
2. Enable **TriageExtension**

### Enable Keyboard Shortcuts

1. Click the Triage menu bar icon
2. Flip the **Keyboard Shortcuts** toggle
3. Grant Accessibility permission when prompted (green checkmark confirms it's active)

## Distribution

### Build a signed DMG

```bash
./Scripts/create-dmg.sh                   # full build + sign + notarize
./Scripts/create-dmg.sh --skip-notarize   # build + sign only (for testing)
```

The script:
1. Auto-increments the build number in Info.plist
2. Builds a universal binary (arm64 + x86_64) via xcodebuild
3. Signs the MailKit extension, Sparkle framework, and app with Developer ID Application
4. Creates a DMG with drag-to-install layout
5. Notarizes via `xcrun notarytool` and staples the result
6. Creates a Sparkle update archive and appcast
7. Creates a GitHub Release with the DMG and update zip
8. Commits the build number bump and tags the release

Prerequisites: `brew install create-dmg` (optional — falls back to `hdiutil`)

Environment variables (prompted if not set):
- `APPLE_ID` — Apple ID email for notarization
- `APP_PASSWORD` — app-specific password ([appleid.apple.com](https://appleid.apple.com))
- `TEAM_ID` — Developer team ID (default: 84CC987JU3)

## Architecture

- **Menu bar app** — `LSUIElement`, `MenuBarExtra` with `.window` style
- **MailKit extension** — embedded `MEComposeSessionHandler` (extensible)
- **Keyboard shortcuts** — `CGEvent` tap intercepts keys before Mail.app, suppresses originals
- **Mail.app communication** — AppleScript via `osascript` subprocess
- **Data** — SwiftData for activity history; Mail.app rules for block list; Reminders.app for tasks
- **Auto-update** — Sparkle framework with EdDSA-signed appcast

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ (for building)
- Mail.app configured with at least one account

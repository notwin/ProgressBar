<div align="center">

[简体中文](README.md) | English

<h1>
<img src="screenshots/icon.png" width="42" align="center" alt="icon">
Progress
</h1>

**A lightweight, elegant native macOS task management app**

Track project progress with logs · Pure SwiftUI · No Xcode required · One-command build

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-14.0+-black.svg?logo=apple&logoColor=white)](https://github.com/notwin/ProgressBar)
[![Swift](https://img.shields.io/badge/Swift_6-FA7343.svg?logo=swift&logoColor=white)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/notwin/ProgressBar?color=brightgreen)](https://github.com/notwin/ProgressBar/releases/latest)

<br>

<img src="screenshots/main.png" width="680" alt="Main interface">

<br>

<details>
<summary><b>More Screenshots</b></summary>
<br>
<p><b>Obsidian Theme</b></p>
<img src="screenshots/dark-main.png" width="680" alt="Obsidian theme">
<br><br>
<p><b>Neon Theme</b></p>
<img src="screenshots/neon-theme.png" width="680" alt="Neon theme">
</details>

<br>

[**Download**](https://github.com/notwin/ProgressBar/releases/latest) ·
[**Features**](#features) ·
[**Quick Start**](#quick-start) ·
[**Contributing**](CONTRIBUTING.md)

</div>

<br>

## Features

<table>
<tr>
<td width="50%">

**Task Management**
- Multi-section organization by project
- Status flow: Pending → In Progress → Blocked → Done
- Drag-and-drop sorting, overdue deadlines highlighted
- Separate archive with restore capability

</td>
<td width="50%">

**Progress Logs**
- Add log entries to each task
- Shows latest 3 by default, expandable
- Auto-detects "blocked" keywords to update status
- Editable dates, auto-sorted chronologically

</td>
</tr>
<tr>
<td>

**Calendar & Export**
- One-click sync deadlines to system calendar
- Dedicated calendar with auto sync on changes
- Copy as text / Export as desktop & mobile PNG

</td>
<td>

**Experience**
- 7 distinct themes (auto follows system appearance)
- iCloud multi-device sync + local backup
- Full keyboard shortcuts, `⌘1`~`⌘9` section switching
- In-app auto-update with silent launch check
- MCP protocol integration for AI assistants

</td>
</tr>
</table>

### Themes

| Auto | Obsidian | Abyss | Sandstone | Neon | Frost | Paper |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| System | Linear-style | Arc-style | Earthy warm | Cyberpunk | Nord-style | Things 3-style |

### Keyboard Shortcuts

| Action | Shortcut | Action | Shortcut |
|--------|:--------:|--------|:--------:|
| New Task | `⌘N` | Copy to Clipboard | `⇧⌘C` |
| Search | `⌘F` | Export Image | `⌘E` |
| Sync Calendar | `⇧⌘S` | Shortcuts Help | `⌘/` |
| Settings | `⌘,` | Switch Section | `⌘1`~`⌘9` |

<br>

## Quick Start

### Download

Go to [**Releases**](https://github.com/notwin/ProgressBar/releases/latest), download the latest version, unzip and drag the app to your Applications folder.

### Build from Source

```bash
git clone https://github.com/notwin/ProgressBar.git
cd ProgressBar
./build.sh    # Compile → Sign → Deploy → Launch
```

> **Requires** macOS 14.0+, Xcode Command Line Tools (provides Swift 6 compiler)

<br>

## MCP Integration

Progress provides an [MCP Server](mcp-server/) that allows AI assistants to manage tasks via the MCP protocol.

```bash
cd mcp-server && npm install && npx tsc
```

Supported operations: list sections, list tasks, create tasks, update status, add logs, archive, delete, and more.

<br>

## Tech Stack

| | |
|---|---|
| **Language** | Swift 6 |
| **UI Framework** | SwiftUI + AppKit |
| **Calendar** | EventKit |
| **Build** | `swiftc` CLI compilation, no Xcode project needed |
| **Data** | JSON + iCloud Drive sync |
| **i18n** | 13 languages (EN/ZH/JA/KO/FR/DE/IT/ES/PT/HI/ID) |
| **CI/CD** | GitHub Actions auto build & release |
| **Minimum OS** | macOS 14.0 Sonoma |

<br>

## Project Structure

```
ProgressBar/
├── Models.swift              # Data models & state definitions
├── Theme.swift               # Theme color system
├── AppState.swift            # State management · CRUD · Calendar sync
├── PersistenceManager.swift  # Persistence · iCloud sync
├── CalendarManager.swift     # System calendar integration
├── UpdateChecker.swift       # GitHub Releases auto-update
├── ContentView.swift         # Main view layout
├── TaskRowView.swift         # Task row view
├── SectionTabBar.swift       # Section tab bar
├── SettingsView.swift        # Settings window (Appearance · Update · About)
├── ExportCardView.swift      # Export rendering
├── Localization/             # i18n strings (13 languages)
├── build.sh                  # One-command build & deploy (dev)
├── release.sh                # One-command release script
├── .github/workflows/        # CI auto build & release
└── mcp-server/               # MCP Server
```

## Contributing

Issues and Pull Requests are welcome! See [Contributing Guide](CONTRIBUTING.md).

## License

[MIT](LICENSE) © notwin

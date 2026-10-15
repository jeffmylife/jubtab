# Working on the fork

JubTab is AltTab plus a thin layer of fork changes. The rule that shapes everything below: **keep upstream files as untouched as possible**, so `scripts/fork/update.sh` can merge every upstream release without conflicts.

## Building

Always build through `scripts/fork/build.sh [Release|Debug]` (or `ai/dev.sh` for a dev build). Building the Xcode project directly gives you an unbranded app without the fork's features. The script:

1. Copies the repo to `build-fork/<config>/`.
2. Rewrites every `AltTab` in Swift sources, localized strings, `Info.plist` and the contributors list to `JubTab`. The built app must contain no "alt tab" in any spelling; check with `grep -rlai 'alt.\?tab' <app>`.
3. Appends every file under `src/fork/` to `App.swift`, wrapped in `#sourceLocation` so compiler errors point at the real files. This is why new fork files need no Xcode project changes.
4. Swaps in `config/fork/app.png` and `config/fork/menubar-*.pdf` (Shiba sources in `config/fork/source/`).
5. Builds with xcodebuild; `config/fork.xcconfig` (included last by `config/release.xcconfig`) sets the name, bundle ID and signing.

`config/local.xcconfig` (gitignored) configures the dev build: "JubTab Dev", bundle ID `com.jeffmylife.jubtab-dev`.

## Updating from upstream

`scripts/fork/update.sh [--force]` fetches upstream's latest release tag, merges it, checks that the unlock survived, builds, installs and pushes. It stops with a notification on a merge conflict, a failed build, or a change to upstream's `LICENCE.md`.

## Where the fork touches upstream files

Keep this list short. Each line is a potential merge conflict.

| File | Change |
|---|---|
| `config/release.xcconfig` | includes `config/fork.xcconfig` |
| `src/App.swift` | Sparkle never starts; `Jump.start()`; `JumpFlyout.commitIfHovered()` in `focusTarget` |
| `src/pro/license/LicenseManager.swift` | `forkUnlocked` makes the license state Pro |
| `src/vendors/SparkleDelegate.swift` | no appcast URL |
| `src/Menubar.swift`, `GeneralTab.swift`, `AboutTab.swift`, `SettingsWindow.swift` | hide update, feedback, account, donation and Pro UI |
| `README.md` | ours; `.gitattributes` keeps it on merge |
| `CLAUDE.md` | includes this file |

## Fork features

All in `src/fork/jump/`:

- `JumpSources.swift`: Zen tabs (Zen's session file, switched through Accessibility), local servers (`lsof` plus an HTTP probe for pages), and cmux workspaces (the cmux CLI).
- `JumpItems.swift`: merges the sources and links servers to their workspace and Zen tab.
- `Jump.swift` and `JumpPanel.swift`: the ⌥Tab switcher, with its own event tap. JubTab's Carbon hotkey handler consumes every hotkey, so a Carbon hotkey would never reach it.
- `JumpSearch.swift`: search ranking. It reuses upstream's `SearchTestable.tierMatch` on titles and keywords, then boosts things you pick often (`jumpPicks` in the app's defaults). `JumpWindows.swift` adds JubTab's own windows.
- Search mode is entered by tapping ⌥Tab (a release within 0.3s, without moving) or double-tapping a bare ⌥. While it's open, the event tap swallows the keyboard and types into the drawn field. ⌘A/⌘C/⌘X/⌘V edit the query like a text field; other ⌘/⌃ shortcuts are ignored. Esc, a click outside, or ⌘Tab/⌘`/⌘Space close it (the last three go through).
- `JumpFlyout.swift`: the hover side menu in the ⌘Tab switcher.
- Diagnostics are logged to `~/Library/Logs/JubTab-jump.log`.

Fork code departs from `AGENTS.md` in two places, on purpose: the panels use SwiftUI, and the side menu polls the switcher's hover state rather than adding observer hooks to upstream code.

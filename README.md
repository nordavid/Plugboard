# Plugboard

A Mac app that finds every installed audio plug-in, shows what it is and removes it cleanly, for Logic Pro, FL Studio, Ableton Live, Pro Tools and any other DAW. The interface is in English, with a German localization that follows the system language.

## Features

- **Every format and location**: Audio Units, VST3, VST, CLAP, AAX (including Pro Tools' "Plug-Ins (Unused)"), AUv3 extensions, Waves plug-ins and WaveShells, WPAPI, MAS, RTAS, plus Core Audio and MIDI drivers. Both the user folder (`~/Library`) and the shared one (`/Library`) are scanned, including vendor subfolders. Extra folders can be added in Settings.
- **Details for each plug-in**: name, vendor, format, type (instrument, effect, MIDI), version, architecture (Universal, Apple silicon, Intel only, 32-bit), size, install and modification dates, location, bundle ID, code signature, Audio Unit codes and, for shells, the plug-ins they contain.
- **Plug-ins, not just files**: the AU, VST3, AAX and CLAP builds of one product appear as a single row with the formats inside. You can switch to one row per file.
- **Removal**: move to the Trash with Undo (⌘Z or the button in the confirmation), delete immediately after a confirmation, or uninstall completely.
- **Complete uninstall**: finds every format of a product plus its settings, caches, presets, Logic Pro plug-in settings, support folders and installer receipts. You choose what to remove from a list. Presets and support files start unselected.
- **Cleanup helpers**: plug-ins that can't load, Intel-only plug-ins that need Rosetta, VST2 copies of VST3 plug-ins, AAX plug-ins without Pro Tools installed, duplicate copies and older Waves versions, each with the space it frees.
- **Overview**: counts, disk space by format and vendor, the largest plug-ins and which formats the DAWs on your Mac actually load.
- **Export**: the current list as CSV that opens correctly in Excel and Numbers in any region.
- **Tools**: reset the Audio Unit cache, so Logic Pro and GarageBand validate every AU again. The list updates on its own when an installer adds or removes plug-ins.

## Safety

- The Trash is always the default. Deleting immediately requires a confirmation.
- An administrator password is requested only for plug-ins installed for all users that you don't own, once per operation, through the standard macOS prompt. Items it moves to the Trash are handed to you, so emptying the Trash never asks for a password.
- Every path is checked before removal: it must sit inside a plug-in or support folder and may never be a format folder itself or one of its parents. Symbolic links are never followed.
- Hard links, which Waves uses for its shells, are detected, so the size shown matches the space actually freed.

## Requirements

- macOS 14 Sonoma or later
- Xcode or the Command Line Tools (`xcode-select --install`)

## Build and run

```bash
make app        # universal app (Apple silicon + Intel) at build/Plugboard.app
make run        # build and open
make install    # copy to /Applications
make check      # core checks and translation check
make debug      # faster debug build for this architecture only
make snapshot   # render the window in several states to build/snapshots
make icon       # redraw the app icon
```

The build calls `swiftc` directly through `Scripts/build.sh`, because Swift Package Manager in Command Line Tools 15.0 stops with "unable to lookup item 'PlatformPath'". With Xcode or newer Command Line Tools, `swift build` works too; `Package.swift` describes the same modules.

Without a developer certificate the app is signed ad hoc, which is enough on the Mac that built it. To distribute it, sign with a Developer ID and notarize it afterwards:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
```

## Project layout

| Folder | Contents |
| --- | --- |
| `Sources/PlugboardCore` | Scanner, metadata readers (Info.plist, VST3 `moduleinfo.json`, Mach-O, code signature), disk usage, grouping, cleanup analysis, DAW detection, removal with path protection, leftover search, CSV export |
| `Sources/Plugboard` | SwiftUI app: sidebar, table, inspector, overview, Waves versions, review sheet, settings |
| `Sources/PlugboardChecks` | Checks for the core, including real removal and restore runs in a throwaway folder |
| `Resources` | Info.plist, localizations (`en.lproj`, `de.lproj`), app icon |
| `Scripts` | Build, bundle, icon generator, translation check |

## Localization

English is the development language. German lives in `Resources/de.lproj`, with plural rules in `Localizable.stringsdict`. `Scripts/check-localization.py` lists every user-facing string in the sources and fails when a German translation is missing.

The scan cache is stored in `~/Library/Caches/app.plugboard.Plugboard/`. Unchanged plug-ins are not read again on the next launch.

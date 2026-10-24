// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Plugboard",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Plugboard", targets: ["Plugboard"]),
    ],
    targets: [
        // Scanning, analysis and file operations. No UI code, so it can be checked headless.
        .target(
            name: "PlugboardCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        // The SwiftUI app. Localized strings live in Resources/*.lproj and are
        // copied into the .app bundle by Scripts/build-app.sh.
        .executableTarget(
            name: "Plugboard",
            dependencies: ["PlugboardCore"]
        ),
        // Self-contained checks for PlugboardCore. The Command Line Tools ship
        // without XCTest, so these run as a plain executable: `swift run PlugboardChecks`.
        .executableTarget(
            name: "PlugboardChecks",
            dependencies: ["PlugboardCore"]
        ),
    ]
)

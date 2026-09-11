// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libopus can arrive two ways:
//  1. Vendor/opus.xcframework, built by Scripts/build-opus-xcframework.sh for iOS (shim compiled in).
//  2. A system libopus found through pkg-config (brew install opus / apt install libopus-dev), used by
//     `swift test` on macOS and Linux so the codec wrapper is exercised for real.
// With neither, the pure-Swift targets still build and the PCM passthrough codec is used.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let xcframeworkPath = "Vendor/opus.xcframework"
let hasXCFramework = FileManager.default.fileExists(atPath: packageDir.appendingPathComponent(xcframeworkPath).path)
let hasSystemOpus = !hasXCFramework && [
    "/usr/include/opus/opus.h", "/usr/local/include/opus/opus.h", "/opt/homebrew/include/opus/opus.h",
].contains { FileManager.default.fileExists(atPath: $0) }
let hasOpus = hasXCFramework || hasSystemOpus

var audioDependencies: [Target.Dependency] = ["SottoCore"]
var audioSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
if hasXCFramework {
    audioDependencies.append("Copus")
    audioSettings.append(.define("SOTTO_HAS_OPUS"))
} else if hasSystemOpus {
    audioDependencies += ["Copus", "CopusShim"]
    audioSettings += [.define("SOTTO_HAS_OPUS"), .define("SOTTO_OPUS_SYSTEM")]
}

var targets: [Target] = [
    .target(
        name: "SottoCore",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "SottoAudio",
        dependencies: audioDependencies,
        swiftSettings: audioSettings
    ),
    .target(
        name: "SottoTransport",
        dependencies: ["SottoCore"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "SottoSession",
        dependencies: ["SottoCore", "SottoAudio", "SottoTransport"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(name: "SottoCoreTests", dependencies: ["SottoCore"]),
    .testTarget(name: "SottoAudioTests", dependencies: ["SottoAudio", "SottoCore"]),
    .testTarget(name: "SottoTransportTests", dependencies: ["SottoTransport", "SottoCore"]),
    .testTarget(name: "SottoSessionTests", dependencies: ["SottoSession", "SottoCore", "SottoAudio", "SottoTransport"]),
]

if hasXCFramework {
    targets.append(.binaryTarget(name: "Copus", path: xcframeworkPath))
} else if hasSystemOpus {
    targets.append(.systemLibrary(name: "Copus", path: "Sources/Copus", pkgConfig: "opus", providers: [.brew(["opus"]), .apt(["libopus-dev"])]))
    targets.append(.target(name: "CopusShim", dependencies: ["Copus"], path: "Sources/CopusShim"))
}

let package = Package(
    name: "SottoKit",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "SottoCore", targets: ["SottoCore"]),
        .library(name: "SottoAudio", targets: ["SottoAudio"]),
        .library(name: "SottoTransport", targets: ["SottoTransport"]),
        .library(name: "SottoSession", targets: ["SottoSession"]),
    ],
    targets: targets
)

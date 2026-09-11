// swift-tools-version: 6.0
import PackageDescription
import Foundation

// libopus is vended as a prebuilt xcframework produced by Scripts/build-opus-xcframework.sh.
// The binary target is only declared when the artefact exists so that `swift test` on a
// machine without it (Linux CI, a fresh checkout) still builds the pure-Swift targets.
let opusPath = "Vendor/opus.xcframework"
let hasOpus = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(opusPath).path)

var targets: [Target] = [
    .target(
        name: "SottoCore",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "SottoAudio",
        dependencies: ["SottoCore"] + (hasOpus ? ["Copus"] : []),
        swiftSettings: [.swiftLanguageMode(.v6)] + (hasOpus ? [.define("SOTTO_HAS_OPUS")] : [])
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

if hasOpus {
    targets.append(.binaryTarget(name: "Copus", path: opusPath))
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

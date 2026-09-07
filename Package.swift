// swift-tools-version: 5.9
// Anti-Bleed_mic Swift package.
//
// Targets:
//   AntiBleedCore      - platform-independent DSP/FSM/engine (macOS, Linux, Windows)
//   AntiBleedRealtime  - C lock-free rings shared by IOProc and DSP thread (all platforms)
//   AntiBleedAudio     - macOS Core Audio layer (aggregate capture + tap, virtual writer, AEC bridge)
//   AntiBleedApp       - macOS menu-bar app (SwiftUI)
//   AntiBleedCoreTests - XCTest suite for the core; runs wherever `swift test` runs
//
// macOS build order (see Docs/Testing.md):
//   Scripts/build-webrtc.sh                       -> build/webrtc (APM/AEC3 static lib)
//   cmake -S AECBridge -B build/aec && cmake --build build/aec   -> build/aec/libAECBridge.a
//   swift build -c release                        -> .build/release/AntiBleed
// Without AECBridge, AntiBleedAudio still compiles (WebRTCCanceller returns nil
// at runtime) and the engine stays in BYPASS.
import PackageDescription

var products: [Product] = [
    .library(name: "AntiBleedCore", targets: ["AntiBleedCore"]),
]
var targets: [Target] = [
    .target(
        name: "AntiBleedCore",
        path: "AntiBleedApp/Core"
    ),
    .target(
        name: "AntiBleedRealtime",
        path: "AntiBleedApp/Realtime",
        publicHeadersPath: "include"
    ),
    .testTarget(
        name: "AntiBleedCoreTests",
        dependencies: ["AntiBleedCore", "AntiBleedRealtime"],
        path: "Tests/SwiftCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "AntiBleed", targets: ["AntiBleedApp"]))
targets.append(contentsOf: [
    .systemLibrary(
        name: "AECBridgeC",
        path: "AECBridge/SwiftModule"
    ),
    .target(
        name: "AntiBleedAudio",
        dependencies: ["AntiBleedCore", "AntiBleedRealtime", "AECBridgeC"],
        path: "AntiBleedApp/Audio",
        linkerSettings: [
            .linkedFramework("CoreAudio"),
            .linkedFramework("AudioToolbox"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("AppKit"),
            .unsafeFlags(["-L", "build/aec", "-L", "build/webrtc/lib"]),
        ]
    ),
    .executableTarget(
        name: "AntiBleedApp",
        dependencies: ["AntiBleedCore", "AntiBleedAudio"],
        path: "AntiBleedApp",
        exclude: ["Core", "Realtime", "Audio", "App/Info.plist", "AntiBleedApp.entitlements"],
        sources: ["App", "UI"],
        linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]
    ),
])
#endif

let package = Package(
    name: "AntiBleed",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)

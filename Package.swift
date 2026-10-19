// swift-tools-version:6.0
// ForceIQ Peak (PR 1). One third-party dependency, pinned exactly (see THIRD_PARTY_NOTICES.md and Package.resolved).
import PackageDescription

let package = Package(
    name: "ForceIQPeak",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ForceIQPeak", targets: ["ForceIQPeak"])],
    dependencies: [
        // sindresorhus/KeyboardShortcuts, MIT, exact 3.1.0 (commit 772133d9dbe800fdac0473226822994c5c162c58)
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0"),
    ],
    targets: [
        // Pure logic: models, policy, URL router, geometry, prefs, view models. No AppKit, no network. Unit-tested.
        .target(name: "PeakCore", path: "Sources/PeakCore"),
        .executableTarget(name: "ForceIQPeak",
                          dependencies: ["PeakCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")],
                          path: "Sources/ForceIQPeak"),
        .testTarget(name: "PeakCoreTests", dependencies: ["PeakCore"], path: "Tests/PeakCoreTests", exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)

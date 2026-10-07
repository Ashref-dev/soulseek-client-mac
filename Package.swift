// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Arpeggio",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "Arpeggio", targets: ["Arpeggio"]), .library(name: "SoulseekCore", targets: ["SoulseekCore"]), .executable(name: "ArpeggioFixture", targets: ["ArpeggioFixture"]), .executable(name: "ArpeggioLive", targets: ["ArpeggioLive"]), .executable(name: "ArpeggioPerformance", targets: ["ArpeggioPerformance"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "SoulseekCore", dependencies: ["CZlib"]),
        .target(name: "Persistence", dependencies: ["CSQLite", "SoulseekCore"]),
        .target(name: "ShareIndexer", dependencies: ["SoulseekCore"]),
        .target(name: "TransferEngine", dependencies: ["SoulseekCore", "Persistence"]),
        .target(name: "ArpeggioServices", dependencies: ["SoulseekCore", "Persistence", "ShareIndexer", "TransferEngine"], path: "Sources/ApplicationServices"),
        .executableTarget(name: "Arpeggio", dependencies: ["ArpeggioServices"]),
        .target(name: "ProtocolFixtures", dependencies: ["SoulseekCore"]),
        .executableTarget(name: "ArpeggioFixture", dependencies: ["ArpeggioServices", "ProtocolFixtures"], path: "Tools/Fixture"),
        .executableTarget(name: "ArpeggioLive", dependencies: ["ArpeggioServices"], path: "Tools/Live"),
        .executableTarget(name: "ArpeggioPerformance", dependencies: ["ArpeggioServices", "ProtocolFixtures"], path: "Tools/Performance"),
        .testTarget(name: "CoreTests", dependencies: ["SoulseekCore", "Persistence", "ShareIndexer", "TransferEngine", "ArpeggioServices", "ProtocolFixtures", "Arpeggio"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ricochet",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RicochetCore", targets: ["RicochetCore"]),
        .executable(name: "ricochet", targets: ["Ricochet"]),
    ],
    dependencies: [
        // The transport, pairing, TLS and the gamepad event all come from AirPoint. This
        // game adds a handler and a scene; it reimplements none of that. 0.4 is the release
        // that added `pad_state`, which this game needed and which did not exist until it
        // was built.
        .package(url: "https://github.com/brianlo06/airpoint.git", .upToNextMinor(from: "0.4.1")),
    ],
    targets: [
        // Game rules, deliberately free of SpriteKit and of the network, so a whole match
        // can be replayed from a log of button states without a window server or a phone.
        .target(
            name: "RicochetCore",
            dependencies: [.product(name: "RemoteKit", package: "airpoint")],
            path: "Sources/RicochetCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Ricochet",
            dependencies: [
                "RicochetCore",
                .product(name: "RemoteKit", package: "airpoint"),
                .product(name: "RemoteServer", package: "airpoint"),
            ],
            path: "Sources/Ricochet",
            resources: [.copy("Resources/web")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RicochetTests",
            dependencies: ["RicochetCore"],
            path: "Tests/RicochetTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

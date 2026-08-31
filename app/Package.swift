// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "sezish",
    platforms: [
        .macOS("14.2"),
        .iOS("18.0"),
    ],
    products: [
        .executable(name: "sezish", targets: ["SezishApp"]),
        .library(name: "SezishCore", targets: ["SezishCore"]),
        .library(name: "SezishAsr", targets: ["SezishAsr"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            from: "1.20.0"
        ),
        // Sparkle 2 ships as a binary artifact: the framework plus the CLI tools
        // (generate_keys / generate_appcast) the Makefile drives.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "SezishApp",
            dependencies: [
                "SezishCore",
                "SezishAsr",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // swift-tools-version 6.1 predates the `.defaultIsolation` SwiftSetting
                // (6.2+), so the equivalent compiler flag gives the app target
                // MainActor-by-default isolation. Allowed here: SezishApp is the root
                // executable and is never consumed as a package dependency.
                .unsafeFlags(["-default-isolation", "MainActor"]),
            ]
        ),
        .target(
            name: "SezishCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "SezishAsr",
            dependencies: [
                "SezishCore",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            resources: [
                // Папка НЕ может называться Resources: на iOS codesign принимает
                // такой ресурсный бандл за старый macOS-овский («bundle format
                // unrecognized») и отказывается его подписывать — приложение
                // с локальной моделью не собирается вовсе.
                .copy("Bundled"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SezishAppTests",
            dependencies: ["SezishApp"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SezishCoreTests",
            dependencies: ["SezishCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SezishAsrTests",
            dependencies: ["SezishAsr"],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "speedcolors",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CHid",
            pkgConfig: "hidapi",
            providers: [.brew(["hidapi"])]
        ),
        .target(
            name: "SpeedColorsCore",
            dependencies: ["CHid"]
        ),
        .executableTarget(
            name: "speedcolors",
            dependencies: [
                "SpeedColorsCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "SpeedColorsUI",
            dependencies: ["SpeedColorsCore"]
        ),
    ]
)

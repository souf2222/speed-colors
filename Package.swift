// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeedColors",
    platforms: [.macOS(.v13)],
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
            name: "SpeedColors",
            dependencies: ["SpeedColorsCore"]
        ),
    ]
)

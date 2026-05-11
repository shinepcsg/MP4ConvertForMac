// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP4ConvertorApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MP4ConvertorApp", targets: ["MP4ConvertorApp"])
    ],
    targets: [
        .executableTarget(
            name: "MP4ConvertorApp",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP4Convertor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MP4Convertor", targets: ["MP4Convertor"])
    ],
    targets: [
        .executableTarget(
            name: "MP4Convertor",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

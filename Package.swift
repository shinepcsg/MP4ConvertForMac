// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP4Convertor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MP4ConvertorCore", targets: ["MP4ConvertorCore"]),
        .executable(name: "MP4Convertor", targets: ["MP4Convertor"]),
        .executable(name: "MP4MattermostBot", targets: ["MP4MattermostBot"])
    ],
    targets: [
        .target(
            name: "MP4ConvertorCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "MP4Convertor",
            dependencies: ["MP4ConvertorCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "MP4MattermostBot",
            dependencies: ["MP4ConvertorCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // 봇 CLI 바이너리에 Info.plist(NSMicrophoneUsageDescription 포함)를
                // __TEXT,__info_plist 섹션으로 임베드해 macOS TCC가 권한 안내 문구를 읽도록 한다.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/BotInfo.plist"
                ])
            ]
        )
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalMeet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LocalMeet", targets: ["LocalMeet"])
    ],
    targets: [
        .executableTarget(
            name: "LocalMeet",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("ScreenCaptureKit")
            ]
        ),
        .testTarget(
            name: "LocalMeetTests",
            dependencies: ["LocalMeet"]
        )
    ],
    swiftLanguageModes: [.v5]
)

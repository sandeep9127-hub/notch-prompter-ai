// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchCoach",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchCoach",
            path: "Sources/NotchCoach",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
            ]
        )
    ]
)

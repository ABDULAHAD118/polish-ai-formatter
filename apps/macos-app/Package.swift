// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhatsAppFormatter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "FormatterCore",
            resources: [.embedInCode("config.json")]
        ),
        .executableTarget(
            name: "WhatsAppFormatter",
            dependencies: ["FormatterCore"]
        ),
        // Command Line Tools has no XCTest and no default path to Testing, so this is a plain
        // assert-based runner: swift run CoreChecks
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["FormatterCore"],
            path: "Tests/CoreChecks"
        ),
    ]
)

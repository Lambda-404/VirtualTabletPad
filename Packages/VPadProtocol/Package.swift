// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VPadProtocol",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "VPadProtocol", targets: ["VPadProtocol"])
    ],
    targets: [
        .target(name: "VPadProtocol"),
        .testTarget(
            name: "VPadProtocolTests",
            dependencies: ["VPadProtocol"]
        )
    ]
)

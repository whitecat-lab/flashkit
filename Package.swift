// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FlashKit",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "FlashKitHelperProtocol",
            targets: ["FlashKitHelperProtocol"]
        ),
        .executable(
            name: "FlashKit",
            targets: ["FlashKit"]
        ),
        .executable(
            name: "FlashKitPrivilegedHelper",
            targets: ["FlashKitPrivilegedHelper"]
        ),
    ],
    targets: [
        .target(
            name: "FlashKitHelperProtocol"
        ),
        .executableTarget(
            name: "FlashKit",
            dependencies: ["FlashKitHelperProtocol"]
        ),
        .executableTarget(
            name: "FlashKitPrivilegedHelper",
            dependencies: ["FlashKitHelperProtocol"]
        ),
        .testTarget(
            name: "FlashKitTests",
            dependencies: ["FlashKit", "FlashKitHelperProtocol"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

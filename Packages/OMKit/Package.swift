// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OMKit",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "OMKit", targets: ["OMKit"])],
    targets: [
        // 相機通訊、配對資料、連線流程。不含畫面，Mac 與 iPhone/iPad 共用。
        .target(name: "OMKit"),
        .testTarget(name: "OMKitTests", dependencies: ["OMKit"]),
    ]
)

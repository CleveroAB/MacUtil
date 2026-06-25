// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUtil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacUtil", targets: ["MacUtil"])
    ],
    targets: [
        .executableTarget(
            name: "MacUtil",
            path: "Sources/MacUtil"
        )
    ],
    // Swift 5 language mode: AppKit/Carbon/AX are main-thread, callback-heavy C APIs.
    // Strict Swift 6 concurrency checking buys us nothing here and only adds friction.
    swiftLanguageModes: [.v5]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFPO",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PDFPO", targets: ["PDFPO"])
    ],
    targets: [
        .executableTarget(
            name: "PDFPO",
            path: "Sources/PDFPO",
            resources: [
                .process("../../Resources")
            ]
        )
    ]
)

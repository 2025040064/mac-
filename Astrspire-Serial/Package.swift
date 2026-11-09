// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AstrspireSerial",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SerialCore", targets: ["SerialCore"]),
        .executable(name: "AstrspireSerial", targets: ["AstrspireSerial"])
    ],
    dependencies: [.package(path: "Vendor/ORSSerialPort")],
    targets: [
        .target(name: "SerialCore"),
        .executableTarget(
            name: "AstrspireSerial",
            dependencies: ["SerialCore", .product(name: "ORSSerial", package: "ORSSerialPort")]
        ),
        .testTarget(name: "SerialCoreTests", dependencies: ["SerialCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["AstrspireSerial", "SerialCore"])
    ]
)

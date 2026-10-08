// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "HexLens",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "HexLens", targets: ["HexLens"]),
    .executable(name: "hexlens-cli", targets: ["hexlens-cli"]),
  ],
  targets: [
    // Git, análisis de fuentes, clasificación por arquitectura y grafo. Sin dependencias de UI.
    .target(name: "HexLensCore"),
    // Vistas SwiftUI y estado de la app.
    .target(name: "HexLensUI", dependencies: ["HexLensCore"]),
    .executableTarget(name: "HexLens", dependencies: ["HexLensUI"]),
    .executableTarget(name: "hexlens-cli", dependencies: ["HexLensCore", "HexLensUI"]),
    .testTarget(name: "HexLensCoreTests", dependencies: ["HexLensCore"]),
  ]
)

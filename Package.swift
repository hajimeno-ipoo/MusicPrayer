// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MusicPrayer",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "MusicPrayer", targets: ["MusicPrayer"])],
    targets: [
        .executableTarget(name: "MusicPrayer", path: "Sources", resources: [.copy("Rendering/Shaders.metal"), .copy("Rendering/LightSwarm.metal"), .copy("Rendering/WaterSurface.metal"), .copy("Rendering/TapeScene.metal"), .copy("Rendering/SpectrumCity.metal"), .copy("Rendering/CityStudioEnvironment.png"), .copy("Resources/Fonts"), .copy("AppleMusic/AppleMusicBridge.js")]),
        .testTarget(name: "MusicPrayerTests", dependencies: ["MusicPrayer"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)

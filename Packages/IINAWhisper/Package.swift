// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "IINAWhisper",
  platforms: [.macOS(.v12)],
  products: [.library(name: "whisper", targets: ["whisper"])],
  targets: [
    .binaryTarget(
      name: "whisper",
      path: "whisper.xcframework"
    )
  ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "flutter_patcher",
  platforms: [.iOS("13.0")],
  products: [.library(name: "flutter-patcher", targets: ["flutter_patcher"])],
  dependencies: [],
  targets: [.target(name: "flutter_patcher", dependencies: [])]
)

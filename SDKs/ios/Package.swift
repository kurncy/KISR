// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// Package manifest for the KISR Swift package.
// Notes:
// - Crypto backend is pluggable. You can bring your own, or enable Swift-Sodium.
// - See KISRCryptoAdapters for automatic bootstrap using canImport(Sodium)/Clibsodium.
// - If you add the Swift-Sodium dependency, also add "Sodium" to the target deps.
// ----------------------------------------------------------------------------
// Example (uncomment to use Swift-Sodium):
// .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.10.0")
// and in target dependencies: .product(name: "Sodium", package: "swift-sodium")
// ============================================================================

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "KISR",
	platforms: [
		.iOS(.v15), .macOS(.v12)
	],
	products: [
		.library(name: "KISR", targets: ["KISR"])
	],
	dependencies: [
		// Add Swift-Sodium if desired (see notes above)
		// .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.10.0")
	],
	targets: [
		.target(
			name: "KISR",
			dependencies: [
				// .product(name: "Sodium", package: "swift-sodium"), // optional
			],
			path: "Sources/KISR"
		)
	],
	swiftLanguageVersions: [.v5]
)

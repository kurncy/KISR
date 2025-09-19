// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
package org.kisr.sdk

sealed class KISRError(message: String) : Exception(message) {
	class DecryptionFailed : KISRError("Decryption failed")
	class UtxoSpent : KISRError("UTXO already spent")
	class NetworkMismatch : KISRError("Network mismatch")
	class FeeTooHigh : KISRError("Fee too high")
	class PayloadInvalid : KISRError("Invalid KISR payload")
	class WasmUnavailable(name: String) : KISRError("Missing WASM bridge: $name")
	class InvalidCode : KISRError("Invalid KISR code")
	class InvalidDeeplink : KISRError("Invalid KISR deeplink")
}

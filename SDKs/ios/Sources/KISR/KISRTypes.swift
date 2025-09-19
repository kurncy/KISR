// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
import Foundation


public struct KISRCreateParams {
	public let amountSompi: UInt64
	public let memo: String?
	public init(amountSompi: UInt64, memo: String? = nil) {
		self.amountSompi = amountSompi
		self.memo = memo
	}
}


public enum KISRError: Error, LocalizedError, Equatable {
	case decryptionFailed
	case utxoSpent
	case networkMismatch
	case feeTooHigh
	case payloadInvalid
	case wasmUnavailable(String)
	case invalidCode
	case invalidDeeplink

	public var errorDescription: String? {
		switch self {
		case .decryptionFailed: return "Decryption failed"
		case .utxoSpent: return "UTXO already spent"
		case .networkMismatch: return "Network mismatch"
		case .feeTooHigh: return "Fee too high"
		case .payloadInvalid: return "Invalid KISR payload"
		case .wasmUnavailable(let name): return "Missing WASM bridge: \(name)"
		case .invalidCode: return "Invalid KISR code"
		case .invalidDeeplink: return "Invalid KISR deeplink"
		}
	}
}

/// Wallet adapters act as the integration bridge to your SDK/WASM or native stack.
///
/// Responsibilities:
/// - Provide a self UTXO for anchoring and return its outpoint
/// - Pre-sign the outpoint input with flags 0x82 (None|AnyOneCanPay)
/// - Publish an anchor transaction carrying the KISR payload
/// - Fetch a transaction payload by txid (hex string)
/// - Assemble a redemption transaction given the decrypted payload and destination
/// - Broadcast a raw transaction to the network
public protocol KISRWalletAdapter {
	func currentNetworkId() -> UInt8
	func createSelfUtxo(amountSompi: UInt64) throws -> (txid: String, vout: UInt32, amountSompi: UInt64)
	func preSignInput(txid: String, vout: UInt32, sighashFlags: UInt8) throws -> Data
	func publishAnchorTransaction(payload: Data) throws -> String
	func assembleRedemption(toAddress: String, inputTxid: String, inputIndex: UInt32, inputAmountSompi: UInt64, presigHex: String, feeSompi: UInt64) throws -> Data
	func broadcastRedemption(rawTx: Data) throws -> String
}

public struct DecryptedPayload: Equatable {
	public let txid: String
	public let vout: UInt32
	public let amountSompi: UInt64
	public let presig: Data
	public let sighashFlags: UInt8
	public let inviterPubKey: Data
	public let networkId: UInt8
	public let memo: String
	public init(txid: String, vout: UInt32, amountSompi: UInt64, presig: Data, sighashFlags: UInt8, inviterPubKey: Data, networkId: UInt8, memo: String) {
		self.txid = txid
		self.vout = vout
		self.amountSompi = amountSompi
		self.presig = presig
		self.sighashFlags = sighashFlags
		self.inviterPubKey = inviterPubKey
		self.networkId = networkId
		self.memo = memo
	}
}

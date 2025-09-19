// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//
import Foundation

public final class KISRWalletAdapterJS: KISRWalletAdapter {
	private let bridge: KISRJSCoreBridge // use as an example of how to bridge to your SDK/WASM
	private let networkId: UInt8
	private let privateKey: String

	public init?(networkId: UInt8 = 0, privateKey: String) {
		guard let bridge = KISRJSCoreBridge() else { return nil }
		self.bridge = bridge
		self.networkId = networkId
		self.privateKey = privateKey
	}

	public func currentNetworkId() -> UInt8 { networkId }

	public func createSelfUtxo(amountSompi: UInt64) throws -> (txid: String, vout: UInt32, amountSompi: UInt64) {
		let network = (networkId == 0) ? "mainnet" : "testnet-10"
		let resAny = try bridge.callAsync("createUtxoToSelf", args: [[
			"privateKey": privateKey,
			"amountSompi": String(amountSompi),
			"network": network
		]])
		guard let res = resAny as? [String: Any], let txid = res["txid"] as? String else { throw KISRError.payloadInvalid }
		let index = (res["index"] as? Int) ?? 0
		let vout = UInt32(index)
		return (txid, vout, amountSompi)
	}

	public func preSignInput(txid: String, vout: UInt32, sighashFlags: UInt8) throws -> Data {
		let network = (networkId == 0) ? "mainnet" : "testnet-10"
		let resAny = try bridge.callAsync("preSignCreatedUtxo", args: [[
			"privateKey": privateKey,
			"network": network,
			"txid": txid,
			"index": Int(vout)
		]])
		guard let res = resAny as? [String: Any], let sigHex = res["signatureHex"] as? String else { throw KISRError.payloadInvalid }
		return Data(hexString: sigHex)
	}

	public func publishAnchorTransaction(payload: Data) throws -> String {
		let network = (networkId == 0) ? "mainnet" : "testnet-10"
		let resAny = try bridge.callAsync("createAnchorToSelfWithPayload", args: [[
			"privateKey": privateKey,
			"network": network,
			"payloadHex": payload.hexString
		]])
		guard let res = resAny as? [String: Any], let txid = res["txid"] as? String else { throw KISRError.payloadInvalid }
		return txid
	}

	public func assembleRedemption(toAddress: String, inputTxid: String, inputIndex: UInt32, inputAmountSompi: UInt64, presigHex: String, feeSompi: UInt64) throws -> Data {
		// Example adapter responsibility: bridge to your SDK/WASM to construct the raw tx.
		// For JS bridge, you would expose a `assembleRedemption` in kisr_core.js and call it here.
		// Returning error to indicate this must be implemented per-wallet.
		throw KISRError.wasmUnavailable("kaspa assembleRedemption not bridged in JS core")
	}

	public func broadcastRedemption(rawTx: Data) throws -> String {
		let network = (networkId == 0) ? "mainnet" : "testnet-10"
		let txid = try bridge.callAsync("submitRawTransactionHex", args: [rawTx.hexString, network])
		guard let id = txid as? String, !id.isEmpty else { throw KISRError.payloadInvalid }
		return id
	}
}

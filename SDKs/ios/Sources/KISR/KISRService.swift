// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
import Foundation

public final class KISR {
	private let wallet: KISRWalletAdapter
	private let remote: KISRRemote?

	public init(wallet: KISRWalletAdapter) { self.wallet = wallet; self.remote = nil; if KISRWasm.crypto == nil { KISRBootstrap.useAvailableCrypto() } }
	public init(wallet: KISRWalletAdapter, remote: KISRRemote?, autoBootstrapCrypto: Bool = true) {
		self.wallet = wallet
		self.remote = remote
		if autoBootstrapCrypto && KISRWasm.crypto == nil { KISRBootstrap.useAvailableCrypto() }
	}

	/// Creates a KISR invitation by:
	/// - creating a self UTXO via the adapter (bridge to your wallet SDK/WASM)
	/// - pre-signing its input
	/// - building & encrypting the KISR envelope
	/// - publishing anchor transaction with the payload
	public func createInvite(params: KISRCreateParams) throws -> URL {
		let utxo = try wallet.createSelfUtxo(amountSompi: params.amountSompi)
		let presig = try wallet.preSignInput(txid: utxo.txid, vout: utxo.vout, sighashFlags: 0x82)
		let code = try KISRCode.generate()
		let payload = try KISRPayload.buildAndEncrypt(code: code, utxo: utxo, presig: presig, networkId: wallet.currentNetworkId(), memo: params.memo)
		let anchor = try wallet.publishAnchorTransaction(payload: payload)
		guard let url = KISRDeeplink.build(code: code, txid: anchor) else { throw KISRError.invalidDeeplink }
		return url
	}

	/// Redeems a KISR invitation link by fetching the payload, decrypting,
	/// and asking the adapter (bridge to your SDK/WASM) to assemble the redemption transaction.
	public func redeemInvite(link: URL, destinationKaspaAddress: String, feeSompi: UInt64 = 2000) throws -> String {
		let parsed = try KISRDeeplink.parse(link)
		// Fetch KISR envelope natively from Kaspa API
		let payloadHex = try self.fetchTransactionPayloadHex(txid: parsed.txid)
		let payload = Data(hexString: payloadHex)
		guard let code = parsed.code else { throw KISRError.invalidCode }
		let decrypted = try KISRPayload.decrypt(code: code, envelope: payload)
		let rawTx = try wallet.assembleRedemption(
			toAddress: destinationKaspaAddress,
			inputTxid: decrypted.txid,
			inputIndex: decrypted.vout,
			inputAmountSompi: decrypted.amountSompi,
			presigHex: decrypted.presig.hexString,
			feeSompi: feeSompi
		)
		return try wallet.broadcastRedemption(rawTx: rawTx)
	}

	public func createUtxoToSelf(amountSompi: UInt64) throws -> (txid: String, vout: UInt32, amountSompi: UInt64) {
		return try wallet.createSelfUtxo(amountSompi: amountSompi)
	}

	public func preSignCreatedUtxo(txid: String, vout: UInt32, amountSompi: UInt64) throws -> Data {
		_ = amountSompi
		return try wallet.preSignInput(txid: txid, vout: vout, sighashFlags: 0x82)
	}

	public func buildKISREncryptedPayload(code: String, utxoTxid: String, utxoIndex: UInt32, amountSompi: UInt64, presigHex: String, inviterPubKeyHex: String? = nil, memo: String? = nil) throws -> Data {
		let presig = Data(hexString: presigHex)
		return try KISRPayload.buildAndEncrypt(code: code, utxo: (utxoTxid, utxoIndex, amountSompi), presig: presig, networkId: wallet.currentNetworkId(), memo: memo, inviterPubKeyHex: inviterPubKeyHex)
	}

	public func createAnchorToSelfWithPayload(payload: Data) throws -> String {
		return try wallet.publishAnchorTransaction(payload: payload)
	}

	public func fetchTransactionPayloadHex(txid: String) throws -> String {
		// Use native Swift HTTP via KISRRemote to read payload from Kaspa API
		let effectiveRemote: KISRRemote = self.remote ?? KISRRemote(config: .init(baseURL: URL(string: "https://api.kaspa.org")!))
		let networkString: String = (wallet.currentNetworkId() == 0) ? "mainnet" : "testnet-10"
		var result: Result<String, Error>!
		let sem = DispatchSemaphore(value: 0)
		Task {
			do {
				let hex = try await effectiveRemote.fetchPayload(txid: txid, network: networkString)
				result = .success(hex)
			} catch {
				result = .failure(error)
			}
			sem.signal()
		}
		sem.wait()
		return try result.get()
	}

	public func decryptKISRPayload(code: String, envelopeHex: String) throws -> DecryptedPayload {
		return try KISRPayload.decrypt(code: code, envelope: Data(hexString: envelopeHex))
	}

	/// Example convenience: ask the adapter to assemble and broadcast from a pre-decrypted payload.
	public func assembleAndBroadcastRedemption(toAddress: String, decrypted: DecryptedPayload, feeSompi: UInt64 = 2000) throws -> String {
		let raw = try wallet.assembleRedemption(
			toAddress: toAddress,
			inputTxid: decrypted.txid,
			inputIndex: decrypted.vout,
			inputAmountSompi: decrypted.amountSompi,
			presigHex: decrypted.presig.hexString,
			feeSompi: feeSompi
		)
		return try wallet.broadcastRedemption(rawTx: raw)
	}
}

enum KISRCode {
	private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
	static func generate() throws -> String {
		var bytes = [UInt8](repeating: 0, count: 8)
		let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		if status != errSecSuccess {
			for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
		}
		let chars: [Character] = bytes.map { b in
			let idx = Int(b) % alphabet.count
			return alphabet[idx]
		}
		let code = String(chars)
		return "KISR-" + code
	}
	static func validate(_ code: String) -> Bool {
		guard code.hasPrefix("KISR-") else { return false }
		let body = code.dropFirst(5)
		guard body.count == 8 else { return false }
		for c in body { if !alphabet.contains(c) { return false } }
		return true
	}
}

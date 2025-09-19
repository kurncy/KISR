// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//
package org.kisr.sdk

class KISRWalletAdapterJS(
	private val bridge: KISRJSCoreBridge,
	private val networkId: UByte = 0u,
	private val privateKey: String
) : KISRWalletAdapter {
	override fun currentNetworkId(): UByte = networkId

	override fun createSelfUtxo(amountSompi: Long): Triple<String, UInt, Long> {
		val network = if (networkId == 0u.toUByte()) "mainnet" else "testnet-10"
		val res = bridge.call(
			name = "createUtxoToSelf",
			args = listOf(mapOf(
				"privateKey" to privateKey,
				"amountSompi" to amountSompi.toString(),
				"network" to network
			))
		) as? Map<*, *> ?: throw KISRError.PayloadInvalid()
		val txid = (res["txid"] as? String) ?: throw KISRError.PayloadInvalid()
		val index = (res["index"] as? Number)?.toInt() ?: 0
		return Triple(txid, index.toUInt(), amountSompi)
	}

	override fun preSignInput(txid: String, vout: UInt, sighashFlags: UByte): ByteArray {
		val network = if (networkId == 0u.toUByte()) "mainnet" else "testnet-10"
		val res = bridge.call(
			name = "preSignCreatedUtxo",
			args = listOf(mapOf(
				"privateKey" to privateKey,
				"network" to network,
				"txid" to txid,
				"index" to vout.toInt()
			))
		) as? Map<*, *> ?: throw KISRError.PayloadInvalid()
		val sigHex = (res["signatureHex"] as? String) ?: throw KISRError.PayloadInvalid()
		return org.kisr.sdk.internal.hexStringToBytes(sigHex)
	}

	override fun publishAnchorTransaction(payload: ByteArray): String {
		val network = if (networkId == 0u.toUByte()) "mainnet" else "testnet-10"
		val res = bridge.call(
			name = "createAnchorToSelfWithPayload",
			args = listOf(mapOf(
				"privateKey" to privateKey,
				"network" to network,
				"payloadHex" to org.kisr.sdk.internal.bytesToHex(payload)
			))
		) as? Map<*, *> ?: throw KISRError.PayloadInvalid()
		return (res["txid"] as? String) ?: throw KISRError.PayloadInvalid()
	}

	override fun assembleRedemption(
		toAddress: String,
		inputTxid: String,
		inputIndex: UInt,
		inputAmountSompi: Long,
		presigHex: String,
		feeSompi: Long
	): ByteArray {
		throw KISRError.WasmUnavailable("kaspa assembleRedemption not bridged in JS core")
	}

	override fun broadcastRedemption(rawTx: ByteArray): String {
		val network = if (networkId == 0u.toUByte()) "mainnet" else "testnet-10"
		val id = bridge.call(
			name = "submitRawTransactionHex",
			args = listOf(org.kisr.sdk.internal.bytesToHex(rawTx), network)
		) as? String ?: throw KISRError.PayloadInvalid()
		return id
	}
}

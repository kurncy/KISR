// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
package org.kisr.sdk

import java.util.*

data class KISRCreateParams(
	val amountSompi: Long,
	val memo: String? = null
)

interface KISRWalletAdapter {
	fun currentNetworkId(): UByte // 0 mainnet, 1 testnet
	fun createSelfUtxo(amountSompi: Long): Triple<String, UInt, Long> // txid, vout, amount
	fun preSignInput(txid: String, vout: UInt, sighashFlags: UByte): ByteArray
	fun publishAnchorTransaction(payload: ByteArray): String // returns txid
	fun assembleRedemption(
		toAddress: String,
		inputTxid: String,
		inputIndex: UInt,
		inputAmountSompi: Long,
		presigHex: String,
		feeSompi: Long
	): ByteArray
	fun broadcastRedemption(rawTx: ByteArray): String
}

data class DecryptedPayload(
	val txid: String,
	val vout: UInt,
	val amountSompi: Long,
	val presig: ByteArray,
	val sighashFlags: UByte,
	val inviterPubKey: ByteArray,
	val networkId: UByte,
	val memo: String
)

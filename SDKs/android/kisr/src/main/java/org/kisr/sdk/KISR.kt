// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//

package org.kisr.sdk

import org.kisr.sdk.internal.KISRBootstrap
import org.kisr.sdk.internal.KISRWasm
import org.kisr.sdk.internal.bytesToHex
import org.kisr.sdk.internal.hexStringToBytes

class KISR(private val wallet: KISRWalletAdapter, private val remote: KISRRemote? = null, autoBootstrapCrypto: Boolean = true) {
	init {
		if (autoBootstrapCrypto && KISRWasm.crypto == null) {
			KISRBootstrap.useAvailableCrypto()
		}
	}

	fun createInvite(params: KISRCreateParams): String {
		val utxo = wallet.createSelfUtxo(params.amountSompi)
		val presig = wallet.preSignInput(txid = utxo.first, vout = utxo.second, sighashFlags = 0x82u)
		val code = KISRCode.generate()
		val payload = KISRPayload.buildAndEncrypt(code = code, utxo = utxo, presig = presig, networkId = wallet.currentNetworkId(), memo = params.memo)
		val anchor = wallet.publishAnchorTransaction(payload)
		return KISRDeeplink.build(code = code, txid = anchor)
	}

	fun redeemInvite(link: String, destinationKaspaAddress: String, feeSompi: Long = 2000): String {
		val (txid, codeOpt) = KISRDeeplink.parse(link)
		val payloadHex = fetchTransactionPayloadHex(txid)
		val payload = hexStringToBytes(payloadHex)
		val code = codeOpt ?: throw KISRError.InvalidCode()
		val decrypted = KISRPayload.decrypt(code = code, envelope = payload)
		val rawTx = wallet.assembleRedemption(
			toAddress = destinationKaspaAddress,
			inputTxid = decrypted.txid,
			inputIndex = decrypted.vout,
			inputAmountSompi = decrypted.amountSompi,
			presigHex = bytesToHex(decrypted.presig),
			feeSompi = feeSompi
		)
		return wallet.broadcastRedemption(rawTx)
	}

	fun createUtxoToSelf(amountSompi: Long): Triple<String, UInt, Long> = wallet.createSelfUtxo(amountSompi)

	fun preSignCreatedUtxo(txid: String, vout: UInt, amountSompi: Long): ByteArray {
		return wallet.preSignInput(txid = txid, vout = vout, sighashFlags = 0x82u)
	}

	fun buildKISREncryptedPayload(
		code: String,
		utxoTxid: String,
		utxoIndex: UInt,
		amountSompi: Long,
		presigHex: String,
		inviterPubKeyHex: String? = null,
		memo: String? = null
	): ByteArray {
		val presig = hexStringToBytes(presigHex)
		return KISRPayload.buildAndEncrypt(code, Triple(utxoTxid, utxoIndex, amountSompi), presig, wallet.currentNetworkId(), memo, inviterPubKeyHex)
	}

	fun createAnchorToSelfWithPayload(payload: ByteArray): String = wallet.publishAnchorTransaction(payload)

	fun fetchTransactionPayloadHex(txid: String): String {
		val effectiveRemote = remote ?: KISRRemote(KISRRemote.Config())
		val networkString = if (wallet.currentNetworkId() == 0.toUByte()) "mainnet" else "testnet-10"
		return effectiveRemote.fetchPayload(txid, networkString)
	}

	fun decryptKISRPayload(code: String, envelopeHex: String): DecryptedPayload {
		return KISRPayload.decrypt(code, hexStringToBytes(envelopeHex))
	}

	fun assembleAndBroadcastRedemption(toAddress: String, decrypted: DecryptedPayload, feeSompi: Long = 2000): String {
		val raw = wallet.assembleRedemption(
			toAddress = toAddress,
			inputTxid = decrypted.txid,
			inputIndex = decrypted.vout,
			inputAmountSompi = decrypted.amountSompi,
			presigHex = bytesToHex(decrypted.presig),
			feeSompi = feeSompi
		)
		return wallet.broadcastRedemption(raw)
	}
}

private object KISRCode {
	private val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".toCharArray()
	fun generate(): String {
		val bytes = ByteArray(8)
		java.security.SecureRandom().nextBytes(bytes)
		val chars = CharArray(8) { i ->
			val idx = (bytes[i].toInt() and 0xFF) % alphabet.size
			alphabet[idx]
		}
		return "KISR-" + String(chars)
	}
	fun validate(code: String): Boolean {
		if (!code.startsWith("KISR-")) return false
		val body = code.substring(5)
		if (body.length != 8) return false
		for (c in body) if (!alphabet.contains(c)) return false
		return true
	}
}

// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//

package org.kisr.sdk

import org.kisr.sdk.internal.*

internal object KISRPayload {
	fun buildAndEncrypt(
		code: String,
		utxo: Triple<String, UInt, Long>,
		presig: ByteArray,
		networkId: UByte,
		memo: String?,
		inviterPubKeyHex: String? = null
	): ByteArray {
		val crypto = KISRWasm.crypto ?: throw KISRError.WasmUnavailable("crypto")
		val version = byteArrayOf(EnvelopeConst.version.toByte())
		val salt = crypto.randomBytes(16)
		val nonce = crypto.randomBytes(24)
		val key = crypto.pwhashArgon2id(32, code.toByteArray(Charsets.UTF_8), salt, opsLimit = 2u, memLimitBytes = (64uL * 1024uL * 1024uL))

		val tlvParts = ArrayList<ByteArray>()
		val outpoint = txidHexToLE32(utxo.first) + utxo.second.toLe32()
		tlvParts += writeTLV(TLVTag.Outpoint, outpoint)
		tlvParts += writeTLV(TLVTag.Presig, presig)
		tlvParts += writeTLV(TLVTag.Sighash, byteArrayOf(0x82.toByte()))
		if (!inviterPubKeyHex.isNullOrEmpty()) tlvParts += writeTLV(TLVTag.InviterPubKey, hexStringToBytes(inviterPubKeyHex))
		tlvParts += writeTLV(TLVTag.AmountSompi, utxo.third.toULong().toLe64())
		val netIdCompact: UByte = if (networkId == 0.toUByte()) 0u else 1u
		tlvParts += writeTLV(TLVTag.NetworkId, byteArrayOf(netIdCompact.toByte()))
		val now = (System.currentTimeMillis() / 1000L).toULong()
		tlvParts += writeTLV(TLVTag.Timestamp, now.toLe64())
		if (!memo.isNullOrEmpty()) {
			require(memo.length <= 40) { "memo too long" }
			tlvParts += writeTLV(TLVTag.Memo, memo.toByteArray(Charsets.UTF_8))
		}
		val tlv = tlvParts.fold(ByteArray(0)) { acc, part -> acc + part }

		val ad = version + salt
		val cipher = crypto.aeadXChaCha20Poly1305IetfEncrypt(tlv, ad, nonce, key)
		return EnvelopeConst.prefix + version + salt + nonce + cipher
	}

	fun decrypt(code: String, envelope: ByteArray): DecryptedPayload {
		val crypto = KISRWasm.crypto ?: throw KISRError.WasmUnavailable("crypto")
		val pfx = EnvelopeConst.prefix
		if (envelope.size <= pfx.size || !envelope.copyOfRange(0, pfx.size).contentEquals(pfx)) throw KISRError.PayloadInvalid()
		val buf = envelope.copyOfRange(pfx.size, envelope.size)
		if (buf.size < 1 + 16 + 24 + 16) throw KISRError.PayloadInvalid()
		val version = buf[0]
		if (version.toUByte() != EnvelopeConst.version) throw KISRError.PayloadInvalid()
		val salt = buf.copyOfRange(1, 1 + 16)
		val nonce = buf.copyOfRange(1 + 16, 1 + 16 + 24)
		val ciphertext = buf.copyOfRange(1 + 16 + 24, buf.size)
		val key = crypto.pwhashArgon2id(32, code.toByteArray(Charsets.UTF_8), salt, opsLimit = 2u, memLimitBytes = (64uL * 1024uL * 1024uL))
		val ad = byteArrayOf(version) + salt
		val plaintext = crypto.aeadXChaCha20Poly1305IetfDecrypt(ciphertext, ad, nonce, key)
		val tlv = readTLV(plaintext)

		val outpoint = tlv[TLVTag.Outpoint] ?: throw KISRError.PayloadInvalid()
		if (outpoint.size != 36) throw KISRError.PayloadInvalid()
		val txid = le32ToTxidHex(outpoint.copyOfRange(0, 32))
		val vout = outpoint.copyOfRange(32, 36).toUInt32LE()
		val presigHex = bytesToHex(tlv[TLVTag.Presig] ?: ByteArray(0))
		val sighashFlags = tlv[TLVTag.Sighash]?.firstOrNull()?.toUByte() ?: 0x82u
		val inviterPubKey = tlv[TLVTag.InviterPubKey] ?: ByteArray(0)
		val amountSompi = (tlv[TLVTag.AmountSompi]?.toUInt64LE() ?: 0uL).toLong()
		val networkId = tlv[TLVTag.NetworkId]?.firstOrNull()?.toUByte() ?: 0u
		val memoBytes = tlv[TLVTag.Memo]
		val memo = memoBytes?.toString(Charsets.UTF_8) ?: ""

		return DecryptedPayload(
			txid = txid,
			vout = vout,
			amountSompi = amountSompi,
			presig = hexStringToBytes(presigHex),
			sighashFlags = sighashFlags,
			inviterPubKey = inviterPubKey,
			networkId = networkId,
			memo = memo
		)
	}
}

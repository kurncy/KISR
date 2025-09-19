// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
package org.kisr.sdk.internal

import com.goterl.lazysodium.LazySodiumAndroid
import com.goterl.lazysodium.SodiumAndroid
import com.goterl.lazysodium.interfaces.AEAD.XChaCha20Poly1305Ietf
import com.goterl.lazysodium.utils.Key
import org.kisr.sdk.KISRError

internal interface KISRWasmCrypto {
	@Throws(Exception::class)
	fun randomBytes(count: Int): ByteArray
	@Throws(Exception::class)
	fun pwhashArgon2id(outputLength: Int, password: ByteArray, salt: ByteArray, opsLimit: UInt, memLimitBytes: ULong): ByteArray
	@Throws(Exception::class)
	fun aeadXChaCha20Poly1305IetfEncrypt(plaintext: ByteArray, associatedData: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray
	@Throws(Exception::class)
	fun aeadXChaCha20Poly1305IetfDecrypt(ciphertext: ByteArray, associatedData: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray
}

internal object KISRWasm {
	@Volatile var crypto: KISRWasmCrypto? = null
}

internal object KISRBootstrap {
	fun useAvailableCrypto() {
		try {
			KISRWasm.crypto = SodiumCryptoAdapter()
		} catch (_: Throwable) {
			// consumer must set crypto manually
		}
	}
}

internal class SodiumCryptoAdapter : KISRWasmCrypto {
	private val sodium = SodiumAndroid()
	private val lazy = LazySodiumAndroid(sodium)

	override fun randomBytes(count: Int): ByteArray {
		val out = ByteArray(count)
		sodium.randombytes_buf(out, count.toLong())
		return out
	}

	override fun pwhashArgon2id(outputLength: Int, password: ByteArray, salt: ByteArray, opsLimit: UInt, memLimitBytes: ULong): ByteArray {
		val out = ByteArray(outputLength)
		val rc = sodium.crypto_pwhash(
			out,
			outputLength.toLong(),
			String(password, Charsets.UTF_8),
			password.size.toLong(),
			salt,
			opsLimit.toLong(),
			memLimitBytes.toLong(),
			SodiumAndroid.crypto_pwhash_ALG_ARGON2ID13
		)
		if (rc != 0) throw KISRError.WasmUnavailable("sodium.crypto_pwhash")
		return out
	}

	override fun aeadXChaCha20Poly1305IetfEncrypt(plaintext: ByteArray, associatedData: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray {
		val aead = lazy.aeadXChaCha20Poly1305Ietf()
		val macLen = XChaCha20Poly1305Ietf.MACBYTES
		val out = ByteArray(plaintext.size + macLen)
		val ok = aead.encrypt(
			out,
			plaintext,
			associatedData,
			nonce,
			Key.fromBytes(key)
		)
		if (!ok) throw KISRError.WasmUnavailable("sodium.aead.encrypt")
		return out
	}

	override fun aeadXChaCha20Poly1305IetfDecrypt(ciphertext: ByteArray, associatedData: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray {
		val aead = lazy.aeadXChaCha20Poly1305Ietf()
		val out = ByteArray(ciphertext.size - XChaCha20Poly1305Ietf.MACBYTES)
		val ok = aead.decrypt(
			out,
			ciphertext,
			associatedData,
			nonce,
			Key.fromBytes(key)
		)
		if (!ok) throw KISRError.DecryptionFailed()
		return out
	}
}

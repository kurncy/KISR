// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
import Foundation

public enum KISRBootstrap {
	/// Sets `KISRWasm.crypto` to an available adapter if the corresponding module is present.
	/// - Order of preference: swift-sodium (Sodium), then Clibsodium.
	public static func useAvailableCrypto() {
		#if canImport(Sodium)
		KISRWasm.crypto = SodiumCryptoAdapter()
		#elseif canImport(Clibsodium)
		KISRWasm.crypto = SodiumCAdapter()
		#else
		// No crypto backend available; consumer must set KISRWasm.crypto manually
		#endif
	}
}

#if canImport(Sodium)
import Sodium

public final class SodiumCryptoAdapter: KISRWasmCrypto {
	private let sodium = Sodium()

	public init() {}

	public func randomBytes(count: Int) throws -> Data {
		guard let bytes = sodium.randomBytes.buf(length: count) else { throw KISRError.wasmUnavailable("sodium.random") }
		return Data(bytes)
	}

	public func pwhashArgon2id(outputLength: Int, password: Data, salt: Data, opsLimit: UInt32, memLimitBytes: UInt64) throws -> Data {
		let ops = sodium.pwHash.OpsLimit(opsLimit)
		let mem = sodium.pwHash.MemLimit(memLimitBytes)
		guard let out = sodium.pwHash.hash(outputLength: outputLength,
				password: Array(password),
				salt: Array(salt),
				opslimit: ops,
				memlimit: mem,
				alg: .argon2id13) else { throw KISRError.wasmUnavailable("sodium.pwhash") }
		return Data(out)
	}

	public func aeadXChaCha20Poly1305IetfEncrypt(plaintext: Data, associatedData: Data, nonce: Data, key: Data) throws -> Data {
		guard let cipher = sodium.aead.xchacha20poly1305ietf.encrypt(message: Array(plaintext),
				additionalData: Array(associatedData),
				nonce: Array(nonce),
				secretKey: Array(key)) else { throw KISRError.wasmUnavailable("sodium.aead.encrypt") }
		return Data(cipher)
	}

	public func aeadXChaCha20Poly1305IetfDecrypt(ciphertext: Data, associatedData: Data, nonce: Data, key: Data) throws -> Data {
		guard let plain = sodium.aead.xchacha20poly1305ietf.decrypt(authenticatedCipherText: Array(ciphertext),
				additionalData: Array(associatedData),
				nonce: Array(nonce),
				secretKey: Array(key)) else { throw KISRError.decryptionFailed }
		return Data(plain)
	}
}
#endif

#if canImport(Clibsodium)
import Clibsodium

public final class SodiumCAdapter: KISRWasmCrypto {
	public init() { if (sodium_init() == -1) { /* ignore init failure; calls will error */ } }

	public func randomBytes(count: Int) throws -> Data {
		var out = Data(count: count)
		out.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
			if let base = ptr.baseAddress { randombytes_buf(base, count) }
		}
		return out
	}

	public func pwhashArgon2id(outputLength: Int, password: Data, salt: Data, opsLimit: UInt32, memLimitBytes: UInt64) throws -> Data {
		var out = Data(count: outputLength)
		let res = out.withUnsafeMutableBytes { outPtr -> Int32 in
			password.withUnsafeBytes { passPtr in
				salt.withUnsafeBytes { saltPtr in
					crypto_pwhash(outPtr.bindMemory(to: UInt8.self).baseAddress, UInt64(outputLength),
						passPtr.bindMemory(to: CChar.self).baseAddress, UInt64(password.count),
						saltPtr.bindMemory(to: UInt8.self).baseAddress,
						UInt64(opsLimit), memLimitBytes,
						UInt32(crypto_pwhash_ALG_ARGON2ID13))
				}
			}
		}
		guard res == 0 else { throw KISRError.wasmUnavailable("sodium.crypto_pwhash") }
		return out
	}

	public func aeadXChaCha20Poly1305IetfEncrypt(plaintext: Data, associatedData: Data, nonce: Data, key: Data) throws -> Data {
		var cipher = Data(count: plaintext.count + Int(crypto_aead_xchacha20poly1305_ietf_ABYTES))
		var cipherLen: UInt64 = 0
		let rc = cipher.withUnsafeMutableBytes { cPtr in
			plaintext.withUnsafeBytes { mPtr in
				associatedData.withUnsafeBytes { adPtr in
					nonce.withUnsafeBytes { nPtr in
						key.withUnsafeBytes { kPtr in
							crypto_aead_xchacha20poly1305_ietf_encrypt(
								cPtr.bindMemory(to: UInt8.self).baseAddress,
								&cipherLen,
								mPtr.bindMemory(to: UInt8.self).baseAddress,
								UInt64(plaintext.count),
								adPtr.bindMemory(to: UInt8.self).baseAddress,
								UInt64(associatedData.count),
								nil,
								nPtr.bindMemory(to: UInt8.self).baseAddress,
								kPtr.bindMemory(to: UInt8.self).baseAddress
							)
						}
					}
				}
			}
		}
		guard rc == 0 else { throw KISRError.wasmUnavailable("sodium.aead.encrypt") }
		return cipher.prefix(Int(cipherLen))
	}

	public func aeadXChaCha20Poly1305IetfDecrypt(ciphertext: Data, associatedData: Data, nonce: Data, key: Data) throws -> Data {
		var plain = Data(count: max(0, ciphertext.count - Int(crypto_aead_xchacha20poly1305_ietf_ABYTES)))
		var plainLen: UInt64 = 0
		let rc = plain.withUnsafeMutableBytes { pPtr in
			ciphertext.withUnsafeBytes { cPtr in
				associatedData.withUnsafeBytes { adPtr in
					nonce.withUnsafeBytes { nPtr in
						key.withUnsafeBytes { kPtr in
							crypto_aead_xchacha20poly1305_ietf_decrypt(
								pPtr.bindMemory(to: UInt8.self).baseAddress,
								&plainLen,
								nil,
								cPtr.bindMemory(to: UInt8.self).baseAddress,
								UInt64(ciphertext.count),
								adPtr.bindMemory(to: UInt8.self).baseAddress,
								UInt64(associatedData.count),
								nPtr.bindMemory(to: UInt8.self).baseAddress,
								kPtr.bindMemory(to: UInt8.self).baseAddress
							)
						}
					}
				}
			}
		}
		guard rc == 0 else { throw KISRError.decryptionFailed }
		return plain.prefix(Int(plainLen))
	}
}
#endif

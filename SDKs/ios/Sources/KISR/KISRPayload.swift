// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
import Foundation

struct KISRPayload {
	static func buildAndEncrypt(code: String, utxo: (txid: String, vout: UInt32, amountSompi: UInt64), presig: Data, networkId: UInt8, memo: String?, inviterPubKeyHex: String? = nil) throws -> Data {
		guard let crypto = KISRWasm.crypto else { throw KISRError.wasmUnavailable("crypto") }
		let version = Data([EnvelopeConst.version])
		let salt = try crypto.randomBytes(count: 16)
		let nonce = try crypto.randomBytes(count: 24)
		let key = try crypto.pwhashArgon2id(outputLength: 32, password: Data(code.utf8), salt: salt, opsLimit: 2, memLimitBytes: 64 * 1024 * 1024)

		var tlv = Data()
		let outpoint = txidHexToLE32(utxo.txid) + utxo.vout.le32
		tlv.append(writeTLV(tag: .outpoint, value: outpoint))
		tlv.append(writeTLV(tag: .presig, value: presig))
		tlv.append(writeTLV(tag: .sighash, value: Data([0x82])))
		if let inviter = inviterPubKeyHex, !inviter.isEmpty { tlv.append(writeTLV(tag: .inviterPubKey, value: Data(hexString: inviter))) }
		tlv.append(writeTLV(tag: .amountSompi, value: utxo.amountSompi.le64))
		let netIdCompact: UInt8 = (networkId == 0) ? 0 : 1
		tlv.append(writeTLV(tag: .networkId, value: Data([netIdCompact])))
		let now = UInt64(Date().timeIntervalSince1970)
		tlv.append(writeTLV(tag: .timestamp, value: now.le64))
		if let memo, !memo.isEmpty {
			if memo.count > 40 { throw KISRError.payloadInvalid }
			tlv.append(writeTLV(tag: .memo, value: Data(memo.utf8)))
		}

		let ad = version + salt
		let cipher = try crypto.aeadXChaCha20Poly1305IetfEncrypt(plaintext: tlv, associatedData: ad, nonce: nonce, key: key)
		let envelope = EnvelopeConst.prefix + version + salt + nonce + cipher
		return envelope
	}

	static func decrypt(code: String, envelope: Data) throws -> DecryptedPayload {
		guard let crypto = KISRWasm.crypto else { throw KISRError.wasmUnavailable("crypto") }
		guard envelope.count > EnvelopeConst.prefix.count, envelope.prefix(EnvelopeConst.prefix.count) == EnvelopeConst.prefix else { throw KISRError.payloadInvalid }
		let buf = envelope.dropFirst(EnvelopeConst.prefix.count)
		guard buf.count >= 1 + 16 + 24 + 16 else { throw KISRError.payloadInvalid }
		let version = buf[buf.startIndex]
		guard version == EnvelopeConst.version else { throw KISRError.payloadInvalid }
		let salt = buf.dropFirst(1).prefix(16)
		let nonce = buf.dropFirst(1 + 16).prefix(24)
		let ciphertext = buf.dropFirst(1 + 16 + 24)
		let key = try crypto.pwhashArgon2id(outputLength: 32, password: Data(code.utf8), salt: Data(salt), opsLimit: 2, memLimitBytes: 64 * 1024 * 1024)
		let ad = Data([version]) + Data(salt)
		let plaintext = try crypto.aeadXChaCha20Poly1305IetfDecrypt(ciphertext: Data(ciphertext), associatedData: ad, nonce: Data(nonce), key: key)
		let tlv = try readTLV(plaintext)

		guard let outpoint = tlv[.outpoint], outpoint.count == 36 else { throw KISRError.payloadInvalid }
		let txid = le32ToTxidHex(outpoint.prefix(32))
		let vout = outpoint.suffix(4).toUInt32LE()
		let presigHex = tlv[.presig]?.hexString ?? ""
		let sighashFlags = tlv[.sighash]?.first ?? 0x82
		let inviterPubKey = tlv[.inviterPubKey] ?? Data()
		let amountSompi = (tlv[.amountSompi]?.toUInt64LE()) ?? 0
		let networkId = tlv[.networkId]?.first ?? 0
		let memoData = tlv[.memo]
		let memo = memoData != nil ? String(data: memoData!, encoding: .utf8) ?? "" : ""

		return DecryptedPayload(txid: txid, vout: vout, amountSompi: amountSompi, presig: Data(hexString: presigHex), sighashFlags: sighashFlags, inviterPubKey: inviterPubKey, networkId: networkId, memo: memo)
	}
}

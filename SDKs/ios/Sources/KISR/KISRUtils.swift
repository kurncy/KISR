// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
import Foundation

enum TLVTag: UInt8 {
	case outpoint = 0x01
	case presig = 0x02
	case sighash = 0x03
	case inviterPubKey = 0x04
	case amountSompi = 0x05
	case networkId = 0x06
	case timestamp = 0x07
	case memo = 0x08
}

enum EnvelopeConst {
	static let prefix = Data("KISR-".utf8)
	static let version: UInt8 = 0x01
}

func writeTLV(tag: TLVTag, value: Data) -> Data {
	var out = Data()
	out.append(tag.rawValue)
	var len = UInt16(value.count).bigEndian
	withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
	out.append(value)
	return out
}

func readTLV(_ buf: Data) throws -> [TLVTag: Data] {
	var out: [TLVTag: Data] = [:]
	var o = 0
	while o + 3 <= buf.count {
		let tag = buf[o]
		let lenBE = (UInt16(buf[o+1]) << 8) | UInt16(buf[o+2])
		let len = Int(lenBE)
		o += 3
		guard o + len <= buf.count else { throw KISRError.payloadInvalid }
		let v = buf.subdata(in: o..<(o+len))
		out[TLVTag(rawValue: tag) ?? .memo] = v
		o += len
	}
	return out
}

func txidHexToLE32(_ hex: String) -> Data {
	let b = Data(hexString: hex)
	precondition(b.count == 32, "txid must be 32 bytes")
	return Data(b.reversed())
}

func le32ToTxidHex(_ le: Data) -> String {
	precondition(le.count == 32, "le32 must be 32 bytes")
	return Data(le.reversed()).hexString
}

extension UInt32 {
	var le32: Data {
		var v = self.littleEndian
		return withUnsafeBytes(of: &v) { Data($0) }
	}
}

extension UInt64 {
	var le64: Data {
		var v = self.littleEndian
		return withUnsafeBytes(of: &v) { Data($0) }
	}
}

extension Data {
	init(hexString: String) {
		let s = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
		var data = Data(capacity: s.count / 2)
		var idx = s.startIndex
		while idx < s.endIndex {
			let next = s.index(idx, offsetBy: 2)
			let byteStr = s[idx..<next]
			let byte = UInt8(byteStr, radix: 16) ?? 0
			data.append(byte)
			idx = next
		}
		self = data
	}
	var hexString: String {
		self.map { String(format: "%02x", $0) }.joined()
	}
	func toUInt32LE() -> UInt32 {
		var value: UInt32 = 0
		let count = Swift.min(self.count, 4)
		for i in 0..<count { value |= UInt32(self[i]) << (8 * i) }
		return value
	}
	func toUInt64LE() -> UInt64 {
		var value: UInt64 = 0
		let count = Swift.min(self.count, 8)
		for i in 0..<count { value |= UInt64(self[i]) << (8 * i) }
		return value
	}
}

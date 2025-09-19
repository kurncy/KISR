// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
package org.kisr.sdk.internal

import org.kisr.sdk.KISRError
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal enum class TLVTag(val id: UByte) {
	Outpoint(0x01u),
	Presig(0x02u),
	Sighash(0x03u),
	InviterPubKey(0x04u),
	AmountSompi(0x05u),
	NetworkId(0x06u),
	Timestamp(0x07u),
	Memo(0x08u)
}

internal object EnvelopeConst {
	val prefix: ByteArray = "KISR-".toByteArray(Charsets.UTF_8)
	const val version: UByte = 0x01u
}

internal fun writeTLV(tag: TLVTag, value: ByteArray): ByteArray {
	val len = value.size
	require(len <= 0xFFFF) { "value too large" }
	val out = ByteArray(1 + 2 + len)
	out[0] = tag.id.toByte()
	out[1] = ((len ushr 8) and 0xFF).toByte()
	out[2] = (len and 0xFF).toByte()
	System.arraycopy(value, 0, out, 3, len)
	return out
}

internal fun readTLV(buf: ByteArray): Map<TLVTag, ByteArray> {
	val out = LinkedHashMap<TLVTag, ByteArray>()
	var o = 0
	while (o + 3 <= buf.size) {
		val tag = buf[o].toUByte()
		val len = ((buf[o + 1].toInt() and 0xFF) shl 8) or (buf[o + 2].toInt() and 0xFF)
		o += 3
		if (o + len > buf.size) throw KISRError.PayloadInvalid()
		val v = buf.copyOfRange(o, o + len)
		val t = TLVTag.values().firstOrNull { it.id == tag } ?: TLVTag.Memo
		out[t] = v
		o += len
	}
	return out
}

internal fun txidHexToLE32(hex: String): ByteArray {
	val b = hexStringToBytes(hex)
	require(b.size == 32) { "txid must be 32 bytes" }
	return b.reversedArray()
}

internal fun le32ToTxidHex(le: ByteArray): String {
	require(le.size == 32) { "le32 must be 32 bytes" }
	return bytesToHex(le.reversedArray())
}

internal fun UInt.toLe32(): ByteArray {
	val bb = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
	bb.putInt(this.toInt())
	return bb.array()
}

internal fun ULong.toLe64(): ByteArray {
	val bb = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
	bb.putLong(this.toLong())
	return bb.array()
}

internal fun ByteArray.toUInt32LE(): UInt {
	val bb = ByteBuffer.wrap(this.copyOfRange(0, 4)).order(ByteOrder.LITTLE_ENDIAN)
	return bb.int.toUInt()
}

internal fun ByteArray.toUInt64LE(): ULong {
	val bb = ByteBuffer.wrap(this.copyOfRange(0, 8)).order(ByteOrder.LITTLE_ENDIAN)
	return bb.long.toULong()
}

internal fun hexStringToBytes(input: String): ByteArray {
	val s = if (input.startsWith("0x", ignoreCase = true)) input.substring(2) else input
	val len = s.length
	val out = ByteArray(len / 2)
	var i = 0
	while (i < len) {
		out[i / 2] = ((s[i].digitToInt(16) shl 4) + s[i + 1].digitToInt(16)).toByte()
		i += 2
	}
	return out
}

internal fun bytesToHex(bytes: ByteArray): String = bytes.joinToString("") { b -> "%02x".format(b) }

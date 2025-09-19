// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
package org.kisr.sdk

object KISRDeeplink {
	fun build(code: String?, txid: String, inviterAddress: String? = null): String {
		val parts = mutableListOf<String>()
		if (!code.isNullOrEmpty()) parts += "code=$code"
		parts += "txid=$txid"
		val query = parts.joinToString("&")
		val path = if (!inviterAddress.isNullOrEmpty()) "$inviterAddress/redeem" else "redeem"
		return "kaspa:$path?$query"
	}

	fun parse(url: String): Pair<String, String?> {
		val lower = url.lowercase()
		if (!lower.startsWith("kaspa:")) throw KISRError.InvalidDeeplink()
		val after = url.substringAfter(":")
		val comps = after.split("?", limit = 2)
		val path = comps.getOrNull(0) ?: ""
		val query = comps.getOrNull(1) ?: ""
		if (!(path == "redeem" || path.endsWith("/redeem"))) throw KISRError.InvalidDeeplink()
		var code: String? = null
		var txid: String? = null
		if (query.isNotEmpty()) {
			for (pair in query.split("&")) {
				val kv = pair.split("=", limit = 2)
				val name = kv.getOrNull(0)?.lowercase() ?: ""
				val value = kv.getOrNull(1) ?: ""
				if (name == "code") code = value
				if (name == "txid") txid = value
			}
		}
		val t = txid ?: throw KISRError.InvalidDeeplink()
		return t to code
	}
}

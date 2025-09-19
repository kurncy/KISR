// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
package org.kisr.sdk

import org.kisr.sdk.KISRError
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

class KISRRemote(private val config: Config = Config()) {
	data class Config(
		val mainnetBase: String = "https://api.kaspa.org",
		val testnetBase: String = "https://api-tn10.kaspa.org"
	)

	private fun normalizeNetwork(network: String): String {
		val n = network.lowercase()
		return if (n == "testnet" || n == "testnet-10") "testnet-10" else "mainnet"
	}

	fun fetchPayload(txid: String, network: String = "mainnet", address: String? = null): String {
		val net = normalizeNetwork(address?.let { if (it.lowercase().startsWith("kaspatest:")) "testnet-10" else network } ?: network)
		val base = if (net == "testnet-10") config.testnetBase else config.mainnetBase
		val url = URL("$base/transactions/$txid?inputs=false&outputs=false&resolve_previous_outpoints=no")
		val conn = (url.openConnection() as HttpURLConnection).apply {
			requestMethod = "GET"
			setRequestProperty("Accept", "application/json")
			connectTimeout = 8000
			readTimeout = 8000
		}
		conn.inputStream.use { stream ->
			val text = BufferedReader(InputStreamReader(stream)).readText()
			val payloadHex = parsePayloadField(text) ?: throw KISRError.PayloadInvalid()
			return payloadHex
		}
	}

	private fun parsePayloadField(json: String): String? {
		// Minimal parser to avoid bringing gson; expects { "payload": "hex" }
		val key = "\"payload\""
		val idx = json.indexOf(key)
		if (idx < 0) return null
		val colon = json.indexOf(':', idx + key.length)
		if (colon < 0) return null
		var i = colon + 1
		while (i < json.length && json[i].isWhitespace()) i++
		if (i >= json.length || json[i] != '"') return null
		i++
		val start = i
		while (i < json.length && json[i] != '"') i++
		if (i >= json.length) return null
		return json.substring(start, i)
	}
}

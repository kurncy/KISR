package com.kurncy.data.service

import android.util.Log
import com.kurncy.data.model.NetworkType
import com.kurncy.data.rustyservice.RpcConnectionManager
import com.kurncy.data.rustyservice.RustyRpcService
import com.kurncy.data.rustyservice.RustyTxService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import kotlin.math.min

class KISRService private constructor() {
	companion object {
		val instance = KISRService()
		private const val TAG = "KISRService"
	}

	sealed class KisrError(message: String? = null) : Exception(message) {
		object NotConnected : KisrError()
		object EncryptionUnavailable : KisrError()
		object FeatureUnavailable : KisrError()
		class NetworkError(val reason: String) : KisrError(reason)
		class DecodeError(val reason: String) : KisrError(reason)
		object InvalidEnvelope : KisrError()
		class FfiError(val reason: String) : KisrError(reason)
		object InsufficientFunds : KisrError()
		class UtxoNotFound(val details: String) : KisrError(details)
	}

	data class CreateUtxoToSelfResult(
		val txid: String,
		val index: Int,
		val amountSompi: Long,
		val address: String,
	)

	data class DecryptedPayload(
		val txid: String,
		val index: Int,
		val amountSompi: Long,
		val memo: String? = null,
	)

	// MARK: - KISR code utilities

	private val kisrAlphabet: CharArray = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".toCharArray()
	private val kisrPrefix: String = "KISR-"

	fun normalizeNetwork(network: String): String {
		return if (network.equals("testnet-10", ignoreCase = true) || network.lowercase().contains("testnet")) "testnet-10" else "mainnet"
	}

	fun generateKisrCode(): String {
		val rnd = SecureRandom()
		val bytes = ByteArray(8)
		rnd.nextBytes(bytes)
		val sb = StringBuilder(kisrPrefix.length + 8)
		sb.append(kisrPrefix)
		for (b in bytes) {
			val idx = (b.toInt() and 0xFF) % kisrAlphabet.size
			sb.append(kisrAlphabet[idx])
		}
		return sb.toString()
	}

	fun normalizeKisrCode(input: String): String? {
		val trimmed = input.trim().uppercase()
		if (trimmed.isEmpty()) return null
		val body = when {
			trimmed.startsWith(kisrPrefix) -> trimmed.drop(kisrPrefix.length)
			trimmed.startsWith("KISR") -> trimmed.drop(4).trimStart('-', ':', ' ')
			else -> trimmed
		}
		val filtered = buildString(body.length) {
			for (c in body) if (c.isLetterOrDigit()) append(c)
		}
		if (filtered.length != 8) return null
		for (c in filtered) if (!kisrAlphabet.contains(c)) return null
		return kisrPrefix + filtered
	}

	fun validateKisrCode(code: String): Boolean {
		val norm = normalizeKisrCode(code) ?: return false
		return norm.length == (kisrPrefix.length + 8) && norm.startsWith(kisrPrefix)
	}

	// MARK: - Public API

	suspend fun createUtxoToSelf(
		network: String,
		selfAddress: String,
		amountSompi: Long,
		feeRateSompiPerMass: Int,
		privateKeyHex: String,
	): CreateUtxoToSelfResult = withContext(Dispatchers.IO) {
		val net = normalizeNetwork(network)
		val isTestnet = isTestnetNetwork(net)
		Log.d(TAG, "createUtxoToSelf: start network=$network normalized=$net isTestnet=$isTestnet address=$selfAddress amountSompi=$amountSompi feeRate=$feeRateSompiPerMass")
		val handle = ensureConnectedAndGetHandle(net)
		Log.d(TAG, "createUtxoToSelf: rpcHandle=$handle")

		val utxos = parseUtxoArray(getUtxosJson(handle, selfAddress))
		Log.d(TAG, "createUtxoToSelf: utxosFetched count=${utxos.size} totalSompi=${utxos.sumOf { it.amount }}")
		if (utxos.isEmpty()) throw KisrError.InsufficientFunds

		val selection = selectUtxosForAmount(
			utxos = utxos,
			targetAmountSompi = amountSompi,
			feeRateSompiPerKilomass = feeRateSompiPerMass,
			isTestnet = isTestnet,
			toAddress = selfAddress,
			payloadHex = null,
		)
		val selectedUtxos = selection.selected
		Log.d(TAG, "createUtxoToSelf: selectionDone selectedCount=${selectedUtxos.size} selectedTotalSompi=${selectedUtxos.sumOf { it.amount }} minFeeSompi=${selection.feeEstimation.minFee}")
		for (u in selectedUtxos) {
			Log.d(TAG, "createUtxoToSelf: selectedUtxo ${u.txid}:${u.index} amount=${u.amount}")
		}

		val gen = RustyTxService.instance.txGeneratorNew(isTestnet)
		try {
			check(gen >= 0) { "FFI: txGeneratorNew failed" }
			Log.d(TAG, "createUtxoToSelf: txGeneratorNew id=$gen")
			check(RustyTxService.instance.txGeneratorSetChangeAddress(gen, selfAddress) == 0) { "FFI: set_change_address failed" }
			Log.d(TAG, "createUtxoToSelf: setChangeAddress $selfAddress")
			check(RustyTxService.instance.txGeneratorSetFeeRate(gen, feeRateSompiPerMass) == 0) { "FFI: set_fee_rate failed" }
			Log.d(TAG, "createUtxoToSelf: setFeeRate $feeRateSompiPerMass")
			for (u in selectedUtxos) {
				val utxo = KaspaFfi.UTXO(u.txid, u.index, u.amount, u.scriptHex)
				check(RustyTxService.instance.txGeneratorAddUtxo(gen, utxo) == 0) { "FFI: add_utxo failed" }
				Log.d(TAG, "createUtxoToSelf: addUtxo ${u.txid}:${u.index} amount=${u.amount}")
			}
			check(RustyTxService.instance.txGeneratorAddOutput(gen, KaspaFfi.Output(selfAddress, amountSompi)) == 0) { "FFI: add_output failed" }
			Log.d(TAG, "createUtxoToSelf: addOutput to=$selfAddress amount=$amountSompi")
			val safeJson = RustyTxService.instance.txGeneratorBuildAndSignSafejson(gen, privateKeyHex)
			Log.d(TAG, "createUtxoToSelf: buildAndSignSafejson length=${safeJson.length}")
			// Broadcast
			val txid = RustyRpcService.instance.submitSafeJson(handle, safeJson, net)
			Log.i(TAG, "createUtxoToSelf: broadcasted txid=$txid")
			CreateUtxoToSelfResult(txid = txid, index = 0, amountSompi = amountSompi, address = selfAddress)
		} catch (e: Exception) {
			Log.e(TAG, "createUtxoToSelf failed", e)
			when (e) {
				is KisrError -> throw e
				else -> throw KisrError.FfiError(e.message ?: "ffi_error")
			}
		} finally {
			RustyTxService.instance.txGeneratorFree(gen)
			Log.d(TAG, "createUtxoToSelf: txGeneratorFree id=$gen")
		}
	}

	suspend fun preSignCreatedUtxo(
		privateKeyHex: String,
		network: String,
		txid: String,
		index: Int,
		amountSompi: Long,
		address: String,
	): Pair<String, String> = withContext(Dispatchers.IO) {
		val net = normalizeNetwork(network)
		val isTestnet = isTestnetNetwork(net)
		Log.d(TAG, "preSignCreatedUtxo: start network=$network normalized=$net isTestnet=$isTestnet address=$address txid=$txid index=$index amountSompi=$amountSompi")
		val handle = ensureConnectedAndGetHandle(net)
		Log.d(TAG, "preSignCreatedUtxo: rpcHandle=$handle")

		val parsed = retryFindUtxo(handle, address, txid, index, amountSompi)
		Log.d(TAG, "preSignCreatedUtxo: parsedUtxo ${parsed.txid}:${parsed.index} amount=${parsed.amount} scriptLen=${parsed.scriptHex.length}")

		val gen = KaspaFfi.txGeneratorNew(isTestnet)
		try {
			check(gen >= 0) { "FFI: txGeneratorNew failed" }
			Log.d(TAG, "preSignCreatedUtxo: txGeneratorNew id=$gen")
			val utxo = KaspaFfi.UTXO(parsed.txid, parsed.index, parsed.amount, parsed.scriptHex)
			check(KaspaFfi.txGeneratorAddUtxo(gen, utxo.txidBeHex, utxo.index, utxo.amount, utxo.scriptPubKeyHex) == 0) { "FFI: add_utxo failed" }
			Log.d(TAG, "preSignCreatedUtxo: addUtxo ${utxo.txidBeHex}:${utxo.index} amount=${utxo.amount} scriptLen=${utxo.scriptPubKeyHex.length}")
			// Build+sign with SIGHASH_NONE | ANYONECANPAY (0x82)
			val signedSafeJson = KaspaFfi.txGeneratorBuildAndSignSafejsonWithTypeAndAlgo(gen, privateKeyHex, 0x82.toByte(), 0)
			Log.d(TAG, "preSignCreatedUtxo: signedSafeJson length=${signedSafeJson.length}")
			val signatureScript = extractSignatureScript(signedSafeJson)
				?: throw KisrError.DecodeError("Could not extract signatureScript")
			Log.d(TAG, "preSignCreatedUtxo: signatureScript length=${signatureScript.length} preview=${signatureScript.take(24)}...")
			// Sighash omitted in iOS implementation
			Pair(signatureScript, "")
		} catch (e: Exception) {
			Log.e(TAG, "preSignCreatedUtxo failed", e)
			when (e) {
				is KisrError -> throw e
				else -> throw KisrError.FfiError(e.message ?: "ffi_error")
			}
		} finally {
			KaspaFfi.txGeneratorFree(gen)
			Log.d(TAG, "preSignCreatedUtxo: txGeneratorFree id=$gen")
		}
	}

	suspend fun buildKisEncryptedPayload(
		code: String,
		network: String,
		utxoTxid: String,
		utxoIndex: Int,
		presigHex: String,
		amountSompi: Long,
		inviterPubKeyHex: String?,
		memo: String?,
	): String = withContext(Dispatchers.Default) {
		KaspaPayloadService.instance.buildKisEncryptedPayload(
			code = code,
			network = network,
			utxoTxid = utxoTxid,
			utxoIndex = utxoIndex,
			presigHex = presigHex,
			amountSompi = amountSompi,
			inviterPubKeyHex = inviterPubKeyHex,
			memo = memo
		)
	}

	suspend fun decryptKisPayload(
		code: String,
		envelopeHex: String,
	): DecryptedPayload = withContext(Dispatchers.Default) {
		KaspaPayloadService.instance.decryptKisPayload(code, envelopeHex).first
	}

	data class TransactionPayloadResult(
		val payloadHex: String,
		val outputs: List<com.kurncy.data.api.models.TransactionOutput>?
	)

	suspend fun fetchTransactionPayloadHex(
		network: String = "mainnet",
		txid: String,
		address: String? = null,
		includeOutputs: Boolean = false,
	): TransactionPayloadResult = withContext(Dispatchers.IO) {
		val net = address?.let { inferNetworkFromAddress(it) } ?: normalizeNetwork(network)
		val networkType = if (isTestnetNetwork(net)) NetworkType.Testnet10 else NetworkType.Mainnet
		val base = URLService.getInstance().getKaspaAPIURL(networkType)
		val url = URL("$base/transactions/$txid")
		val conn = (url.openConnection() as HttpURLConnection).apply {
			requestMethod = "GET"
			setRequestProperty("accept", "application/json")
			connectTimeout = 30000
			readTimeout = 30000
		}
		try {
			when (conn.responseCode) {
				in 200..299 -> {
					val body = conn.inputStream.bufferedReader().use { it.readText() }
					val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }
					val tx = json.decodeFromString(com.kurncy.data.api.models.KaspaTransactionResponse.serializer(), body)
					TransactionPayloadResult(payloadHex = tx.payload ?: "", outputs = if (includeOutputs) tx.outputs else null)
				}
				else -> {
					val err = conn.errorStream?.bufferedReader()?.use { it.readText() }
					throw KisrError.NetworkError("HTTP ${conn.responseCode}: ${err ?: ""}")
				}
			}
		} finally {
			conn.disconnect()
		}
	}

	suspend fun assembleAndBroadcastRedemptionPresigned(
		network: String = "mainnet",
		toAddress: String,
		decrypted: DecryptedPayload,
		feeSompi: Long,
		fromAddress: String,
		presigHex: String,
	): String = withContext(Dispatchers.IO) {
		val net = normalizeNetwork(network)
		val isTestnet = isTestnetNetwork(net)
		val handle = ensureConnectedAndGetHandle(net)

		val input = retryFindUtxo(handle, fromAddress, decrypted.txid, decrypted.index, decrypted.amountSompi)
		if (input.amount <= feeSompi) throw KisrError.InsufficientFunds
		val value = input.amount - feeSompi

		val gen = KaspaFfi.txGeneratorNew(isTestnet)
		try {
			check(gen >= 0) { "FFI: txGeneratorNew failed" }
			check(KaspaFfi.txGeneratorSetChangeAddress(gen, fromAddress) == 0) { "FFI: set_change_address failed" }
			check(KaspaFfi.txGeneratorSetFeeRate(gen, 0) == 0) { "FFI: set_fee_rate failed" }
			check(KaspaFfi.txGeneratorAddUtxo(gen, input.txid, input.index, input.amount, input.scriptHex) == 0) { "FFI: add_utxo failed" }
			check(KaspaFfi.txGeneratorAddOutput(gen, toAddress, value) == 0) { "FFI: add_output failed" }
			val unsignedSafeJson = KaspaFfi.txGeneratorBuildUnsignedSafejson(gen)
			val safeJsonWithSig = KaspaFfi.safejsonSetInputSignatureScript(unsignedSafeJson, 0, presigHex)
			val txid = RustyRpcService.instance.submitSafeJson(handle, safeJsonWithSig, net)
			txid
		} catch (e: Exception) {
			when (e) {
				is KisrError -> throw e
				else -> throw KisrError.FfiError(e.message ?: "ffi_error")
			}
		} finally {
			KaspaFfi.txGeneratorFree(gen)
		}
	}

	suspend fun createAnchorToSelfWithPayload(
		privateKeyHex: String,
		network: String = "mainnet",
		feeSompi: Long = 0,
		payloadHex: String? = null,
		payloadText: String? = null,
		excludeOutpoint: Pair<String, Int>? = null,
	): String = withContext(Dispatchers.IO) {
		val net = normalizeNetwork(network)
		val isTestnet = isTestnetNetwork(net)
		Log.d(TAG, "createAnchorToSelfWithPayload: start network=$network normalized=$net isTestnet=$isTestnet payloadHexProvided=${!payloadHex.isNullOrBlank()} payloadTextProvided=${!payloadText.isNullOrBlank()} excludeOutpoint=${excludeOutpoint?.first}:${excludeOutpoint?.second} feeSompi=$feeSompi")
		val handle = ensureConnectedAndGetHandle(net)
		Log.d(TAG, "createAnchorToSelfWithPayload: rpcHandle=$handle")

		val selfAddress = addressFromPrivateKeyHex(privateKeyHex, isTestnet)
		Log.d(TAG, "createAnchorToSelfWithPayload: selfAddress=$selfAddress")
		val finalPayloadHex = when {
			!payloadHex.isNullOrBlank() -> payloadHex
			!payloadText.isNullOrBlank() -> payloadText.encodeToByteArray().joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
			else -> null
		}
		val payloadBytes = finalPayloadHex?.length?.div(2) ?: 0
		Log.d(TAG, "createAnchorToSelfWithPayload: payloadPrepared type=${when { !payloadHex.isNullOrBlank() -> "hex"; !payloadText.isNullOrBlank() -> "text"; else -> "none" }} bytes=$payloadBytes preview=${finalPayloadHex?.take(32)?.let { "$it..." } ?: "none"}")
		val anchorValue = 500_000_000L // 5 KAS
		val utxos = parseUtxoArray(getUtxosJson(handle, selfAddress))
		Log.d(TAG, "createAnchorToSelfWithPayload: utxosFetched count=${utxos.size} totalSompi=${utxos.sumOf { it.amount }}")
		val filteredUtxos = excludeOutpoint?.let { (tx, ix) -> utxos.filterNot { it.txid == tx && it.index == ix } } ?: utxos
		Log.d(TAG, "createAnchorToSelfWithPayload: utxosFiltered count=${filteredUtxos.size} excluded=${excludeOutpoint != null}")
		if (filteredUtxos.isEmpty()) throw KisrError.InsufficientFunds

		val feeRateSompiPerKilomass = 1000
		Log.d(TAG, "createAnchorToSelfWithPayload: estimating selection with feeRate=$feeRateSompiPerKilomass and payloadBytes=$payloadBytes")
		val selection = selectUtxosForAmount(
			utxos = filteredUtxos,
			targetAmountSompi = anchorValue,
			feeRateSompiPerKilomass = feeRateSompiPerKilomass,
			isTestnet = isTestnet,
			toAddress = selfAddress,
			payloadHex = finalPayloadHex,
		)
		val selectedUtxos = selection.selected
		Log.d(TAG, "createAnchorToSelfWithPayload: selectionDone selectedCount=${selectedUtxos.size} selectedTotalSompi=${selectedUtxos.sumOf { it.amount }} minFeeSompi=${selection.feeEstimation.minFee}")
		for (u in selectedUtxos) {
			Log.d(TAG, "createAnchorToSelfWithPayload: selectedUtxo ${u.txid}:${u.index} amount=${u.amount}")
		}

		val gen = KaspaFfi.txGeneratorNew(isTestnet)
		try {
			check(gen >= 0) { "FFI: txGeneratorNew failed" }
			Log.d(TAG, "createAnchorToSelfWithPayload: txGeneratorNew id=$gen")
			check(KaspaFfi.txGeneratorSetChangeAddress(gen, selfAddress) == 0) { "FFI: set_change_address failed" }
			Log.d(TAG, "createAnchorToSelfWithPayload: setChangeAddress $selfAddress")
			check(KaspaFfi.txGeneratorSetFeeRate(gen, feeRateSompiPerKilomass) == 0) { "FFI: set_fee_rate failed" }
			Log.d(TAG, "createAnchorToSelfWithPayload: setFeeRate $feeRateSompiPerKilomass")
			if (!finalPayloadHex.isNullOrEmpty()) {
				KaspaFfi.txGeneratorSetPayloadHex(gen, finalPayloadHex)
				Log.d(TAG, "createAnchorToSelfWithPayload: setPayloadHex bytes=$payloadBytes")
			}
			for (u in selectedUtxos) {
				check(KaspaFfi.txGeneratorAddUtxo(gen, u.txid, u.index, u.amount, u.scriptHex) == 0) { "FFI: add_utxo failed" }
				Log.d(TAG, "createAnchorToSelfWithPayload: addUtxo ${u.txid}:${u.index} amount=${u.amount}")
			}
			check(KaspaFfi.txGeneratorAddOutput(gen, selfAddress, anchorValue) == 0) { "FFI: add_output failed" }
			Log.d(TAG, "createAnchorToSelfWithPayload: addOutput to=$selfAddress amount=$anchorValue")
			val safeJson = KaspaFfi.txGeneratorBuildAndSignSafejson(gen, privateKeyHex)
			Log.d(TAG, "createAnchorToSelfWithPayload: buildAndSignSafejson length=${safeJson.length}")
			val txid = RustyRpcService.instance.submitSafeJson(handle, safeJson, net)
			Log.i(TAG, "createAnchorToSelfWithPayload: broadcasted txid=$txid")
			txid
		} catch (e: Exception) {
			Log.e(TAG, "createAnchorToSelfWithPayload failed", e)
			when (e) {
				is KisrError -> throw e
				else -> throw KisrError.FfiError(e.message ?: "ffi_error")
			}
		} finally {
			KaspaFfi.txGeneratorFree(gen)
			Log.d(TAG, "createAnchorToSelfWithPayload: txGeneratorFree id=$gen")
		}
	}

	// MARK: - Internals

	private suspend fun ensureConnectedAndGetHandle(network: String): Int {
		val nt = if (isTestnetNetwork(network)) NetworkType.Testnet10 else NetworkType.Mainnet
		return RpcConnectionManager.awaitHandle(nt, timeoutMs = 12_000L)
	}

	private fun isTestnetNetwork(network: String): Boolean = network.contains("testnet")

	private data class ParsedUtxo(
		val txid: String,
		val index: Int,
		val amount: Long,
		val scriptHex: String,
	)

	private suspend fun getUtxosJson(handle: Int, address: String): String {
		return RustyRpcService.instance.getUtxos(handle, address)
	}

	private fun parseUtxoArray(json: String): List<ParsedUtxo> {
		if (json.isBlank()) return emptyList()
		val result = mutableListOf<ParsedUtxo>()
		try {
			val root: JsonElement = Json.parseToJsonElement(json)
			val arr: List<JsonObject> = when (root) {
				is JsonArray -> root.mapNotNull { it as? JsonObject }
				is JsonObject -> {
					root["entries"]?.let { e -> (e as? JsonArray)?.mapNotNull { it as? JsonObject } } ?: emptyList()
				}
				else -> emptyList()
			}
			for (o in arr) {
				var txid: String? = null
				var indexVal: Int? = null
				if (o["outpoint"] is JsonObject) {
					val op = o["outpoint"]!!.jsonObject
					txid = op["transactionId"]?.jsonPrimitive?.content
						?: op["transaction_id"]?.jsonPrimitive?.content
					indexVal = op["index"]?.jsonPrimitive?.content?.toIntOrNull()
				}
				if (txid == null) txid = o["transactionId"]?.jsonPrimitive?.content
				var amount: Long? = null
				amount = o["amount"]?.jsonPrimitive?.content?.toLongOrNull()
				if (amount == null && o["utxoEntry"] is JsonObject) {
					amount = o["utxoEntry"]!!.jsonObject["amount"]?.jsonPrimitive?.content?.toLongOrNull()
				}
				if (amount == null && o["entry"] is JsonObject) {
					amount = o["entry"]!!.jsonObject["amount"]?.jsonPrimitive?.content?.toLongOrNull()
				}
				fun extractScriptHex(obj: JsonObject?, key: String): String? {
					obj ?: return null
					val v = obj[key]
					if (v is JsonObject) {
						val s = v["script"]?.jsonPrimitive?.content
							?: v["scriptPublicKey"]?.jsonPrimitive?.content
						return s
					}
					return v?.jsonPrimitive?.content
				}
				var scriptHex: String? = null
				scriptHex = (o["utxoEntry"] as? JsonObject)?.let { extractScriptHex(it, "scriptPublicKey") }
				if (scriptHex == null) scriptHex = (o["entry"] as? JsonObject)?.let { extractScriptHex(it, "scriptPublicKey") }
				if (scriptHex == null) scriptHex = extractScriptHex(o, "scriptPublicKey")
				scriptHex = scriptHex?.let { if (it.startsWith("0000")) it.drop(4) else it }
				if (!txid.isNullOrBlank() && indexVal != null && amount != null && !scriptHex.isNullOrBlank()) {
					result.add(ParsedUtxo(txid!!, indexVal!!, amount!!, scriptHex!!))
				}
			}
		} catch (_: Exception) { }
		return result
	}

	private suspend fun retryFindUtxo(handle: Int, address: String, txid: String, index: Int, amountSompi: Long): ParsedUtxo {
		val maxRetries = 10
		for (attempt in 1..maxRetries) {
			val utxos = parseUtxoArray(getUtxosJson(handle, address))
			utxos.firstOrNull { it.txid == txid && it.index == index }?.let { return it }
			val sameTx = utxos.filter { it.txid == txid }
			if (sameTx.size == 1) return sameTx.first()
			if (sameTx.size > 1) sameTx.firstOrNull { it.amount == amountSompi }?.let { return it }
			if (attempt < maxRetries) delay(1_000)
		}
		throw KisrError.UtxoNotFound("$txid:$index @ $address")
	}

	private fun extractSignatureScript(safeJson: String): String? {
		return try {
			val root = Json.parseToJsonElement(safeJson) as? JsonObject ?: return null
			val inputs = root["inputs"] as? JsonArray ?: return null
			if (inputs.isEmpty()) return null
			val first = inputs[0] as? JsonObject ?: return null
			first["signature_script"]?.jsonPrimitive?.content
				?: first["signatureScript"]?.jsonPrimitive?.content
				?: first["script"]?.jsonPrimitive?.content
		} catch (_: Exception) { null }
	}

	private fun addressFromPrivateKeyHex(privateKeyHex: String, isTestnet: Boolean): String {
		val clean = privateKeyHex.trim().lowercase().removePrefix("0x")
		require(clean.length == 64) { "Private key must be 32 bytes hex" }
		val bytes = ByteArray(32) { 0 }
		var i = 0
		while (i < clean.length) {
			bytes[i / 2] = ((Character.digit(clean[i], 16) shl 4) or Character.digit(clean[i + 1], 16)).toByte()
			i += 2
		}
		return KaspaFfi.addressFromPrivateKey(bytes, isTestnet).address
	}

	private data class SelectionResult(val selected: List<ParsedUtxo>, val feeEstimation: KaspaFfi.FeeEstimation)

	private fun selectUtxosForAmount(
		utxos: List<ParsedUtxo>,
		targetAmountSompi: Long,
		feeRateSompiPerKilomass: Int,
		isTestnet: Boolean,
		toAddress: String,
		payloadHex: String?,
	): SelectionResult {
		val sorted = utxos.sortedBy { it.amount }
		val chosen = ArrayList<ParsedUtxo>()
		var lastEstimation: KaspaFfi.FeeEstimation = KaspaFfi.FeeEstimation(0, 0, 0, 0, 0)
		for (u in sorted) {
			chosen.add(u)
			// Use generator-based estimation with explicit change address to avoid missing-change errors
			val gen = KaspaFfi.txGeneratorNew(isTestnet)
			try {
				check(gen >= 0) { "FFI: txGeneratorNew failed" }
				check(KaspaFfi.txGeneratorSetChangeAddress(gen, toAddress) == 0) { "FFI: set_change_address failed" }
				check(KaspaFfi.txGeneratorSetFeeRate(gen, feeRateSompiPerKilomass) == 0) { "FFI: set_fee_rate failed" }
				if (!payloadHex.isNullOrBlank()) {
					KaspaFfi.txGeneratorSetPayloadHex(gen, payloadHex)
				}
				for (c in chosen) {
					check(KaspaFfi.txGeneratorAddUtxo(gen, c.txid, c.index, c.amount, c.scriptHex) == 0) { "FFI: add_utxo failed" }
				}
				check(KaspaFfi.txGeneratorAddOutput(gen, toAddress, targetAmountSompi) == 0) { "FFI: add_output failed" }
				lastEstimation = KaspaFfi.txGeneratorEstimateJson(gen)
			} finally {
				KaspaFfi.txGeneratorFree(gen)
			}
			val required = targetAmountSompi + lastEstimation.minFee
			val totalSelected = chosen.sumOf { it.amount }
			if (totalSelected >= required) {
				return SelectionResult(chosen.toList(), lastEstimation)
			}
		}
		throw KisrError.InsufficientFunds
	}

	private fun inferNetworkFromAddress(address: String): String? {
		return when {
			address.lowercase().startsWith("kaspatest:") -> "testnet-10"
			address.lowercase().startsWith("kaspa:") -> "mainnet"
			else -> null
		}
	}

	// KISR payload crypto moved to KaspaPayloadService
}

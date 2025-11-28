import Foundation
import KaspaFFI
import Security


final class KISRService {
    static let shared = KISRService()
    private init() {}

    enum KISRError: Error, LocalizedError {
        case notConnected
        case encryptionUnavailable
        case featureUnavailable
        case networkError(String)
        case decodeError(String)
        case invalidEnvelope
        case ffiError(String)
        case insufficientFunds
        case utxoNotFound(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "rpc_error_not_connected".localized
            case .encryptionUnavailable:
                return "kisr_error_encryption_unavailable".localized
            case .featureUnavailable:
                return "kisr_error_feature_unavailable".localized
            case .networkError(let m):
                return m
            case .decodeError(let m):
                return m
            case .invalidEnvelope:
                return "kisr_error_invalid_envelope".localized
            case .ffiError(let m):
                return m
            case .insufficientFunds:
                return "Insufficient funds".localized
            case .utxoNotFound(let d):
                return String(format: "kisr_error_utxo_not_found".localized, d)
            }
        }
    }

    struct CreateUtxoToSelfResult {
        let txid: String
        let index: UInt32
        let amountSompi: UInt64
        let address: String
    }

    typealias DecryptedPayload = KaspaPayloadService.DecryptedPayload


    static func normalizeNetwork(_ network: String) -> String {
        if network == "testnet-10" || network.lowercased().contains("testnet") { return "testnet-10" }
        return "mainnet"
    }

    // MARK: KISR Code (generate/validate/normalize) — parity with API/SDK
    private static let kisrPrefix = "KISR-"
    private static let kisrAlphabet: [Character] = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Generate a KISR code using the standard alphabet and prefix `KISR-`.
    static func generateKisrCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        let chars: [Character] = bytes.map { b in
            let idx = Int(b) % kisrAlphabet.count
            return kisrAlphabet[idx]
        }
        return kisrPrefix + String(chars)
    }

    /// Validate a candidate code strictly: must be `KISR-` + 8 chars from the allowed alphabet.
    static func validateKisrCode(_ code: String) -> Bool {
        guard let normalized = normalizeKisrCode(code) else { return false }
        return normalized.count == 5 + 8 && normalized.hasPrefix(kisrPrefix)
    }

    /// Normalize user input to canonical `KISR-XXXXXXXX` if possible. Returns nil if invalid.
    /// Accepts inputs like `kisr-xxxx....`, `kisrxxxxxxxx`, or just `xxxxxxxx`.
    static func normalizeKisrCode(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return nil }

        // Extract body of 8 characters, allowing optional prefix and separator variations
        let body: String
        if trimmed.hasPrefix(kisrPrefix) {
            body = String(trimmed.dropFirst(kisrPrefix.count))
        } else if trimmed.hasPrefix("KISR") {
            body = String(trimmed.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: "-: "))
        } else {
            body = trimmed
        }

        // Remove non-alphanumeric separators in case they appear between characters
        let filtered = body.filter { $0.isLetter || $0.isNumber }
        guard filtered.count == 8 else { return nil }

        // Check alphabet membership (excludes I, O, 0, 1)
        for c in filtered {
            if !kisrAlphabet.contains(c) { return nil }
        }
        return kisrPrefix + filtered
    }

    func createUtxoToSelf(network: String,
                          selfAddress: String,
                          amountSompi: UInt64,
                          feeRateSompiPerMass: Int64,
                          privateKeyHex: String) async throws -> CreateUtxoToSelfResult {
        let net = Self.normalizeNetwork(network)
        _ = try await ensureConnectedAndGetHandle(network: net)
        let submit = try await KaspaTransactionService.shared.buildSignAndSubmit(
            network: net,
            fromAddress: selfAddress,
            toAddress: selfAddress,
            amountSompi: amountSompi,
            feeRateSompiPerMass: feeRateSompiPerMass,
            privateKeyHex: privateKeyHex,
            changeAddress: selfAddress,
            selectionMode: .minimal
        )
        return CreateUtxoToSelfResult(txid: submit.txid, index: 0, amountSompi: amountSompi, address: selfAddress)
    }

    func preSignCreatedUtxo(privateKeyHex: String,
                            network: String,
                            txid: String,
                            index: UInt32,
                            amountSompi: UInt64,
                            address: String) async throws -> (signatureHex: String, sighash: String) {
        let net = Self.normalizeNetwork(network)
        let isTestnet = Self.isTestnetNetwork(net)
        let handle = try await ensureConnectedAndGetHandle(network: net)

        let u: ParsedUtxo = try await {
            let maxRetries = 10
            for attempt in 1...maxRetries {
                let utxosJson = try await getUtxosJson(handle: handle, address: address)
                let utxos = Self.parseUtxoArray(from: utxosJson)
                if let direct = utxos.first(where: { $0.txid == txid && $0.index == index }) {
                    return direct
                }
                let sameTx = utxos.filter { $0.txid == txid }
                if sameTx.count == 1, let single = sameTx.first {
                    return single
                }
                if sameTx.count > 1, let byAmount = sameTx.first(where: { $0.amount == amountSompi }) {
                    return byAmount
                }
                if attempt < maxRetries {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            throw KISRError.utxoNotFound("\(txid):\(index) @ \(address)")
        }()

        let signedJSONString: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let gen = kaspa_tx_generator_new(isTestnet)
                guard gen >= 0 else {
                    let msg = Self.kaspaFFIError() ?? "FFI: tx_generator_new failed"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }
                defer { _ = kaspa_tx_generator_free(gen) }

                // Add the single specified UTXO
                let entry = KaspaUtxoEntry(txid_be_hex: nil, index: u.index, amount: u.amount, script_pub_key_hex: nil)
                let rcAdd: Int32 = u.txid.withCString { cTxid in
                    u.scriptHex.withCString { cSpk in
                        var e = entry
                        e.txid_be_hex = cTxid
                        e.script_pub_key_hex = cSpk
                        return withUnsafePointer(to: &e) { kaspa_tx_generator_add_utxo(gen, $0) }
                    }
                }
                if rcAdd != 0 {
                    let msg = (Self.kaspaFFIError() ?? "FFI: add_utxo failed") + " (code=\(rcAdd))"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }

                var signedJSONString: String?
                privateKeyHex.withCString { cPriv in
                    if let c = kaspa_tx_generator_build_and_sign_safejson_with_type_and_algo(gen, cPriv, 0x82, 0) {
                        let s = String(cString: c)
                        kaspa_string_free(c)
                        signedJSONString = s
                    }
                }
                if let safeJson = signedJSONString {
                    continuation.resume(returning: safeJson)
                } else {
                    let msg = Self.kaspaFFIError() ?? "FFI: tx_generator_build_and_sign_safejson_with_type_and_algo returned null"
                    continuation.resume(throwing: KISRError.ffiError(msg))
                }
            }
        }

        guard let signatureScriptHex = Self.extractSignatureScript(from: signedJSONString), !signatureScriptHex.isEmpty else {
            throw KISRError.decodeError("FFI: could not extract signatureScript from SafeJSON".localized)
        }

        let sighashHex = ""

        return (signatureHex: signatureScriptHex, sighash: sighashHex)
    }

    func buildKisEncryptedPayload(code: String,
                                  network: String,
                                  utxoTxid: String,
                                  utxoIndex: UInt32,
                                  presigHex: String,
                                  amountSompi: UInt64,
                                  inviterPubKeyHex: String?,
                                  memo: String?) async throws -> String /* envelopeHex */ {
        return try await KaspaPayloadService.shared.buildKisEncryptedPayload(code: code,
                                                                             network: network,
                                                                             utxoTxid: utxoTxid,
                                                                             utxoIndex: utxoIndex,
                                                                             presigHex: presigHex,
                                                                             amountSompi: amountSompi,
                                                                             inviterPubKeyHex: inviterPubKeyHex,
                                                                             memo: memo)
    }

    func decryptKisPayload(code: String, envelopeHex: String) async throws -> DecryptedPayload {
        return try await KaspaPayloadService.shared.decryptKisPayload(code: code, envelopeHex: envelopeHex)
    }

    func fetchTransactionPayloadHex(network: String = "mainnet",
                                    txid: String,
                                    address: String? = nil,
                                    includeOutputs: Bool = false) async throws -> (payloadHex: String, outputs: [Any]?) {
        let netInput = (address.flatMap { Self.inferNetwork(fromAddress: $0) } ?? network)
        let net = Self.normalizeNetwork(netInput)
        do {
            let result = try await KaspaService.shared.getTransactionPayloadHex(txid: txid,
                                                                               address: address,
                                                                               includeOutputs: includeOutputs,
                                                                               network: net)
            return result
        } catch let e as KaspaServiceError {
            switch e {
            case .invalidResponse:
                throw KISRError.decodeError("Invalid JSON".localized)
            case .networkError(let underlying):
                throw KISRError.networkError(underlying.localizedDescription)
            default:
                throw KISRError.networkError(e.localizedDescription)
            }
        } catch {
            throw KISRError.networkError(error.localizedDescription)
        }
    }

 


    func assembleAndBroadcastRedemptionPresigned(network: String = "mainnet",
                                                 toAddress: String,
                                                 decrypted: DecryptedPayload,
                                                 feeSompi: UInt64,
                                                 fromAddress: String,
                                                 presigHex: String) async throws -> String /* txid */ {
        let net = Self.normalizeNetwork(network)
        let handle = try await ensureConnectedAndGetHandle(network: net)

        let input: ParsedUtxo = try await {
            let maxRetries = 10
            for attempt in 1...maxRetries {
                let utxosJson = try await getUtxosJson(handle: handle, address: fromAddress)
                let utxos = Self.parseUtxoArray(from: utxosJson)
                if let found = utxos.first(where: { $0.txid == decrypted.txid && $0.index == decrypted.index }) ?? {
                    let sameTx = utxos.filter { $0.txid == decrypted.txid }
                    if sameTx.count == 1 { return sameTx.first }
                    if sameTx.count > 1 {
                        if let amt = UInt64(exactly: decrypted.amountSompi) {
                            return sameTx.first(where: { $0.amount == amt })
                        }
                    }
                    return nil
                }() {
                    return found
                }
                if attempt < maxRetries {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            throw KISRError.utxoNotFound("\(decrypted.txid):\(decrypted.index) @ \(fromAddress)")
        }()

        let isTestnet = Self.isTestnetNetwork(net)
        let baselineRate: Int64 = 1000
        let estimatedMinFee: UInt64 = {
            let txidCStr = Array(input.txid.utf8CString)
            let spkCStr = Array(input.scriptHex.utf8CString)
            let addrCStr = Array(toAddress.utf8CString)
            var minFee: UInt64 = feeSompi
            let estPtr: UnsafeMutablePointer<CChar>? = txidCStr.withUnsafeBufferPointer { txBuf in
                spkCStr.withUnsafeBufferPointer { spkBuf in
                    var utxo = KaspaUtxoEntry(txid_be_hex: txBuf.baseAddress, index: input.index, amount: input.amount, script_pub_key_hex: spkBuf.baseAddress)
                    return withUnsafePointer(to: &utxo) { utxoPtr in
                        addrCStr.withUnsafeBufferPointer { addrBuf in
                            var out = KaspaOutputEntry(address: addrBuf.baseAddress, amount: input.amount)
                            return withUnsafePointer(to: &out) { outPtr in
                                kaspa_estimate_fee_from_entries(utxoPtr, 1, outPtr, 1, isTestnet, baselineRate, nil)
                            }
                        }
                    }
                }
            }
            if let estPtr {
                let s = String(cString: estPtr)
                kaspa_string_free(estPtr)
                let parsed = KaspaTransactionService.parseEstimate(json: s)
                minFee = max(minFee, parsed.minFee)
            }
            return minFee
        }()

        let appliedFee = max(feeSompi, estimatedMinFee)
        guard input.amount > appliedFee else { throw KISRError.insufficientFunds }
        let value = input.amount &- appliedFee

        let unsignedSafeJson: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let gen = kaspa_tx_generator_new(isTestnet)
                guard gen >= 0 else {
                    let msg = Self.kaspaFFIError() ?? "FFI: tx_generator_new failed"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }
                defer { _ = kaspa_tx_generator_free(gen) }

                let rcChange: Int32 = fromAddress.withCString { kaspa_tx_generator_set_change_address(gen, $0) }
                if rcChange != 0 {
                    let msg = (Self.kaspaFFIError() ?? "FFI: set_change_address failed") + " (code=\(rcChange))"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }
                let rcFee = kaspa_tx_generator_set_fee_rate(gen, 0)
                if rcFee != 0 {
                    let msg = (Self.kaspaFFIError() ?? "FFI: set_fee_rate failed") + " (code=\(rcFee))"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }

                let entry = KaspaUtxoEntry(txid_be_hex: nil, index: input.index, amount: input.amount, script_pub_key_hex: nil)
                let rcAdd: Int32 = input.txid.withCString { cTxid in
                    input.scriptHex.withCString { cSpk in
                        var e = entry
                        e.txid_be_hex = cTxid
                        e.script_pub_key_hex = cSpk
                        return withUnsafePointer(to: &e) { kaspa_tx_generator_add_utxo(gen, $0) }
                    }
                }
                if rcAdd != 0 {
                    let msg = (Self.kaspaFFIError() ?? "FFI: add_utxo failed") + " (code=\(rcAdd))"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }

                let rcOut: Int32 = toAddress.withCString { cAddr in
                    var out = KaspaOutputEntry(address: cAddr, amount: value)
                    return withUnsafePointer(to: &out) { kaspa_tx_generator_add_output(gen, $0) }
                }
                if rcOut != 0 {
                    let msg = (Self.kaspaFFIError() ?? "FFI: add_output failed") + " (code=\(rcOut))"
                    return continuation.resume(throwing: KISRError.ffiError(msg))
                }

                if let u = kaspa_tx_generator_build_unsigned_safejson(gen) {
                    let s = String(cString: u)
                    kaspa_string_free(u)
                    continuation.resume(returning: s)
                } else {
                    let msg = Self.kaspaFFIError() ?? "FFI: build_unsigned_safejson returned null"
                    continuation.resume(throwing: KISRError.ffiError(msg))
                }
            }
        }

        let safeJson = try Self.replaceSignatureScript(in: unsignedSafeJson, with: presigHex)

        let txid: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                safeJson.withCString { cJson in
                    net.withCString { cNet in
                        if let c = kaspa_rpc_submit_safe_json(handle, cJson, cNet) {
                            let s = String(cString: c)
                            kaspa_string_free(c)
                            continuation.resume(returning: s)
                        } else {
                            let raw = Self.kaspaFFIError()
                            let msg = (raw ?? "Broadcast SafeJSON failed (FFI returned null)".localized) + " (net=\(net))"
                            continuation.resume(throwing: KISRError.ffiError(msg))
                        }
                    }
                }
            }
        }
        return txid
    }

    func createAnchorToSelfWithPayload(privateKeyHex: String,
                                       network: String = "mainnet",
                                       feeSompi: UInt64 = 0,
                                       payloadHex: String? = nil,
                                       payloadText: String? = nil,
                                       excludeOutpoint: (transactionId: String, index: UInt32)? = nil) async throws -> String /* txid */ {
        let net = Self.normalizeNetwork(network)
        let isTestnet = Self.isTestnetNetwork(net)
        let _ = try await ensureConnectedAndGetHandle(network: net)

        let selfAddress = try KaspaKeyDerivationService.shared.addressFromPrivateKeyHex(privateKeyHex, isTestnet: isTestnet)
        let payloadStr: String = {
            if let hex = payloadHex, !hex.isEmpty { return hex }
            if let text = payloadText { return Data(text.utf8).map { String(format: "%02x", $0) }.joined() }
            return ""
        }()

        let anchorValue: UInt64 = 500_000_000
        let finalAmount = anchorValue

        let submit = try await KaspaTransactionService.shared.buildSignAndSubmit(
            network: net,
            fromAddress: selfAddress,
            toAddress: selfAddress,
            amountSompi: finalAmount,
            feeRateSompiPerMass: 1000,
            privateKeyHex: privateKeyHex,
            changeAddress: selfAddress,
            selectionMode: .minimal,
            sighashType: 0x01,
            signatureAlgorithm: .schnorr,
            payloadHex: payloadStr.isEmpty ? nil : payloadStr,
            excludeOutpoint: excludeOutpoint
        )
        return submit.txid
    }

    private func ensureConnectedAndGetHandle(network: String) async throws -> Int32 {
        return try await MainActor.run {
            let svc = KaspaRPCService.shared
            if !svc.hasConnection(for: network) {
                let ok = svc.ensureConnection(for: network, useBorsh: true)
                if !ok { throw KISRError.notConnected }
            }
            let handle = svc.currentHandle(for: network)
            guard handle >= 0 else { throw KISRError.notConnected }
            return handle
        }
    }

    private static func isTestnetNetwork(_ network: String) -> Bool {
        return network.contains("testnet")
    }

    private struct ParsedUtxo: Hashable, Sendable {
        let txid: String
        let index: UInt32
        let amount: UInt64
        let scriptHex: String
    }

    private func getUtxosJson(handle: Int32, address: String) async throws -> String {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if let c = kaspa_rpc_get_utxos(handle, address) {
                    let s = String(cString: c)
                    kaspa_string_free(c)
                    continuation.resume(returning: s)
                } else {
                    let msg = Self.kaspaFFIError() ?? "rpc_error_ffi_null".localized
                    continuation.resume(throwing: KISRError.ffiError(msg))
                }
            }
        }
    }

    private static func parseUtxoArray(from json: String) -> [ParsedUtxo] {
        guard let data = json.data(using: .utf8) else { return [] }
        var results: [ParsedUtxo] = []
        if let any = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for obj in any {
                var txid: String? = nil
                var indexVal: UInt32? = nil
                if let outpoint = obj["outpoint"] as? [String: Any] {
                    if let s = outpoint["transactionId"] as? String { txid = s } else if let s = outpoint["transaction_id"] as? String { txid = s }
                    if let n = outpoint["index"] as? NSNumber { indexVal = n.uint32Value } else if let s = outpoint["index"] as? String, let n = UInt32(s) { indexVal = n }
                }
                if txid == nil, let s = obj["transactionId"] as? String { txid = s }
                var amount: UInt64? = nil
                if let n = obj["amount"] as? NSNumber { amount = n.uint64Value }
                else if let s = obj["amount"] as? String, let n = UInt64(s) { amount = n }
                if amount == nil, let utxoEntry = obj["utxoEntry"] as? [String: Any] {
                    if let n = utxoEntry["amount"] as? NSNumber { amount = n.uint64Value }
                    else if let s = utxoEntry["amount"] as? String, let n = UInt64(s) { amount = n }
                }
                if amount == nil, let entry = obj["entry"] as? [String: Any] {
                    if let n = entry["amount"] as? NSNumber { amount = n.uint64Value }
                    else if let s = entry["amount"] as? String, let n = UInt64(s) { amount = n }
                }
                func extractScriptHex(_ spk: Any?) -> String? {
                    if let s = spk as? String { return s.hasPrefix("0000") ? String(s.dropFirst(4)) : s }
                    if let d = spk as? [String: Any] { if let s = d["script"] as? String { return s }; if let s = d["scriptPublicKey"] as? String { return s } }
                    return nil
                }
                var scriptHex: String? = nil
                if let utxoEntry = obj["utxoEntry"] as? [String: Any] { scriptHex = extractScriptHex(utxoEntry["scriptPublicKey"]) }
                if scriptHex == nil, let entry = obj["entry"] as? [String: Any] { scriptHex = extractScriptHex(entry["scriptPublicKey"]) }
                if scriptHex == nil { scriptHex = extractScriptHex(obj["scriptPublicKey"]) }
                if let txid = txid, let index = indexVal, let amount = amount, let spk = scriptHex, !txid.isEmpty, !spk.isEmpty {
                    results.append(ParsedUtxo(txid: txid, index: index, amount: amount, scriptHex: spk))
                }
            }
        }
        return results
    }

    private static func inferNetwork(fromAddress address: String) -> String? {
        if address.lowercased().hasPrefix("kaspatest:") { return "testnet-10" }
        if address.lowercased().hasPrefix("kaspa:") { return "mainnet" }
        return nil
    }


    @inline(__always)
    private static func kaspaFFIError() -> String? {
        guard let err = kaspa_last_error_message() else { return nil }
        let s = String(cString: err)
        kaspa_string_free(err)
        return s
    }

    private static func extractSignatureScript(from safeJson: String) -> String? {
        guard let data = safeJson.data(using: .utf8) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let inputs = root["inputs"] as? [[String: Any]], let first = inputs.first else { return nil }
        if let sig = first["signatureScript"] as? String { return sig }
        return nil
    }

    private static func replaceSignatureScript(in safeJson: String, with presigHex: String) throws -> String {
        guard let data = safeJson.data(using: .utf8) else { throw KISRError.decodeError("Invalid SafeJSON".localized) }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KISRError.decodeError("Invalid SafeJSON root".localized)
        }
        guard var inputs = root["inputs"] as? [[String: Any]], !inputs.isEmpty else {
            throw KISRError.decodeError("SafeJSON.inputs missing".localized)
        }
        var first = inputs[0]
        first["signatureScript"] = presigHex
        inputs[0] = first
        root["inputs"] = inputs
        let outData = try JSONSerialization.data(withJSONObject: root, options: [])
        guard let outStr = String(data: outData, encoding: .utf8) else {
            throw KISRError.decodeError("Failed to serialize SafeJSON".localized)
        }
        return outStr
    }
}


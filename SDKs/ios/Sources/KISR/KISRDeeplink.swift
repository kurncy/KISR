// ============================================================================
// KISR Modules (Multi-wallet support)
// ----------------------------------------------------------------------------
// This file is part of the KISR standard. Make sure to implement the exact encryption and code generations.
// ============================================================================
//
//
import Foundation

public enum KISRDeeplink {
	public static func build(code: String?, txid: String) -> URL? {
		return build(code: code, txid: txid, inviterAddress: nil)
	}
	
	public static func build(code: String?, txid: String, inviterAddress: String?) -> URL? {
		var parts: [String] = []
		if let code, !code.isEmpty { parts.append("code=\(code)") }
		parts.append("txid=\(txid)")
		let query = parts.joined(separator: "&")
		let path = (inviterAddress?.isEmpty == false) ? "\(inviterAddress!)/redeem" : "redeem"
		let uri = "kaspa:\(path)?\(query)"
		return URL(string: uri)
	}

	public static func parse(_ url: URL) throws -> (txid: String, code: String?) {
		guard url.scheme?.lowercased() == "kaspa" else { throw KISRError.invalidDeeplink }
		let raw = url.absoluteString
		guard let range = raw.range(of: ":") else { throw KISRError.invalidDeeplink }
		let afterScheme = raw[range.upperBound...]
		let comps = afterScheme.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
		let pathPart = String(comps.first ?? "")
		let queryPart = comps.count > 1 ? String(comps[1]) : ""
		// Accept either "redeem" or "<address>/redeem"
		if !(pathPart == "redeem" || pathPart.hasSuffix("/redeem")) { throw KISRError.invalidDeeplink }
		var code: String? = nil
		var txid: String? = nil
		if !queryPart.isEmpty {
			for pair in queryPart.split(separator: "&") {
				let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
				let name = kv.count > 0 ? String(kv[0]).lowercased() : ""
				let value = kv.count > 1 ? String(kv[1]) : ""
				if name == "code" { code = value }
				if name == "txid" { txid = value }
			}
		}
		guard let t = txid, !t.isEmpty else { throw KISRError.invalidDeeplink }
		return (txid: t, code: code)
	}
}

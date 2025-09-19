// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//
import Foundation

public final class KISRRemote {
	public struct Config {
		public let baseURL: URL
		public init(baseURL: URL) { self.baseURL = baseURL }
	}

	private let config: Config
	private let urlSession: URLSession

	public init(config: Config, session: URLSession = .shared) {
		self.config = config
		self.urlSession = session
	}

	// MARK: - Native Kaspa API fetch (payload only)
	private func normalizeNetwork(_ network: String) -> String {
		let n = network.lowercased()
		if n == "testnet" || n == "testnet-10" { return "testnet-10" }
		return "mainnet"
	}
	private func inferNetwork(from address: String?) -> String {
		guard let address else { return "mainnet" }
		if address.lowercased().hasPrefix("kaspatest:") { return "testnet-10" }
		return "mainnet"
	}
	private struct KaspaTxResponse: Decodable {
		let payload: String?
	}

	public func fetchPayload(txid: String, network: String = "mainnet", address: String? = nil) async throws -> String {
		let netInput = address != nil ? inferNetwork(from: address) : network
		let net = normalizeNetwork(netInput)
		let base = (net == "testnet-10") ? "https://api-tn10.kaspa.org" : "https://api.kaspa.org"
		var comps = URLComponents(string: base + "/transactions/" + txid)!
		comps.queryItems = [
			URLQueryItem(name: "inputs", value: "false"),
			URLQueryItem(name: "outputs", value: "false"),
			URLQueryItem(name: "resolve_previous_outpoints", value: "no")
		]
		guard let url = comps.url else { throw KISRError.payloadInvalid }
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.timeoutInterval = 8.0
		let (data, response) = try await urlSession.data(for: request)
		guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw KISRError.payloadInvalid }
		let decoded = try JSONDecoder().decode(KaspaTxResponse.self, from: data)
		guard let payloadHex = decoded.payload, !payloadHex.isEmpty else { throw KISRError.payloadInvalid }
		return payloadHex
	}
}

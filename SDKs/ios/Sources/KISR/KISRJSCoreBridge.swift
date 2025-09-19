// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//
import Foundation
import JavaScriptCore

@objc protocol KISRJSHostExports: JSExport {
	func fetchJson(_ url: String, _ callback: JSValue)
	func submitRawTxHex(_ hex: String, _ network: String, _ callback: JSValue)
}

@objc class KISRJSHost: NSObject, KISRJSHostExports {
	func fetchJson(_ url: String, _ callback: JSValue) {
		guard let u = URL(string: url) else { callback.call(withArguments: [NSNull()]) ; return }
		var req = URLRequest(url: u)
		req.httpMethod = "GET"
		req.setValue("application/json", forHTTPHeaderField: "Accept")
		URLSession.shared.dataTask(with: req) { data, resp, err in
			if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) {
				callback.call(withArguments: [obj])
			} else {
				callback.call(withArguments: [NSNull()])
			}
		}.resume()
	}

	func submitRawTxHex(_ hex: String, _ network: String, _ callback: JSValue) {
		DispatchQueue.global().async {
			guard let kaspa = KISRWasm.kaspa else { callback.call(withArguments: [NSNull()]); return }
			let id = try? kaspa.submitRawTransaction(rawTx: Data(hexString: hex), network: network)
			callback.call(withArguments: [id ?? NSNull()])
		}
	}
}

final class KISRJSCoreBridge {
	private let context: JSContext

	init?() {
		guard let jsPath = Bundle.module.path(forResource: "kisr_core", ofType: "js", inDirectory: "JS"),
				let source = try? String(contentsOfFile: jsPath, encoding: .utf8) else { return nil }
		let ctx = JSContext()
		guard let ctx else { return nil }
		self.context = ctx

		// Error logging
		self.context.exceptionHandler = { _, exception in
			print("[KISRJS] Exception: \(exception?.toString() ?? "unknown")")
		}

		// Inject host bridges
		let host = KISRJSHost()
		self.context.setObject(host, forKeyedSubscript: "__host" as (NSCopying & NSObjectProtocol))
		let hostFetch: @convention(block) (String) -> JSValue = { url in
			let sem = DispatchSemaphore(value: 0)
			var result: Any = NSNull()
			let cb: @convention(block) (Any) -> Void = { obj in result = obj; sem.signal() }
			let callback = JSValue(object: cb, in: ctx)
			let hostObj = ctx.objectForKeyedSubscript("__host")
			hostObj?.invokeMethod("fetchJson", withArguments: [url, callback as Any])
			sem.wait()
			return JSValue(object: result, in: ctx)
		}
		self.context.setObject(hostFetch, forKeyedSubscript: "hostFetchJson" as (NSCopying & NSObjectProtocol))

		let hostSubmit: @convention(block) (String, String) -> JSValue = { hex, network in
			let sem = DispatchSemaphore(value: 0)
			var result: Any = NSNull()
			let cb: @convention(block) (Any?) -> Void = { obj in result = obj ?? NSNull(); sem.signal() }
			let callback = JSValue(object: cb, in: ctx)
			let hostObj = ctx.objectForKeyedSubscript("__host")
			hostObj?.invokeMethod("submitRawTxHex", withArguments: [hex, network, callback as Any])
			sem.wait()
			return JSValue(object: result, in: ctx)
		}
		self.context.setObject(hostSubmit, forKeyedSubscript: "hostSubmitRawTxHex" as (NSCopying & NSObjectProtocol))

		// Load core
		self.context.evaluateScript(source)
	}

	func setKaspaModule(_ module: Any) {
		self.context.setObject(module, forKeyedSubscript: "kaspa" as (NSCopying & NSObjectProtocol))
	}

	func callAsync(_ name: String, args: [Any]) throws -> Any? {
		guard let core = context.objectForKeyedSubscript("kisr").objectForKeyedSubscript("core") else { throw KISRError.payloadInvalid }
		guard let fn = core.objectForKeyedSubscript(name) else { throw KISRError.payloadInvalid }
		let promise = fn.call(withArguments: args)
		guard let then = promise?.objectForKeyedSubscript("then") else { throw KISRError.payloadInvalid }
		let sem = DispatchSemaphore(value: 0)
		var out: Any? = nil
		let onResolve: @convention(block) (Any?) -> Void = { value in out = value; sem.signal() }
		let onReject: @convention(block) (Any?) -> Void = { _ in sem.signal() }
		then.call(withArguments: [onResolve, onReject])
		sem.wait()
		return out
	}
}

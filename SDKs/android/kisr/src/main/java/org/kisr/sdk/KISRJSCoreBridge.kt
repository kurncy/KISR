// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//
package org.kisr.sdk

import android.content.Context
import org.mozilla.javascript.Context as RhinoContext
import org.mozilla.javascript.Scriptable

class KISRJSCoreBridge(context: Context? = null) {
	private val rhino: RhinoContext = RhinoContext.enter()
	private val scope: Scriptable = rhino.initStandardObjects()

	init {
		val jsSource = try {
			context?.assets?.open("js/kisr_core.js")?.bufferedReader()?.use { it.readText() }
		} catch (_: Throwable) { null }
		jsSource?.let { rhino.evaluateString(scope, it, "kisr_core.js", 1, null) }
	}

	fun setKaspaModule(module: Any) {
		scope.put("kaspa", scope, module)
	}

	fun call(name: String, args: List<Any>): Any? {
		val core = scope.get("kisr", scope)
		val coreObj = if (core is Scriptable) core.get("core", core) else null
		val fn = if (coreObj is Scriptable) coreObj.get(name, coreObj) else null
		if (fn !is org.mozilla.javascript.Function) throw KISRError.PayloadInvalid()
		val jsArgs = args.map { it as Any }.toTypedArray()
		return fn.call(rhino, scope, coreObj as Scriptable, jsArgs)
	}
}

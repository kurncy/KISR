// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to use QR code generation
// ============================================================================
//
//
package org.kisr.sdk

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

@Composable
fun KISRQRCodeView(url: String, modifier: Modifier = Modifier) {
	val bmp = remember(url) { generateQrBitmap(url, 512) }
	Box(modifier = modifier.aspectRatio(1f)) {
		bmp?.let { Image(bitmap = it.asImageBitmap(), contentDescription = "KISR QR") }
	}
}

@Composable
fun KISRInviteQRView(code: String?, txid: String, inviterAddress: String? = null, modifier: Modifier = Modifier) {
	val url = remember(code, txid, inviterAddress) { KISRDeeplink.build(code, txid, inviterAddress) }
	KISRQRCodeView(url = url, modifier = modifier)
}

private fun generateQrBitmap(data: String, size: Int): Bitmap? {
	if (data.isEmpty()) return null
	val hints = mapOf(EncodeHintType.MARGIN to 0)
	val matrix = QRCodeWriter().encode(data, BarcodeFormat.QR_CODE, size, size, hints)
	val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
	for (y in 0 until size) {
		for (x in 0 until size) {
			bmp.setPixel(x, y, if (matrix.get(x, y)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
		}
	}
	return bmp
}

// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to use QR code generation
// ============================================================================
//
//
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

public struct KISRQRCodeView: View {
	private let dataString: String
	private let context = CIContext()
	private let filter = CIFilter.qrCodeGenerator()

	public init(url: URL) {
		self.dataString = url.absoluteString
	}

	public init(code: String?, txid: String, inviterAddress: String? = nil) {
		let url = KISRDeeplink.build(code: code, txid: txid, inviterAddress: inviterAddress)
		self.dataString = url?.absoluteString ?? ""
	}

	public var body: some View {
		GeometryReader { proxy in
			if let image = generateQRImage(from: dataString, size: proxy.size) {
				Image(uiImage: image)
					.interpolation(.none)
					.resizable()
					.scaledToFit()
			} else {
				Color.secondary.opacity(0.1)
			}
		}
	}

	private func generateQRImage(from string: String, size: CGSize) -> UIImage? {
		guard !string.isEmpty else { return nil }
		let data = Data(string.utf8)
		filter.setValue(data, forKey: "inputMessage")
		filter.setValue("M", forKey: "inputCorrectionLevel")
		guard let outputImage = filter.outputImage else { return nil }
		let scale = max(1, Int(min(size.width, size.height) / 32))
		let transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
		let scaledImage = outputImage.transformed(by: transform)
		if let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) {
			return UIImage(cgImage: cgImage)
		}
		return nil
	}
}

public struct KISRInviteQRView: View {
	private let link: KISRInvitationLink
	private let inviterAddress: String?

	public init(link: KISRInvitationLink, inviterAddress: String? = nil) {
		self.link = link
		self.inviterAddress = inviterAddress
	}

	public var body: some View {
		VStack(spacing: 12) {
			KISRQRCodeView(code: link.code, txid: link.txid, inviterAddress: inviterAddress)
				.aspectRatio(1, contentMode: .fit)
				.frame(minWidth: 180, minHeight: 180)
			if let url = KISRDeeplink.build(code: link.code, txid: link.txid, inviterAddress: inviterAddress) {
				Text(url.absoluteString)
					.font(.footnote)
					.foregroundColor(.secondary)
					.multilineTextAlignment(.center)
					.lineLimit(3)
					.textSelection(.enabled)
				HStack(spacing: 12) {
					Button(action: { UIPasteboard.general.string = url.absoluteString }) {
						Label("Copy", systemImage: "doc.on.doc")
					}
					ShareLink(item: url)
				}
			}
		}
	}
}

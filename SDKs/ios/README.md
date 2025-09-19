# KISR iOS SDK (Swift)

Native Swift implementation of the Kaspa Invitation Standard (KISR) per PRD. Provides APIs to create and redeem invitations with encrypted envelopes anchored on-chain.

- Spec: `@KISR/PRD.md`
- Deeplink: `kaspa:address/redeem?code=KISR-XXXXXXXX&txid=<hex>` (address optional)
- Envelope: `KISR-` prefix, version 0x01, Argon2id key derivation, XChaCha20-Poly1305-ietf AEAD

## Package

Add this repo folder `@KISR/ios` via Swift Package Manager. Product `KISR` exports the SDK.

Optional: add Swift Sodium if you want in-app crypto without your own adapter.
- Xcode > Package Dependencies > Add `https://github.com/jedisct1/swift-sodium.git` (from 0.10.0)
- Or provide Clibsodium via a bridging package.

## Quick start

```swift
import KISR

// Implement your wallet adapter (bridge to your SDK/WASM)
final class MyWalletAdapter: KISRWalletAdapter {
    func currentNetworkId() -> UInt8 { 0 } // 0 mainnet, 1 testnet
    func createSelfUtxo(amountSompi: UInt64) throws -> (txid: String, vout: UInt32, amountSompi: UInt64) { /* ... */ }
    func preSignInput(txid: String, vout: UInt32, sighashFlags: UInt8) throws -> Data { /* ... */ }
    func publishAnchorTransaction(payload: Data) throws -> String { /* ... */ }
    func assembleRedemption(toAddress: String, inputTxid: String, inputIndex: UInt32, inputAmountSompi: UInt64, presigHex: String, feeSompi: UInt64) throws -> Data { /* ... */ }
    func broadcastRedemption(rawTx: Data) throws -> String { /* ... */ }
}

// Bootstrap crypto (if using Sodium/Clibsodium adapters)
KISRBootstrap.useAvailableCrypto()

let sdk = KISR(wallet: MyWalletAdapter())

// Create an invite and get a deeplink URL
let inviteURL = try sdk.createInvite(params: .init(amountSompi: 100_000_000, memo: "Welcome"))

// Show a QR code for the deeplink URL
KISRQRCodeView(url: inviteURL)
    .frame(width: 220, height: 220)

// Redeem an invite
let txid = try sdk.redeemInvite(link: inviteURL, destinationKaspaAddress: "kaspa:...")
```

## Adapter responsibilities

Your `KISRWalletAdapter` acts as the integration bridge to your wallet SDK/WASM or native stack. It must:
- Create a self UTXO for the invite amount and return its outpoint `(txid, vout, amountSompi)`
- Pre-sign the outpoint input with Sighash None | ANYONECANPAY (0x82)
- Publish an anchor transaction carrying the encrypted KISR envelope in `payload`
- Assemble a redemption transaction to sweep the UTXO to the destination address
- Broadcast the raw redemption transaction

## Deeplink

Use `KISRDeeplink.build(code:txid:inviterAddress:)` and `KISRDeeplink.parse(_:)` for constructing/parsing URIs.
- Standard: `kaspa:address/redeem?code=KISR-XXXXXXXX&txid=<hex>`
- Also allowed (no address): `kaspa:redeem?code=KISR-XXXXXXXX&txid=<hex>`

`KISRDeeplink.parse(_:)` returns `(txid: String, code: String?)`.

## Kaspa API payload fetch helper

If you need to fetch a transaction payload directly from the Kaspa public API:

```swift
let remote = KISRRemote(config: .init(baseURL: URL(string: "https://api.kaspa.org")!))
let payloadHex = try await remote.fetchPayload(txid: "<txid>", network: "mainnet")
```

## Example files

The following files are examples to illustrate bridging and UI and are not required for production:
- `KISRJSCoreBridge.swift`: Example of bridging to a JS/WASM core
- `KISRWalletAdapterJS.swift`: Example adapter wired to the JS bridge
- `KISRQRCodeView.swift`: Simple QR code generator for deeplink URLs

## Security

- Key derivation: Argon2id (t=2, m=64 MiB, 32-byte output)
- Cipher: XChaCha20-Poly1305-ietf
- Code: `KISR-` + 8 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`


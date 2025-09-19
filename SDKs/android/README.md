# KISR Android SDK (Kotlin)

Native Kotlin implementation of the Kaspa Invitation Standard (KISR) per PRD. Provides APIs to create and redeem invitations with encrypted envelopes anchored on-chain.

- Spec: `@KISR/KISR.md`
- Deeplink: `kaspa:address/redeem?code=KISR-XXXXXXXX&txid=<hex>` (address optional)
- Envelope: `KISR-` prefix, version 0x01, Argon2id key derivation, XChaCha20-Poly1305-ietf AEAD

## Gradle setup

- Include this folder `@KISR/SDKs/android` as a Gradle project, and depend on the `:kisr` module from your app module.
- Optional crypto backend: LazySodium (libsodium). The SDK auto-bootstraps when available; otherwise set `KISRWasm.crypto` yourself.

## Quick start

```kotlin
import org.kisr.sdk.*

class MyWalletAdapter : KISRWalletAdapter {
    override fun currentNetworkId(): UByte = 0u // 0 mainnet, 1 testnet
    override fun createSelfUtxo(amountSompi: Long): Triple<String, UInt, Long> { /* ... */ TODO() }
    override fun preSignInput(txid: String, vout: UInt, sighashFlags: UByte): ByteArray { /* ... */ TODO() }
    override fun publishAnchorTransaction(payload: ByteArray): String { /* ... */ TODO() }
    override fun assembleRedemption(
        toAddress: String,
        inputTxid: String,
        inputIndex: UInt,
        inputAmountSompi: Long,
        presigHex: String,
        feeSompi: Long
    ): ByteArray { /* ... */ TODO() }
    override fun broadcastRedemption(rawTx: ByteArray): String { /* ... */ TODO() }
}

// Bootstrap crypto (if using LazySodium)
// KISRBootstrap.useAvailableCrypto() is called automatically by KISR() when crypto is null

val sdk = KISR(wallet = MyWalletAdapter())

// Create an invite and get a deeplink URL string
val inviteURL: String = sdk.createInvite(KISRCreateParams(amountSompi = 100_000_000, memo = "Welcome"))

// Redeem an invite
val txid: String = sdk.redeemInvite(link = inviteURL, destinationKaspaAddress = "kaspa:...")
```

## Adapter responsibilities

Your `KISRWalletAdapter` acts as the integration bridge to your wallet SDK/WASM or native stack. It must:
- Create a self UTXO for the invite amount and return its outpoint `(txid, vout, amountSompi)`
- Pre-sign the outpoint input with Sighash None | ANYONECANPAY (0x82)
- Publish an anchor transaction carrying the encrypted KISR envelope in `payload`
- Assemble a redemption transaction to sweep the UTXO to the destination address
- Broadcast the raw redemption transaction

## Deeplink

Use `KISRDeeplink.build(code, txid, inviterAddress?)` and `KISRDeeplink.parse(url)` for constructing/parsing URIs.
- Standard: `kaspa:address/redeem?code=KISR-XXXXXXXX&txid=<hex>`
- Also allowed (no address): `kaspa:redeem?code=KISR-XXXXXXXX&txid=<hex>`

`KISRDeeplink.parse(url)` returns `(txid, code?)`.

## Kaspa API payload fetch helper

If you need to fetch a transaction payload directly from the Kaspa public API:

```kotlin
val remote = KISRRemote()
val payloadHex = remote.fetchPayload(txid = "<txid>", network = "mainnet")
```

## Security

- Key derivation: Argon2id (t=2, m=64 MiB, 32-byte output)
- Cipher: XChaCha20-Poly1305-ietf
- Code: `KISR-` + 8 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`

// Do NOT use Gson. Prefer kotlinx.serialization or manual parsing.

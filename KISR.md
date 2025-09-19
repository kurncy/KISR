# Kaspa Invitation Standard for Redemption (KISR)

## 1. Overview
KISR defines a simple, secure, and interoperable invitation flow to transfer Kaspa to a new user who does not yet control a Kaspa wallet. Any Kaspa wallet (mobile, desktop, browser extension) can implement KISR to create invitations and redeem them in a maximum of two steps.

- Name: Kaspa Invitation Standard for Redemption
- Short name: KISR
- Scope: Open standard, cross-wallet compatible, chain-anchored, redeemable with a short invite code or QR
- Runtime: WASM (server or in-app), with native SDKs for iOS (Swift) and Android (Kotlin)
- Security: Strong authenticated encryption using libsodium (Argon2id + XChaCha20-Poly1305-ietf), pre-signed input with constrained sighash

### Why This Works — Decentralized, Permissionless, Safe
- Decentralized: All critical data is anchored on-chain; there are no centralized databases or accounts. Any RPC-compatible node can serve the data.
- Centralized-compatible: The same standard can be adopted by centralized entities. KISR is built to last and to be used by anyone—decentralized and centralized. In centralized deployments, the KISR Code can operate standalone for business flows where the TXID need not be exposed to the end user at redemption.
- Permissionless: Anyone can create and redeem invites without registering with a service; invites are regular Kaspa transactions plus an encrypted payload.
- No extra wallet required: Invites are created and canceled using the inviter’s existing wallet.
- Easy to cancel: Spending the referenced UTXO immediately invalidates the invite with normal on-chain rules; no coordination required.
- Safe by construction: Presignature with None | ANYONECANPAY constrains inputs, preventing input swapping attacks and allowing the redeemer to control outputs.
- Works offline for sharing: The shareable object `{ code, txid }` can be printed or sent via air-gapped QR; decryption is local to the wallet.
- Human-friendly codes: The KISR Code is a one-time-use, human-readable 8-character code designed for easy input and sharing.
- Example centralized usage: A custodian like Kraken or even Tangem could keep invite metadata in their systems and resolve the TXID internally when presented with a valid KISR Code, providing a seamless user flow while remaining interoperable with the open standard.
- One standard for both worlds: This approach is how KISR satisfies both decentralized and centralized use cases with a single, portable specification.

## 2. Goals
- Minimal steps: 2-step invitation, 2-step redemption
- Interoperable: Works across all Kaspa wallets and platforms
- Secure by default: Resistant to tampering, replay, and online interception
- Self-contained: No server trust or centralized database; no PII stored on-chain
- Shareable: Works with QR codes and deeplinks; usable in offline or constrained UX contexts
- (Optional) Centralized storage of invitations or user metadata

## 3. Non-Goals
- Custodial holding of funds
- Complex multi-party protocols beyond sender and redeemer

## 4. Key Concepts and Artifacts
- KISR Code: Human-readable 8-character code, prefixed as `KISR-XXXXXXXX` (alphabet excludes ambiguous chars: I, O, 0, 1). Used as password to decrypt payload.
- KISR UTXO (KISRUTXO): A dedicated self-transfer UTXO representing the invitation amount.
- KISR Signature (KISRSign): A pre-signature over the KISR UTXO input using Sighash None | ANYONECANPAY.
- KISR Anchor Tx (KISRTXID): A self-transaction anchoring the encrypted payload to the Kaspa DAG. The transaction payload contains the encrypted envelope.

## 5. User Flows
### 5.0 User Stories
- Alice (inviter): Wants to gift KAS to her friend Bob who does not have a wallet yet. Alice creates an invite in two taps, shares a `kaspa:` deeplink or QR containing `{ code, txid }`, and can cancel at any time by spending the dedicated UTXO back to herself.
- Bob (new user): Installs any compatible Kaspa wallet, scans the QR or opens the deeplink, confirms his destination address, and redeems the invite in one confirmation screen.
- Charlie (merchant/promoter): Prepares a batch of small invites to hand out at an event via printed QR cards. Invites are permissionless, do not require a server account, and no need to reclaim later if unused.
- Dana (support/ops): Audits outstanding invites by checking their referenced UTXOs on-chain, cancels stale ones by compounding UTXOs, without touching user private keys.

### 5.1 Detailed Sequence — Invitation
- Precondition: Inviter has spendable UTXOs and a synced node connection.
- Steps:
  1. Wallet constructs a single-output self-transfer to create the KISRUTXO for the chosen amount; broadcast and wait for DAG acceptance if required by policy.
  2. Wallet builds a presignature over the KISRUTXO input using Sighash None | ANYONECANPAY.
  3. Wallet generates `code = KISR-XXXXXXXX` (or accepts a user-provided seed) and derives a symmetric key via Argon2id.
  4. Wallet assembles TLV payload: outpoint, presignature, sighash flags, optional inviter pubkey, amount, network, timestamp, optional memo.
  5. Wallet encrypts payload using XChaCha20-Poly1305-ietf producing the envelope `KISR- | version | salt | nonce | ciphertext`.
  6. Wallet anchors the envelope by sending a self-transaction with the envelope in the payload field (excluding the KISRUTXO as an input to this anchor).
  7. Output to share: `{ code, txid }` where `txid` is the anchor transaction id.

### 5.2 Detailed Sequence — Redemption
- Precondition: Redeemer controls a destination address on the target network (mainnet `kaspa:` or testnet-10).
- Steps:
  1. Parse deeplink/QR to extract `{ code, txid }`.
  2. Fetch anchor transaction by `txid` via RPC; read the raw payload bytes.
  3. Verify envelope prefix/version; derive key from `code`; decrypt using salt/nonce as AAD; reject on auth failure.
  4. Parse TLV: obtain referenced outpoint, presignature, sighash flags, amount, network, and optional memo.
  5. Validate: network matches destination address network; KISRUTXO exists and is unspent; amounts are sane.
  6. Assemble redemption transaction: include exactly the referenced input with its presignature; add one output to the destination address for `amount - fee`.
  7. Estimate fee using network estimator; ensure fee < amount; adjust change/output if necessary per wallet policy.
  8. Broadcast redemption; return final transaction id; mark invite as redeemed once the UTXO is observed spent.

## 6. Technical Architecture
- Core examples implementation in NodeJS using Rusty-Kaspa WASM bindings (RpcClient, UTXO inspection, transaction building/signing, submission)
- Encryption implemented with libsodium-wrappers-sumo in JS; analogous modules expected in Swift (Sodium) and Kotlin (libsodium/jni)
- Clear separation:
  - WASM/Kaspa networking: platform-agnostic module
  - Encryption: platform-native modules that implement the same envelope format

## 7. Data Formats
### 7.1 Envelope
- Prefix: ASCII `KISR-` (5 bytes, cleartext)
- Version: 1 byte (0x01)
- Salt: 16 bytes
- Nonce: 24 bytes (XChaCha20-Poly1305-ietf)
- Ciphertext: AEAD output over the TLV payload
- AAD (additional authenticated data): `version || salt`

Key derivation: Argon2id with parameters
- Output length: 32 bytes
- Opslimit (t): 2
- Memory (m): 64 MiB
- Algorithm: ARGON2ID13

Cipher: XChaCha20-Poly1305-ietf (libsodium `crypto_aead_xchacha20poly1305_ietf_*`)

### 7.2 TLV payload
- 0x01: Outpoint (36 bytes, txid LE32 || index u32 LE)
- 0x02: Pre-signature bytes (hex-decoded)
- 0x03: Sighash flags (1 byte). Default 0x82 (None | ANYONECANPAY)
- 0x04: Inviter public key (optional, 33 bytes compressed)
- 0x05: Amount (u64 LE)
- 0x06: Network (1 byte) — 0: mainnet, 1: testnet-10
- 0x07: Timestamp (u64 LE seconds)
- 0x08: Memo (utf8)

### 7.3 Identifiers
- KISR Code: `KISR-` + 8 chars from alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
- KISRTXID: Standard Kaspa transaction id (hex)

## 8. Protocol Operations (Normative)
### 8.1 Create Invitation
- Input: Sender private key, desired amount, optional fee, optional memo
- Steps:
  1. Create UTXO to self for the amount (single dedicated output)
  2. Pre-sign this UTXO input with Sighash None | ANYONECANPAY
  3. Generate KISR code (or accept a user-provided 8-char seed)
  4. Build encrypted payload (section 7) with outpoint, pre-signature, network, amount, timestamp, memo
  5. Anchor payload by sending a self-transfer with the envelope in tx payload; exclude the dedicated UTXO as input for the anchor
  6. Output shareable object: `{ code, txid }`

### 8.2 Redeem Invitation
- Input: `{ code, txid }`, destination address
- Steps:
  1. Fetch anchor transaction by `txid` and read its payload
  2. Decrypt the payload using the code
  3. Locate the referenced UTXO on-chain; verify it is unspent and matches amount/network
  4. Assemble redemption tx using the pre-signed input, add a single output to the destination address (amount minus fees)
  5. Broadcast and return final transaction id

### 8.3 Cancel Invitation
- Input: Inviter’s wallet keys
- Steps:
  1. In the wallet, use Generator to Compound UTXOs to self, ensuring the KISRUTXO is included.
  2. Broadcast. The invite is now invalid since the referenced input is spent.

## 9. Validation and Error Handling
- Node connectivity: require RPC server info shows `isSynced` true
- UTXO discovery: retry with small backoff up to 10s total
- Fee calculation: use kaspa network fee estimator; reject if fee exceeds input
- Decryption: reject on prefix mismatch, version mismatch, or AAD/auth failure
- Network mismatch: must match address network
- Safety: never reveal private keys or decrypted payload in logs

## 10. Security Considerations
- Code space: 30-character alphabet over 8 chars → 30^8 ≈ 6.56e11 combos; Argon2id settings add significant cost to offline guessing.
- Pre-signature: Sighash None | ANYONECANPAY binds only to the provided input, preventing input replacement and allowing the redeemer to select outputs safely.
- Anchor privacy: Payload is opaque; only KISR prefix and small header are cleartext. No PII on-chain.
- Replay: On successful redemption, the UTXO becomes spent; replay attempts fail naturally.
- Memo: Treat as public. Wallets SHOULD warn users that memos are on-chain (encrypted but not confidential to the code holder if code is shared).

## 11. SDK Deliverables
- JS (Node/Browser with WASM): reference implementation provided in this repo under `@KISR/js`
- iOS (Swift): KISR module exposing `createInvite` and `redeemInvite`, with native Sodium for encryption and Kaspa networking via WASM or platform SDK
- Android (Kotlin): analogous to iOS; JNI-backed libsodium; Kaspa networking via WASM or platform SDK
- Deeplink/QR helpers for sharing and parsing `kaspa:` URIs

## 12. Deeplink and QR
- URI scheme: `kaspa:redeem?code=KISR-XXXXXXXX&txid=<hex>`
- Alternate format including inviter address (optional): `kaspa:<inviterAddress>/redeem?code=KISR-XXXXXXXX&txid=<hex>`
- Alternate format for QR payloads: JSON `{ "code": "KISR-XXXXXXXX", "txid": "..." }`
- Wallets SHOULD support both; URLs may be wrapped by apps per platform conventions

## 13. Open API (Optional)
For server-assisted wallets, provide an Express router with the following endpoints (no persistence):
- POST `/invite/create` → { code, anchor.txid, utxo, presig }
- POST `/invite/redeem` → { transactionId }
- POST `/generate-code` → { code }
- POST `/fetch-payload` → { payloadHex, outputs }
- POST `/decrypt-kis-payload` → { decrypted }
- POST `/assemble-and-broadcast-redemption` → { transactionId }

## 14. Telemetry and Analytics
- None required. Implementers MAY add opt-in anonymized metrics, never storing invite codes or raw payloads.

## 15. Licensing
- Open source; MIT license recommended.

## 16. Risks and Mitigations
- Weak user-chosen codes: default to random generation; UI SHOULD discourage predictable seeds
- API dependency: recommend multiple RPC endpoints and exponential backoff
- Platform parity: keep envelope and TLVs identical across JS/Swift/Kotlin

## 17. Acceptance Criteria
- Any wallet implementing this spec can:
  - Create a valid invitation in ≤2 steps
  - Redeem a valid invitation in ≤2 steps
  - Interoperate with other conforming wallets (cross-app invite→redeem)
  - Handle mainnet and testnet-10 consistently

## 18. Versioning
- Envelope version: 0x01
- This PRD: v1.0.0

## 19. Extensibility and Reuse (KRC-20 Tokens, KRC-721 NFTs)
- KISR is transport-agnostic for assets; wallets MAY extend the TLV with asset descriptors while keeping the envelope and security model unchanged.
- Suggested reserved TLV range for assets: `0x20–0x2F`.
  - 0x20: Asset type (0 = KAS, 20 = KRC-20, 21 = KRC-721)
  - 0x21: Asset/contract identifier (utf8 or binary as per asset standard)
  - 0x22: Token amount (for fungible assets; u256 or decimal string)
  - 0x23: Metadata hash / token id (for NFTs)
- Redemption semantics for assets MUST follow the underlying asset protocol on Kaspa (e.g., KRC-20/KRC-721) and MAY involve additional validation or output formats.
- Reuse examples:
  - Seeding a newcomer with a small KRC-20 balance together with KAS for fees in a single invite.
  - Delivering a KRC-721 NFT to a new user by pre-authorizing the transfer and anchoring the encrypted claim.

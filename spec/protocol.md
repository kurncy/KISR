# KISR Protocol Specification (Normative)

## 1. Terminology
- MUST, SHOULD, MAY are as defined in RFC 2119.
- Wallet: an application capable of holding keys and interacting with the Kaspa network.
- Sender: the wallet creating an invitation.
- Redeemer: the wallet redeeming an invitation.

## 2. Envelope Structure
The encrypted payload MUST be embedded in the transaction payload field of the anchor transaction, and MUST conform to the following structure:

- Cleartext prefix: `KISR-` (5 bytes, ASCII)
- Version: 1 byte (0x01)
- Salt: 16 bytes (random)
- Nonce: 24 bytes (random, XChaCha20-Poly1305-ietf)
- Ciphertext: result of AEAD encryption over the TLV buffer
- AAD: `version || salt`

## 3. Key Derivation and Encryption
- Password: the exact KISR Code string used by the Sender (case-sensitive per implementation; this reference uses the canonical uppercase form)
- KDF: Argon2id, parameters:
  - Output length: 32 bytes
  - Opslimit (t): 2
  - Memory (m): 64 MiB
  - Algorithm: ARGON2ID13
- AEAD: XChaCha20-Poly1305-ietf

Implementations MUST use secure random sources for salt and nonce and MUST NOT reuse nonce with the same key.

## 4. TLV Payload
The plaintext is a concatenation of Tag-Length-Value (TLV) items. Tags are single-byte identifiers.

- 0x01 Outpoint (REQUIRED): 36 bytes
  - Format: `txid_le32 (32 bytes) || index_le32 (4 bytes)`
- 0x02 Pre-signature (REQUIRED): variable length (implementation-defined serialization of signature script for Sighash None | ANYONECANPAY)
- 0x03 Sighash flags (REQUIRED): 1 byte, default 0x82
- 0x04 Inviter PubKey (OPTIONAL): 33 bytes (compressed)
- 0x05 Amount (REQUIRED): 8 bytes, u64 little-endian (sompi)
- 0x06 Network (REQUIRED): 1 byte (0 = mainnet, 1 = testnet-10)
- 0x07 Timestamp (REQUIRED): 8 bytes, u64 LE (seconds since Unix epoch)
- 0x08 Memo (OPTIONAL): UTF-8 text

Unknown tags MUST be ignored by parsers but preserved is not required.

## 5. Invitation Creation
- The Sender MUST create a dedicated UTXO (self-output) for the invitation amount.
  Example: https://explorer.kaspa.org/txs/b1682dd4b211409c27f3de6f4865212b8d0eacc6f2da79d17a8ae529d4329fbf
- The Sender MUST pre-sign the input referencing this UTXO using Sighash None | ANYONECANPAY.
- The Sender MUST include the outpoint, pre-signature, amount, network, and timestamp in the TLV.
- The Sender MUST anchor the envelope by submitting a self-transaction carrying the ciphertext in the payload. - Make sure to exclude the dedicated UTXO
  Example: https://explorer.kaspa.org/txs/96022b49acfdfffb6f7e49bb8b1884a70aa8e52e379322299c5043bab8bd297a
- The output artifact MUST include both `code` and `txid` to be shareable.
  Example: KISR-HNVFFKC8

## 6. Cancellation
- A Sender MAY cancel any outstanding invitation by spending the referenced KISRUTXO back to self.
- Simplest path: use Generator to Compound UTXOs to self ensuring the KISRUTXO is included; broadcast.
- Once the UTXO is spent, the pre-signed input becomes invalid and redemption will fail naturally.

## 7. Redemption
- The Redeemer MUST fetch the anchor transaction by `txid` and read the payload.
- The Redeemer MUST validate the envelope prefix and version before attempting decryption.
- The Redeemer MUST derive the key from the user-provided KISR code and decrypt the TLV.
- The Redeemer MUST locate and validate the referenced UTXO (amount, unspent, correct network).
- The Redeemer MUST construct a transaction that uses the pre-signed input and adds an output to the redeemer’s address for `amount - fee`.
- The fee policy is implementation-defined; it MUST ensure the transaction is valid and acceptable by the network.
- Centralized mode (optional): Implementations MAY accept code-only input and resolve `txid` server-side, provided the flow remains interoperable when both `code` and `txid` are supplied.

## 8. KISR Code Format
- The canonical KISR Code is `KISR-` followed by 8 characters from the alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
- Wallets MAY accept lowercase and normalize to the canonical uppercase form.
- Wallets SHOULD prefer auto-generated random codes to user-entered seeds.

## 9. Network Identification
- Network byte (0 mainnet, 1 testnet-10) MUST match the address network used by the redeemer.
- Implementations MAY infer network from address prefixes `kaspa:` (mainnet) and `kaspatest:` (testnet-10).

## 10. Security Requirements
- Implementations MUST use secure randomness for salts and nonces.
- Implementations MUST never log raw pre-signatures, decrypted TLVs, private keys, or derived keys.

## 11. Versioning and Extensibility
- Envelope Version: 0x01 (this document)
- New tags MAY be introduced. Unknown tags MUST NOT cause failure unless their presence is REQUIRED by a higher-level policy.
- Asset extensibility: Reserved TLV range `0x20–0x2F` for assets (e.g., KRC-20/KRC-721). Implementations MAY define:
  - 0x20 Asset type (0 = KAS, 20 = KRC-20, 21 = KRC-721)
  - 0x21 Asset/contract identifier
  - 0x22 Token amount (fungible)
  - 0x23 Metadata hash / token id (NFT)

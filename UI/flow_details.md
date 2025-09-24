# KISR Invite/Redeem — Flow Details (UI + Copy)

This document specifies the end‑to‑end user flow for creating and redeeming a KISR invitation. It aligns with `@KISR/spec/protocol.md` and the UI reference images in this folder.

- Actors: Sender (invites), Redeemer (redeems)
- Network: Mainnet (`kaspa:`) and `testnet-10` (`kaspatest:`) must be respected
- Artifact: A shareable pair consisting of a `KISR code` and an `anchor txid`

## Screens (reference images)

- Invite entry: `Invite.jpg`
- Invite QR/share: `QR_invite_share.jpg`
- Redeem (scan): `Redeem_scanning.jpg`
- Redeem (code entered): `Redeem_scanned.jpg`
- Redeem success: `Redeemed.jpg`

## Primary Flows

### 1) Invite Flow (Sender)

1. Open “Invite a friend”
   - Amount input in fiat (left) with live KAS conversion (right)
   - Optional memo (up to 40 chars)
   - Primary action: Continue
2. Generate invitation
   - Wallet creates a dedicated UTXO and anchors the encrypted envelope per spec
   - Output artifact: `{ code: "KISR-XXXXXXXX", txid: "<hex>" }`
3. Show “Your invite QR”
   - QR encodes a KISR URI (see URI Format below)
   - Display the human‑readable KISR code underneath
   - Actions: Copy (code), Share (system sheet), Done
4. Share to recipient
   - The recipient can scan the QR or paste the code
5. Cancellation (optional)
   - To cancel a live invitation: spend the referenced KISRUTXO (e.g., Compound UTXO)

States (Sender)
- Draft → Generated → Shared → Redeemed | Canceled | Failed

### 2) Redeem Flow (Redeemer)

1. Open “Redeem invitation”
   - Default state shows camera preview with “Scan invite QR” and “Enter code manually”
2. Scan or enter code
   - After scan, show an editable `KISR code` field and “Redeem” button
3. Redeem
   - Resolve `txid` from QR/URI or backend (centralized mode allowed by spec)
   - Decrypt and validate envelope, verify UTXO and network
   - Build and broadcast transaction: spend pre‑signed input → output to redeemer minus fee
4. Success
   - Show checkmark, “Redeemed successfully”, and the memo if present
   - Action: Done

States (Redeemer)
- Idle → Code Scanned/Entered → Validating → Broadcasting → Success | Error

## KISR URI Format (for QR and deep links)

Canonical form used in QR payloads and deep links (per `@KISR/spec/deeplink.md`):

```
kaspa:<inviterAddress>/redeem?code=KISR-ABCDEFGH&txid=<kaspa_txid_hex>
```

Testnet variant:

```
kaspatest:<inviterAddress>/redeem?code=KISR-ABCDEFGH&txid=<kaspa_txid_hex>
```

Notes
- Query parameters MUST be URL-encoded
- If both `code` and `txid` are present, proceed directly to redemption UI
- If only `code` is present:
  - Centralized mode (opt-in): implementers MAY resolve `txid` server-side when connected to a trusted backend
- `code` MUST be canonical uppercase using the alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
- `txid` is the anchor transaction id carrying the envelope payload

## Validation & Errors (user‑visible)

- Invalid format: “That code doesn’t look right. Check and try again.”
- Not found / anchor missing: “We can’t find this invitation. It may have been canceled.”
- Decryption failed: “The code doesn’t match this invitation. Check and try again.”
- Already redeemed / UTXO spent: “This invitation was already redeemed or canceled.”
- Network mismatch: “This invitation was created on a different network.”
- Camera permission: “Camera access is required to scan invites.”

## UX Notes

- Memo
  - Max 40 UTF‑8 characters; show live counter (e.g., `17/40`)
  - Display memo on success screen for the redeemer
- Amount input
  - Left: fiat with country selector; Right: read‑only KAS conversion
  - Validate positive amount; disable Continue when invalid
- Accessibility
  - Provide `UIAccessibility` labels for QR, code text, and CTAs
  - Ensure sufficient contrast and large tap targets
- Security
  - Do not log codes, decrypted TLVs, pre‑signatures, or keys
  - Use secure randomness for salts/nonces (see spec §10)

# KISR Deeplink and QR Interop Spec

## 1. URI Scheme
Wallets MUST accept the following canonical deeplink formats:

- Inviter-address form: `kaspa:<inviterAddress>/redeem?code=KISR-XXXXXXXX&txid=<kaspa_txid_hex>`

Notes:
- Query parameters MUST be URL-encoded.
- Centralized deployments MAY accept code-only links `kaspa:<inviterAddress>/redeem?code=KISR-XXXXXXXX` where the TXID is resolved server-side; this mode is out-of-scope for cross-wallet interoperability.


## 2. Display and Sharing
- Wallets SHOULD present both a deeplink and a QR code for sharing.
- Wallets SHOULD display the KISR Code in a human-readable form for manual fallback.
- Wallets SHOULD normalize KISR codes to uppercase and validate the `KISR-XXXXXXXX` format during display and input.

## 3. Parsing Rules
- If both `code` and `txid` are present, proceed with redemption UI.
- If only `code` is present:
  - For decentralized/cross-wallet mode, prompt the user for the missing `txid`.
  - For centralized mode (opt-in), implementers MAY resolve the TXID server-side if the wallet is connected to a trusted backend.
- Wallets SHOULD normalize KISR codes to uppercase and validate the `KISR-XXXXXXXX` format.

## 4. Security UI Guidelines
- Do not display full decrypted details until after successful decryption.
- Warn users that anyone with both `code` and `txid` can redeem the invitation.
- Consider clipboard hygiene and time-limited visibility of the code.

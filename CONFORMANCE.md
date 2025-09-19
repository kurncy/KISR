# KIS Conformance Checklist

Implementers MUST:
- [ ] Support KISR URI schemes per `spec/deeplink.md`
- [ ] Create KISRUTXO as standard output types
- [ ] Produce KISRSign with ANYONECANPAY|NONE
- [ ] Publish anchor with encrypted payload
- [ ] Decrypt payload via Argon2id + XChaCha20-Poly1305
- [ ] Validate network, amount, and utxo unspent
- [ ] Assemble redemption and broadcast

SHOULD:
- [ ] Provide cancel  policy


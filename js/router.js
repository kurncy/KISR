// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//

const express = require('express');
const router = express.Router();

const {
	createUtxoToSelf,
	preSignCreatedUtxo,
	createAnchorToSelfWithPayload,
	assembleAndBroadcastRedemption
} = require('./InviteService');


router.post('/create', async (req, res) => {
	try {
		const { privateKey, network, amount, amountSompi, feeSompi, code, memo } = req.body || {};
		if (!privateKey) return res.status(400).json({ success: false, error: 'privateKey is required' });
		const resolvedNetwork = network || 'mainnet';
		const utxo = await createUtxoToSelf({ privateKey, amount, amountSompi, network: resolvedNetwork, feeSompi: feeSompi ? BigInt(feeSompi) : 0n });
		if (!utxo || !utxo.success) throw new Error('Failed to create self UTXO');
		const presig = await preSignCreatedUtxo({ privateKey, network: resolvedNetwork, txid: utxo.txid, index: utxo.index, amountSompi: utxo.amountSompi, address: utxo.address });
		if (!presig || !presig.success) throw new Error('Failed to pre-sign UTXO');
		const inviteCode = undefined; // TODO: generate code using SDKs
		const payload = undefined; // TODO: build payload using SDKs
		// Need to exclude the UTXO that was created to self (KISRUTXO)
		const anchor = await createAnchorToSelfWithPayload({ privateKey, network: resolvedNetwork, feeSompi: feeSompi ? BigInt(feeSompi) : 0n, payloadHex: payload.envelopeHex, excludeOutpoint: { transactionId: utxo.txid, index: utxo.index } });
		if (!anchor || !anchor.success) throw new Error('Failed to anchor payload');
		return res.json({ success: true, utxo, presig, anchor, code: inviteCode });
	} catch (error) {
		return res.status(500).json({ success: false, error: error.message || 'Internal error' });
	}
});


router.post('/redeem', async (req, res) => {
	try {
		const { code, txid, toAddress, feeSompi, network } = req.body || {};
		if (!code) return res.status(400).json({ success: false, error: 'code is required' });
		if (!txid) return res.status(400).json({ success: false, error: 'txid is required' });
		if (!toAddress) return res.status(400).json({ success: false, error: 'toAddress is required' });
		const net = network || 'mainnet';
		// TODO: fetch payload and decrypt the payload with the code and envelopeHex using the SDK
		const decrypted = undefined;
		let fromAddress = undefined; // in the Deeplink, this is the inviter address
		const broadcast = await assembleAndBroadcastRedemption({ network: net, toAddress, decrypted, feeSompi: feeSompi ? BigInt(feeSompi) : 2000n, fromAddress });
		return res.json({ success: true, transactionId: broadcast.transactionId });
	} catch (error) {
		return res.status(500).json({ success: false, error: error.message || 'Internal error' });
	}
});

module.exports = router;

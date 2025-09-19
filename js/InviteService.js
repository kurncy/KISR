// ============================================================================
// EXAMPLE FILE
// ----------------------------------------------------------------------------
// Used as an example of how to bridge to your SDK/WASM
// ============================================================================
//
//

'use strict';

// Polyfill WebSocket for Kaspa WASM SDK
// @ts-ignore
globalThis.WebSocket = require('websocket').w3cwebsocket;

// NOTE: Replace this import with your project's Kaspa WASM binding
const kaspa = require('../../rusty-kaspa/wasm/nodejs/kaspa/kaspa');
const {
	Resolver,
	RpcClient,
	NetworkId,
	NetworkType,
	Encoding,
	PrivateKey,
	payToAddressScript,
	SighashType,
	kaspaToSompi,
	Transaction,
	createInputSignature,
	signTransaction,
	calculateTransactionFee,
	Generator
} = kaspa;

const https = require('https');

let sodiumPromise = null;
async function getSodium() {
	if (!sodiumPromise) {
		sodiumPromise = (async () => {
			const tryLoad = async (pkg) => {
				let mod;
				try { mod = require(pkg); } catch { return null; }
				const candidate = mod && (mod.default || mod);
				if (!candidate || !candidate.ready) return null;
				await candidate.ready;
				if (typeof candidate.crypto_pwhash === 'function' && typeof candidate.crypto_aead_xchacha20poly1305_ietf_encrypt === 'function') {
					return candidate;
				}
				return null;
			};
			let sodium = await tryLoad('libsodium-wrappers-sumo');
			if (!sodium) sodium = await tryLoad('libsodium-wrappers');
			if (!sodium) throw new Error('Failed to load libsodium-wrappers(-sumo)');
			return sodium;
		})();
	}
	return sodiumPromise;
}

function inferNetworkFromAddress(addr) {
	if (typeof addr !== 'string') return 'mainnet';
	if (addr.startsWith('kaspatest:')) return 'testnet-10';
	return 'mainnet';
}

function normalizeNetwork(network) {
	if (network === 'testnet-10' || network === 'testnet') return 'testnet-10';
	return 'mainnet';
}

async function connectRpc(network) {
	const networkId = new NetworkId(network);
	const rpc = new RpcClient({ resolver: new Resolver(), encoding: Encoding.Borsh, networkId });
	await rpc.connect();
	const { isSynced } = await rpc.getServerInfo();
	if (!isSynced) {
		await rpc.disconnect();
		throw new Error('Kaspa node is not synced');
	}
	return { rpc, networkId };
}

function selectUtxoClosestAtLeast(entries, targetSompi) {
	const target = BigInt(targetSompi);
	const candidates = (entries || []).filter(e => BigInt(e.amount) >= target);
	if (candidates.length === 0) throw new Error('No UTXO meets the required amount');
	candidates.sort((a, b) => {
		const da = BigInt(a.amount) - target;
		const db = BigInt(b.amount) - target;
		if (da < db) return -1;
		if (da > db) return 1;
		if (BigInt(a.amount) < BigInt(b.amount)) return -1;
		if (BigInt(a.amount) > BigInt(b.amount)) return 1;
		return 0;
	});
	return candidates[0];
}

function hexToBuf(hex) { return Buffer.from(String(hex).replace(/^0x/, ''), 'hex'); }
function bufToHex(buf) { return Buffer.from(buf).toString('hex'); }
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function writeTLV(tag, valueBuf) {
	const len = valueBuf.length;
	if (len > 0xffff) throw new Error('TLV value too large');
	const header = Buffer.alloc(3);
	header.writeUInt8(tag, 0);
	header.writeUInt16BE(len, 1);
	return Buffer.concat([header, valueBuf]);
}

function readTLV(buf) {
	const out = {};
	let o = 0;
	while (o + 3 <= buf.length) {
		const tag = buf.readUInt8(o); o += 1;
		const len = buf.readUInt16BE(o); o += 2;
		const v = buf.slice(o, o + len); o += len;
		out[tag] = v;
	}
	return out;
}

function txidHexToLE32(hex) {
	const b = hexToBuf(hex);
	if (b.length !== 32) throw new Error('txid must be 32 bytes');
	return Buffer.from(b.reverse());
}
function le32ToTxidHex(buf) {
	if (buf.length !== 32) throw new Error('txid buf must be 32 bytes');
	return bufToHex(Buffer.from(buf).reverse());
}

async function buildKisEncryptedPayload({ code, network, utxoTxid, utxoIndex, presigHex, amountSompi, inviterPubKeyHex, memo }) {
	const sodium = await getSodium();
	const version = Buffer.from([0x01]);
	const salt = sodium.randombytes_buf(16);
	const nonce = sodium.randombytes_buf(sodium.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES);

	const key = sodium.crypto_pwhash(
		32,
		code,
		salt,
		2,
		64 * 1024 * 1024,
		sodium.crypto_pwhash_ALG_ARGON2ID13
	);

	const tlvs = [];
	const outpointBuf = Buffer.concat([
		txidHexToLE32(utxoTxid),
		Buffer.alloc(4)
	]);
	outpointBuf.writeUInt32LE(utxoIndex >>> 0, 32);
	tlvs.push(writeTLV(0x01, outpointBuf));
	tlvs.push(writeTLV(0x02, hexToBuf(presigHex)));
	tlvs.push(writeTLV(0x03, Buffer.from([0x82])));
	if (inviterPubKeyHex) tlvs.push(writeTLV(0x04, hexToBuf(inviterPubKeyHex)));
	const amt = Buffer.alloc(8);
	const a = BigInt(amountSompi);
	amt.writeUInt32LE(Number(a & 0xffffffffn), 0);
	amt.writeUInt32LE(Number((a >> 32n) & 0xffffffffn), 4);
	tlvs.push(writeTLV(0x05, amt));
	const netId = normalizeNetwork(network) === 'mainnet' ? 0 : 1;
	tlvs.push(writeTLV(0x06, Buffer.from([netId])));
	const now = Math.floor(Date.now() / 1000);
	const ts = Buffer.alloc(8);
	ts.writeUInt32LE(now >>> 0, 0);
	ts.writeUInt32LE(0, 4);
	tlvs.push(writeTLV(0x07, ts));
			if (memo) {
			const memoStr = String(memo);
			if (memoStr.length > 40) {
				throw new Error('memo must be 40 characters or fewer');
			}
			tlvs.push(writeTLV(0x08, Buffer.from(memoStr, 'utf8')));
		}

	const tlvBuf = Buffer.concat(tlvs);

	const cipher = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
		new Uint8Array(tlvBuf),
		new Uint8Array(Buffer.concat([version, Buffer.from(salt)])),
		null,
		nonce,
		key
	);

	const clearPrefix = Buffer.from('KISR-');
	const envelope = Buffer.concat([
		clearPrefix,
		version,
		Buffer.from(salt),
		Buffer.from(nonce),
		Buffer.from(cipher)
	]);
	return { envelopeHex: bufToHex(envelope) };
}

async function decryptKisPayload({ code, envelopeHex }) {
	const sodium = await getSodium();
	const raw = hexToBuf(envelopeHex);
	if (!(raw.length > 5 && raw.subarray(0, 5).toString('ascii') === 'KISR-')) throw new Error('Invalid KISR envelope prefix');
	const buf = raw.subarray(5);
	if (buf.length < 1 + 16 + 24 + 16) throw new Error('Envelope too short');
	const version = buf.readUInt8(0);
	if (version !== 0x01) throw new Error('Unsupported KIS version');
	const salt = buf.slice(1, 17);
	const nonce = buf.slice(17, 41);
	const ciphertext = buf.slice(41);
	const key = sodium.crypto_pwhash(32, code, salt, 2, 64 * 1024 * 1024, sodium.crypto_pwhash_ALG_ARGON2ID13);
	const plaintext = sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(null, ciphertext, new Uint8Array(Buffer.concat([Buffer.from([version]), Buffer.from(salt)])), nonce, key);
	const tlvBuf = Buffer.from(plaintext);
	const tlv = readTLV(tlvBuf);

	const outpoint = tlv[0x01];
	if (!outpoint || outpoint.length !== 36) throw new Error('Invalid outpoint');
	const txid = le32ToTxidHex(outpoint.subarray(0, 32));
	const index = outpoint.readUInt32LE(32);
	const presigHex = tlv[0x02] ? bufToHex(tlv[0x02]) : '';
	const sighashFlags = tlv[0x03] ? tlv[0x03].readUInt8(0) : 0x82;
	const inviterPubKeyHex = tlv[0x04] ? bufToHex(tlv[0x04]) : '';
	const amountBuf = tlv[0x05];
	const amountSompi = amountBuf ? (BigInt(amountBuf.readUInt32LE(0)) + (BigInt(amountBuf.readUInt32LE(4)) << 32n)).toString() : '0';
	const memoBuf = tlv[0x08];
	const memo = memoBuf ? Buffer.from(memoBuf).toString('utf8') : '';
	return { version, txid, index, presigHex, sighashFlags, inviterPubKeyHex, amountSompi, memo };
}

async function httpsGetJson(url) {
	return new Promise((resolve, reject) => {
		const req = https.get(url, { headers: { 'accept': 'application/json' } }, (res) => {
			let data = '';
			res.on('data', c => { data += c; });
			res.on('end', () => {
				try {
					const json = JSON.parse(data || '{}');
					if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) return resolve(json);
					return reject(new Error(`HTTP ${res.statusCode}: ${json && json.error ? json.error : data}`));
				} catch (e) { reject(e); }
			});
		});
		req.on('error', reject);
		req.setTimeout(8000, () => req.destroy(new Error('Request timeout')));
	});
}

async function createUtxoToSelf({ privateKey, amount, amountSompi, network = 'mainnet', feeSompi = 0n }) {
	const net = normalizeNetwork(network);
	const { rpc, networkId } = await connectRpc(net);
	try {
		const privateKeyObj = new PrivateKey(privateKey);
		const networkType = net.includes('testnet') ? NetworkType.Testnet : NetworkType.Mainnet;
		const selfAddress = privateKeyObj.toKeypair().toAddress(networkType).toString();
		const targetSompi = amountSompi !== undefined && amountSompi !== null ? BigInt(amountSompi) : BigInt(kaspaToSompi(String(amount)));
		const { entries } = await rpc.getUtxosByAddresses([selfAddress]);
		if (!entries || entries.length === 0) throw new Error('No UTXOs found for source address');
		const estimateInput = entries[0];
		const estTx = new Transaction({
			version: 0,
			lockTime: 0n,
			inputs: [{ previousOutpoint: estimateInput.outpoint, utxo: estimateInput, sequence: 0n, sigOpCount: 1 }],
			outputs: [{ scriptPublicKey: payToAddressScript(selfAddress), value: targetSompi }],
			subnetworkId: '0000000000000000000000000000000000000000',
			gas: 0n,
			payload: ''
		});
		const minFee = calculateTransactionFee(networkId, estTx, 1) || 0n;
		const requiredTotal = targetSompi + BigInt(feeSompi || 0n) + BigInt(minFee);
		const total = (entries || []).reduce((acc, e) => acc + BigInt(e.amount), 0n);
		if (total < requiredTotal) throw new Error('Insufficient balance for amount + fees');
		entries.sort((a, b) => (BigInt(a.amount) < BigInt(b.amount) ? -1 : 1));
		const generator = new Generator({
			entries,
			outputs: [{ address: selfAddress, amount: targetSompi }],
			priorityFee: BigInt(feeSompi || 0n),
			changeAddress: selfAddress,
			networkId
		});
		let pending, lastTxid = null;
		while (pending = await generator.next()) {
			await pending.sign([privateKeyObj]);
			lastTxid = await pending.submit(rpc);
		}
		if (!lastTxid) throw new Error('Failed to produce transaction');
		return { success: true, txid: lastTxid, index: 0, amountSompi: targetSompi.toString(), address: selfAddress };
	} finally { await rpc.disconnect(); }
}

async function preSignCreatedUtxo({ privateKey, network = 'mainnet', txid, index, amountSompi, address }) {
	const net = normalizeNetwork(network);
	const { rpc } = await connectRpc(net);
	try {
		const privateKeyObj = new PrivateKey(privateKey);
		const maxRetries = 10;
		const delayMs = 1000;
		let inputUtxo = null;
		for (let attempt = 1; attempt <= maxRetries; attempt++) {
			const { entries } = await rpc.getUtxosByAddresses([address]);
			if (entries && entries.length > 0) {
				inputUtxo = entries.find(e => e.outpoint && e.outpoint.transactionId === txid && e.outpoint.index === index);
				if (!inputUtxo) {
					const candidates = entries.filter(e => e.outpoint && e.outpoint.transactionId === txid);
					if (candidates.length === 1) inputUtxo = candidates[0];
					else if (candidates.length > 1 && amountSompi !== undefined && amountSompi !== null) {
						const amt = BigInt(amountSompi);
						const byAmt = candidates.find(e => BigInt(e.amount) === amt);
						if (byAmt) inputUtxo = byAmt;
					}
				}
			}
			if (inputUtxo) break;
			await sleep(delayMs);
		}
		if (!inputUtxo) throw new Error('Specified outpoint not found among address UTXOs');
		const tempTx = new Transaction({
			version: 0,
			lockTime: 0n,
			inputs: [{ previousOutpoint: inputUtxo.outpoint, utxo: inputUtxo, sequence: 0n, sigOpCount: 1 }],
			outputs: [],
			subnetworkId: '0000000000000000000000000000000000000000',
			gas: 0n,
			payload: ''
		});
		const inputIndex = 0;
		const signature = await createInputSignature(tempTx, inputIndex, privateKeyObj, SighashType.NoneAnyOneCanPay);
		if (!signature) throw new Error('Failed to produce pre-signature');
		return { success: true, signature, sighash: 'NoneAnyOneCanPay' };
	} finally { await rpc.disconnect(); }
}

function textToHex(text) { if (text === undefined || text === null) return ''; return Buffer.from(String(text), 'utf8').toString('hex'); }

async function createAnchorToSelfWithPayload({ privateKey, network = 'mainnet', feeSompi = 0n, payloadHex, payloadText, excludeOutpoint }) {
	const net = normalizeNetwork(network);
	const { rpc, networkId } = await connectRpc(net);
	try {
		const privateKeyObj = new PrivateKey(privateKey);
		const networkType = net.includes('testnet') ? NetworkType.Testnet : NetworkType.Mainnet;
		const selfAddress = privateKeyObj.toKeypair().toAddress(networkType).toString();
		const { entries } = await rpc.getUtxosByAddresses([selfAddress]);
		if (!entries || entries.length === 0) throw new Error('No UTXOs found for source address');
		let candidates = [...entries];
		if (excludeOutpoint && excludeOutpoint.transactionId !== undefined && excludeOutpoint.index !== undefined) {
			candidates = candidates.filter(e => !(e.outpoint && e.outpoint.transactionId === excludeOutpoint.transactionId && e.outpoint.index === excludeOutpoint.index));
		}
		if (candidates.length === 0) throw new Error('No eligible UTXOs available for anchoring (all excluded)');
		const sorted = candidates.sort((a, b) => (BigInt(a.amount) < BigInt(b.amount) ? -1 : 1));
		const inputUtxo = sorted[0];
		const inputValue = BigInt(inputUtxo.amount);
		const txInput = { previousOutpoint: inputUtxo.outpoint, utxo: inputUtxo, sequence: 0n, sigOpCount: 1 };
		const outputs = [{ scriptPublicKey: payToAddressScript(selfAddress), value: inputValue }];
		const payload = payloadHex || textToHex(payloadText || '');
		const tx = new Transaction({
			version: 0,
			lockTime: 0n,
			inputs: [txInput],
			outputs,
			subnetworkId: '0000000000000000000000000000000000000000',
			gas: 0n,
			payload
		});
		const minFee = calculateTransactionFee(networkId, tx, 1) || 0n;
		const totalFee = BigInt(minFee) + BigInt(feeSompi || 0n);
		const adjustedChange = inputValue - totalFee;
		if (adjustedChange <= 0n) throw new Error('Insufficient funds for fees');
		outputs[0].value = adjustedChange;
		const finalTx = new Transaction({
			version: 0,
			lockTime: 0n,
			inputs: [txInput],
			outputs,
			subnetworkId: '0000000000000000000000000000000000000000',
			gas: 0n,
			payload
		});
		signTransaction(finalTx, [privateKeyObj], false);
		const { transactionId } = await rpc.submitTransaction({ transaction: finalTx });
		return {
			success: true,
			txid: transactionId,
			tx,
			finalTx
		};
	} finally { await rpc.disconnect(); }
}

async function anchorKisPayload({ privateKey, network = 'mainnet', feeSompi = 0n, code, utxoTxid, utxoIndex, amountSompi, presigHex, inviterPubKeyHex, memo }) {
	const { envelopeHex } = await buildKisEncryptedPayload({ code, network, utxoTxid, utxoIndex, presigHex, amountSompi, inviterPubKeyHex, memo });
	return await createAnchorToSelfWithPayload({ privateKey, network, feeSompi, payloadHex: envelopeHex, excludeOutpoint: { transactionId: utxoTxid, index: utxoIndex } });
}

async function assembleAndBroadcastRedemption({ network = 'mainnet', toAddress, decrypted, feeSompi = 2000n, fromAddress }) {
	const netInput = toAddress ? inferNetworkFromAddress(toAddress) : (network || 'mainnet');
	const net = normalizeNetwork(netInput);
	const { rpc } = await connectRpc(net);
	try {
		if (!fromAddress) throw new Error('fromAddress is required to fetch UTXO details');
		let utxoEntry = null;
		const maxRetries = 5;
		for (let attempt = 1; attempt <= maxRetries; attempt++) {
			const { entries } = await rpc.getUtxosByAddresses([fromAddress]);
			if (entries && entries.length > 0) {
				utxoEntry = entries.find(e => e.outpoint && e.outpoint.transactionId === decrypted.txid && e.outpoint.index === decrypted.index);
				if (utxoEntry) break;
			}
			if (attempt < maxRetries) await sleep(1000);
		}
		if (!utxoEntry) throw new Error(`UTXO not found for ${decrypted.txid}:${decrypted.index} at address ${fromAddress}`);
		const inputValue = BigInt(utxoEntry.amount);
		const txInput = { previousOutpoint: utxoEntry.outpoint, utxo: utxoEntry, sequence: 0n, sigOpCount: 1 };
		const value = inputValue - BigInt(feeSompi);
		if (value <= 0n) throw new Error('Fee too high');
		const outputs = [{ scriptPublicKey: payToAddressScript(toAddress), value }];
		const tx = new Transaction({
			version: 0,
			lockTime: 0n,
			inputs: [txInput],
			outputs,
			subnetworkId: '0000000000000000000000000000000000000000',
			gas: 0n,
			payload: ''
		});
		tx.inputs[0].signatureScript = decrypted.presigHex;
		const { transactionId } = await rpc.submitTransaction({ transaction: tx });
		return {
			success: true,
			transactionId,
			tx
		};
	} finally { await rpc.disconnect(); }
}

module.exports = {
	buildKisEncryptedPayload,
	decryptKisPayload,
	fetchTransactionPayloadHex,
	createUtxoToSelf,
	preSignCreatedUtxo,
	createAnchorToSelfWithPayload,
	anchorKisPayload,
	assembleAndBroadcastRedemption
};

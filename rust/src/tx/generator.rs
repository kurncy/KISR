use std::collections::HashMap;
use std::sync::{Mutex, atomic::{AtomicI32, Ordering}, OnceLock};
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;
use kaspa_addresses as kaddr;
use kaspa_txscript::pay_to_address_script;

use crate::{KaspaUtxoEntry, KaspaOutputEntry, SafeJsonInput, SafeJsonInputUtxo, SafeJsonOutput, SafeJsonTx, decode_spk_hex_strip_optional_version_prefix};

#[derive(Clone)]
pub(crate) struct TxGenUtxo {
        pub(crate) txid: [u8;32],
        pub(crate) index: u32,
        pub(crate) amount: u64,
        pub(crate) spk_bytes: Vec<u8>,
}

#[derive(Clone)]
pub(crate) struct TxGenOutput {
        pub(crate) address: String,
        pub(crate) amount: u64,
}

#[derive(Clone)]
pub(crate) struct TxGenEntry {
        pub(crate) is_testnet: bool,
        pub(crate) fee_rate: i64,
        pub(crate) change_address: Option<String>,
        pub(crate) utxos: Vec<TxGenUtxo>,
        pub(crate) outputs: Vec<TxGenOutput>,
        pub(crate) payload: Vec<u8>,
}

pub(crate) fn __gens() -> &'static Mutex<HashMap<i32, TxGenEntry>> {
        static MAP: OnceLock<Mutex<HashMap<i32, TxGenEntry>>> = OnceLock::new();
        MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

fn __next_gen_handle() -> i32 {
        static NEXT: OnceLock<AtomicI32> = OnceLock::new();
        let next = NEXT.get_or_init(|| AtomicI32::new(1));
        next.fetch_add(1, Ordering::SeqCst)
}

pub(crate) fn tx_generator_new(is_testnet: bool) -> c_int {
        let handle = __next_gen_handle();
        let entry = TxGenEntry {
                is_testnet,
                fee_rate: 0,
                change_address: None,
                utxos: Vec::new(),
                outputs: Vec::new(),
                payload: Vec::new(),
        };
        let map = __gens();
        let mut m = map.lock().unwrap();
        m.insert(handle, entry);
        handle
}

pub(crate) fn tx_generator_free(handle: c_int) -> c_int {
        let mut m = __gens().lock().unwrap();
        if m.remove(&(handle as i32)).is_some() { 0 } else { -1 }
}

pub(crate) fn tx_generator_clear(handle: c_int) -> c_int {
        let mut m = __gens().lock().unwrap();
        if let Some(entry) = m.get_mut(&(handle as i32)) {
                entry.utxos.clear();
                entry.outputs.clear();
                entry.change_address = None;
                entry.payload.clear();
                0
        } else { -1 }
}

pub(crate) fn tx_generator_set_change_address(handle: c_int, address: *const c_char) -> c_int {
        if address.is_null() { return -1; }
        let s = unsafe { CStr::from_ptr(address) }.to_string_lossy().to_string();
        let mut m = __gens().lock().unwrap();
        let Some(entry) = m.get_mut(&(handle as i32)) else { return -2; };
        let addr = match kaddr::Address::try_from(s.as_str()) { Ok(a) => a, Err(_) => return -3 };
        let expected_prefix = if entry.is_testnet { kaddr::Prefix::Testnet } else { kaddr::Prefix::Mainnet };
        if addr.prefix != expected_prefix { return -4; }
        entry.change_address = Some(s);
        0
}

pub(crate) fn tx_generator_set_fee_rate(handle: c_int, fee_rate_sompi_per_kilomass: i64) -> c_int {
        let mut m = __gens().lock().unwrap();
        if let Some(entry) = m.get_mut(&(handle as i32)) {
                entry.fee_rate = fee_rate_sompi_per_kilomass;
                0
        } else { -1 }
}

pub(crate) fn tx_generator_set_payload_hex(handle: c_int, payload_hex: *const c_char) -> c_int {
        let mut m = __gens().lock().unwrap();
        let Some(entry) = m.get_mut(&(handle as i32)) else { return -1; };
        if payload_hex.is_null() { entry.payload.clear(); return 0; }
        let s = unsafe { CStr::from_ptr(payload_hex) }.to_string_lossy().to_string();
        let t = s.trim();
        if t.is_empty() { entry.payload.clear(); return 0; }
        match hex::decode(t) { Ok(v) => { entry.payload = v; 0 }, Err(_) => -2 }
}

pub(crate) fn tx_generator_add_utxo(handle: c_int, utxo_ptr: *const KaspaUtxoEntry) -> c_int {
        if utxo_ptr.is_null() { return -1; }
        let utxo = unsafe { &*utxo_ptr };
        if utxo.txid_be_hex.is_null() || utxo.script_pub_key_hex.is_null() { return -2; }
        let txid_str = unsafe { CStr::from_ptr(utxo.txid_be_hex) }.to_string_lossy().to_string();
        let spk_hex = unsafe { CStr::from_ptr(utxo.script_pub_key_hex) }.to_string_lossy().to_string();
        let txid_bytes = match hex::decode(txid_str.trim()) { Ok(v) => v, Err(_) => return -3 };
        if txid_bytes.len() != 32 { return -4; }
        let mut txid_arr = [0u8;32]; txid_arr.copy_from_slice(&txid_bytes);
        let spk_bytes = match decode_spk_hex_strip_optional_version_prefix(&spk_hex) { Ok(v) => v, Err(_) => return -5 };
        let mut m = __gens().lock().unwrap();
        let Some(entry) = m.get_mut(&(handle as i32)) else { return -6; };
        entry.utxos.push(TxGenUtxo { txid: txid_arr, index: utxo.index, amount: utxo.amount, spk_bytes });
        0
}

pub(crate) fn tx_generator_add_output(handle: c_int, output_ptr: *const KaspaOutputEntry) -> c_int {
        if output_ptr.is_null() { return -1; }
        let output = unsafe { &*output_ptr };
        if output.address.is_null() { return -2; }
        let addr_str = unsafe { CStr::from_ptr(output.address) }.to_string_lossy().to_string();
        let mut m = __gens().lock().unwrap();
        let Some(entry) = m.get_mut(&(handle as i32)) else { return -3; };
        let addr = match kaddr::Address::try_from(addr_str.as_str()) { Ok(a) => a, Err(_) => return -4 };
        let expected_prefix = if entry.is_testnet { kaddr::Prefix::Testnet } else { kaddr::Prefix::Mainnet };
        if addr.prefix != expected_prefix { return -5; }
        entry.outputs.push(TxGenOutput { address: addr_str, amount: output.amount });
        0
}

pub(crate) fn tx_generator_build_unsigned_safejson(gen: c_int) -> *mut c_char {
        use kaspa_consensus_core::tx::{Transaction, TransactionInput, TransactionOutpoint, TransactionOutput, ScriptPublicKey, UtxoEntry, SignableTransaction};
        use kaspa_consensus_core::subnets::SubnetworkId;
        let (is_testnet, fee_rate, change_addr_opt, utxos, outs, payload) = {
                let g = __gens().lock().unwrap();
                let Some(entry) = g.get(&gen) else { return ptr::null_mut(); };
                (entry.is_testnet, entry.fee_rate, entry.change_address.clone(), entry.utxos.clone(), entry.outputs.clone(), entry.payload.clone())
        };
        let default_rate: u64 = 1000;
        let rate = if fee_rate <= 0 { default_rate } else { fee_rate as u64 };
        let total_input: u64 = utxos.iter().map(|u| u.amount).sum();
        let total_output_user: u64 = outs.iter().map(|o| o.amount).sum();
        let assumed_sig_script_len: usize = 66;
        let build_tx = |include_change: bool, change_amount: u64| -> Option<(Transaction, Vec<UtxoEntry>, Vec<(String,u32)>, Vec<String>, Vec<Vec<u8>>)> {
                let mut inputs: Vec<TransactionInput> = Vec::with_capacity(utxos.len());
                let mut entries: Vec<UtxoEntry> = Vec::with_capacity(utxos.len());
                let mut prev_outpoints: Vec<(String,u32)> = Vec::with_capacity(utxos.len());
                let mut utxo_scripts_hex: Vec<String> = Vec::with_capacity(utxos.len());
                let mut outputs_spk_bytes: Vec<Vec<u8>> = Vec::with_capacity(outs.len() + if include_change { 1 } else { 0 });
                for u in utxos.iter() {
                        let spk = ScriptPublicKey::new(0, u.spk_bytes.clone().into());
                        let input = TransactionInput::new(TransactionOutpoint { transaction_id: u.txid.into(), index: u.index }, vec![], 0, 1);
                        inputs.push(input);
                        entries.push(UtxoEntry::new(u.amount, spk.clone(), 0, false));
                        let txid_be_hex_str = hex::encode(u.txid);
                        prev_outpoints.push((txid_be_hex_str, u.index));
                        utxo_scripts_hex.push(hex::encode(&u.spk_bytes));
                }
                let mut outputs: Vec<TransactionOutput> = Vec::with_capacity(outs.len() + if include_change { 1 } else { 0 });
                for o in outs.iter() {
                        let addr = kaddr::Address::try_from(o.address.as_str()).ok()?;
                        let expected_prefix = if is_testnet { kaddr::Prefix::Testnet } else { kaddr::Prefix::Mainnet };
                        if addr.prefix != expected_prefix { return None; }
                        let spk = pay_to_address_script(&addr);
                        outputs_spk_bytes.push(spk.script().to_vec());
                        outputs.push(TransactionOutput { value: o.amount, script_public_key: spk });
                }
                if include_change {
                        let change_addr = kaddr::Address::try_from(change_addr_opt.as_ref()?.as_str()).ok()?;
                        let spk = pay_to_address_script(&change_addr);
                        outputs_spk_bytes.push(spk.script().to_vec());
                        outputs.push(TransactionOutput { value: change_amount, script_public_key: spk });
                }
                let mut tx = Transaction::new(0, inputs, outputs, 0, SubnetworkId::default(), 0, payload.clone());
                for inp in tx.inputs.iter_mut() { inp.signature_script = vec![0u8; assumed_sig_script_len]; }
                tx.finalize();
                Some((tx, entries, prev_outpoints, utxo_scripts_hex, outputs_spk_bytes))
        };
        let (tx0, entries0, _prev0, _spkhex0, _outspk0) = match build_tx(false, 0) { Some(v) => v, None => return ptr::null_mut() };
        let mass0 = {
                use kaspa_consensus_core::config::params::Params;
                use kaspa_consensus_core::network::NetworkType;
                use kaspa_consensus_core::mass::MassCalculator;
                let params: Params = NetworkType::Mainnet.into();
                let mc = MassCalculator::new_with_consensus_params(&params);
                let non = mc.calc_non_contextual_masses(&tx0);
                let ctx = mc.calc_contextual_masses(&(&SignableTransaction::with_entries(tx0.clone(), entries0.clone())).as_verifiable()).unwrap_or(kaspa_consensus_core::mass::ContextualMasses::new(0));
                ctx.max(non)
        } as u64;
        let min_fee0 = ((mass0 as u128) * (rate as u128) + 999) / 1000;
        let change = (total_input as i128) - (total_output_user as i128) - (min_fee0 as i128);
        let include_change = change_addr_opt.is_some() && change > 0;
        let (mut tx, mut entries, prev_outpoints, utxo_scripts_hex, outputs_spk_bytes) = if include_change {
                let change_u = change as u64;
                match build_tx(true, change_u) { Some(v) => v, None => return ptr::null_mut() }
        } else {
                (tx0, entries0, _prev0, _spkhex0, _outspk0)
        };
        for inp in tx.inputs.iter_mut() { inp.signature_script.clear(); }
        let id = tx.id().to_string();
        let mass = {
                use kaspa_consensus_core::config::params::Params;
                use kaspa_consensus_core::network::NetworkType;
                use kaspa_consensus_core::mass::{MassCalculator};
                let params: Params = NetworkType::Mainnet.into();
                let mc = MassCalculator::new_with_consensus_params(&params);
                let non = mc.calc_non_contextual_masses(&tx);
                let ctx = mc.calc_contextual_masses(&(&SignableTransaction::with_entries(tx.clone(), entries.clone())).as_verifiable()).unwrap_or(kaspa_consensus_core::mass::ContextualMasses::new(0));
                ctx.max(non)
        };
        let mut inputs_json: Vec<SafeJsonInput> = Vec::with_capacity(tx.inputs.len());
        for (i, inp) in tx.inputs.iter().enumerate() {
                let (txid_be_hex, index) = &prev_outpoints[i];
                let utxo_spk_prefixed = format!("0000{}", utxo_scripts_hex[i].to_lowercase());
                let utxo_amount_str = utxos[i].amount.to_string();
                let utxo_block_daa_score_str = "0".to_string();
                let utxo_is_coinbase = false;
                inputs_json.push(SafeJsonInput {
                        transaction_id: txid_be_hex.clone(),
                        index: *index,
                        signature_script: hex::encode(&inp.signature_script),
                        sequence: inp.sequence.to_string(),
                        sig_op_count: 1,
                        utxo: SafeJsonInputUtxo {
                                address: None,
                                amount: utxo_amount_str,
                                script_public_key: utxo_spk_prefixed,
                                block_daa_score: utxo_block_daa_score_str,
                                is_coinbase: utxo_is_coinbase,
                        },
                });
        }
        let mut outputs_json: Vec<SafeJsonOutput> = Vec::with_capacity(tx.outputs.len());
        for (idx, out) in tx.outputs.iter().enumerate() {
                let spk_hex = hex::encode(&outputs_spk_bytes[idx].as_slice());
                let spk_prefixed = format!("0000{}", spk_hex);
                outputs_json.push(SafeJsonOutput { value: out.value.to_string(), script_public_key: spk_prefixed });
        }
        let safe = SafeJsonTx {
                id,
                inputs: inputs_json,
                outputs: outputs_json,
                version: tx.version,
                lock_time: tx.lock_time.to_string(),
                gas: tx.gas.to_string(),
                subnetwork_id: format!("{:040}", 0),
                payload: hex::encode(&payload),
                mass: mass.to_string(),
        };
        match serde_json::to_string(&safe) { Ok(s) => CString::new(s).ok().map(CString::into_raw).unwrap_or(ptr::null_mut()), Err(_) => ptr::null_mut() }
}

pub(crate) fn tx_generator_build_and_sign_safejson_with_type_and_algo(gen: c_int, private_key_hex: *const c_char, sighash_type_u8: u8, algo: u8) -> *mut c_char {
        use kaspa_consensus_core::tx::{Transaction, TransactionInput, TransactionOutpoint, TransactionOutput, ScriptPublicKey, UtxoEntry, SignableTransaction};
        use kaspa_consensus_core::subnets::SubnetworkId;
        use kaspa_consensus_core::hashing::{sighash::{calc_schnorr_signature_hash, calc_ecdsa_signature_hash}, sighash::SigHashReusedValuesUnsync, sighash_type::SigHashType};
        use secp256k1::{Keypair, Message, Secp256k1, SecretKey};
        if private_key_hex.is_null() { return ptr::null_mut(); }
        let (is_testnet, fee_rate, change_addr_opt, utxos, outs, payload) = {
                let g = __gens().lock().unwrap();
                let Some(entry) = g.get(&gen) else { return ptr::null_mut(); };
                (entry.is_testnet, entry.fee_rate, entry.change_address.clone(), entry.utxos.clone(), entry.outputs.clone(), entry.payload.clone())
        };
        let sig_type = match SigHashType::from_u8(sighash_type_u8) { Ok(t) => t, Err(_) => return ptr::null_mut() };
        let use_ecdsa = match algo { 0 => false, 1 => true, _ => return ptr::null_mut() };
        let default_rate: u64 = 1000;
        let rate = if fee_rate <= 0 { default_rate } else { fee_rate as u64 };
        let total_input: u64 = utxos.iter().map(|u| u.amount).sum();
        let total_output_user: u64 = outs.iter().map(|o| o.amount).sum();
        let sk_hex = unsafe { CStr::from_ptr(private_key_hex) }.to_string_lossy().to_string();
        let sk_bytes = match hex::decode(sk_hex.trim()) { Ok(v) => v, Err(_) => return ptr::null_mut() };
        if sk_bytes.len() != 32 { return ptr::null_mut(); }
        let assumed_sig_script_len: usize = 66;
        let build_tx = |include_change: bool, change_amount: u64| -> Option<(Transaction, Vec<UtxoEntry>, Vec<(String,u32)>, Vec<String>, Vec<Vec<u8>>)> {
                let mut inputs: Vec<TransactionInput> = Vec::with_capacity(utxos.len());
                let mut entries: Vec<UtxoEntry> = Vec::with_capacity(utxos.len());
                let mut prev_outpoints: Vec<(String,u32)> = Vec::with_capacity(utxos.len());
                let mut utxo_scripts_hex: Vec<String> = Vec::with_capacity(utxos.len());
                let mut outputs_spk_bytes: Vec<Vec<u8>> = Vec::with_capacity(outs.len() + if include_change { 1 } else { 0 });
                for u in utxos.iter() {
                        let spk = ScriptPublicKey::new(0, u.spk_bytes.clone().into());
                        let input = TransactionInput::new(TransactionOutpoint { transaction_id: u.txid.into(), index: u.index }, vec![], 0, 1);
                        inputs.push(input);
                        entries.push(UtxoEntry::new(u.amount, spk.clone(), 0, false));
                        let txid_be_hex_str = hex::encode(u.txid);
                        prev_outpoints.push((txid_be_hex_str, u.index));
                        utxo_scripts_hex.push(hex::encode(&u.spk_bytes));
                }
                let mut outputs: Vec<TransactionOutput> = Vec::with_capacity(outs.len() + if include_change { 1 } else { 0 });
                for o in outs.iter() {
                        let addr = kaddr::Address::try_from(o.address.as_str()).ok()?;
                        let expected_prefix = if is_testnet { kaddr::Prefix::Testnet } else { kaddr::Prefix::Mainnet };
                        if addr.prefix != expected_prefix { return None; }
                        let spk = pay_to_address_script(&addr);
                        outputs_spk_bytes.push(spk.script().to_vec());
                        outputs.push(TransactionOutput { value: o.amount, script_public_key: spk });
                }
                if include_change {
                        let change_addr = kaddr::Address::try_from(change_addr_opt.as_ref()?.as_str()).ok()?;
                        let spk = pay_to_address_script(&change_addr);
                        outputs_spk_bytes.push(spk.script().to_vec());
                        outputs.push(TransactionOutput { value: change_amount, script_public_key: spk });
                }
                let mut tx = Transaction::new(0, inputs, outputs, 0, SubnetworkId::default(), 0, payload.clone());
                for inp in tx.inputs.iter_mut() { inp.signature_script = vec![0u8; assumed_sig_script_len]; }
                tx.finalize();
                Some((tx, entries, prev_outpoints, utxo_scripts_hex, outputs_spk_bytes))
        };
        let (tx0, entries0, prev0, spkhex0, outspk0) = match build_tx(false, 0) { Some(v) => v, None => return ptr::null_mut() };
        let mass0 = {
                use kaspa_consensus_core::config::params::Params;
                use kaspa_consensus_core::network::NetworkType;
                use kaspa_consensus_core::mass::MassCalculator;
                let params: Params = NetworkType::Mainnet.into();
                let mc = MassCalculator::new_with_consensus_params(&params);
                let non = mc.calc_non_contextual_masses(&tx0);
                let ctx = mc.calc_contextual_masses(&(&SignableTransaction::with_entries(tx0.clone(), entries0.clone())).as_verifiable()).unwrap_or(kaspa_consensus_core::mass::ContextualMasses::new(0));
                ctx.max(non)
        } as u64;
        let min_fee0 = ((mass0 as u128) * (rate as u128) + 999) / 1000;
        let change = (total_input as i128) - (total_output_user as i128) - (min_fee0 as i128);
        let include_change = change_addr_opt.is_some() && change > 0;
        let (mut tx, mut entries, mut prev_outpoints, mut utxo_scripts_hex, mut outputs_spk_bytes) = if include_change {
                let change_u = change as u64;
                match build_tx(true, change_u) { Some(v) => v, None => return ptr::null_mut() }
        } else {
                (tx0.clone(), entries0.clone(), prev0.clone(), spkhex0.clone(), outspk0.clone())
        };
        if include_change {
                let mass1 = {
                        use kaspa_consensus_core::config::params::Params;
                        use kaspa_consensus_core::network::NetworkType;
                        use kaspa_consensus_core::mass::MassCalculator;
                        let params: Params = NetworkType::Mainnet.into();
                        let mc = MassCalculator::new_with_consensus_params(&params);
                        let non = mc.calc_non_contextual_masses(&tx);
                        let ctx = mc.calc_contextual_masses(&(&SignableTransaction::with_entries(tx.clone(), entries.clone())).as_verifiable()).unwrap_or(kaspa_consensus_core::mass::ContextualMasses::new(0));
                        ctx.max(non)
                } as u64;
                let min_fee1 = ((mass1 as u128) * (rate as u128) + 999) / 1000;
                let change1 = (total_input as i128) - (total_output_user as i128) - (min_fee1 as i128);
                if change1 <= 0 {
                        // Fallback to no-change tx
                        tx = tx0;
                        entries = entries0;
                        prev_outpoints = prev0;
                        utxo_scripts_hex = spkhex0;
                        outputs_spk_bytes = outspk0;
                } else {
                        if let Some(last) = tx.outputs.last_mut() { last.value = change1 as u64; }
                }
        }
        let secp = Secp256k1::new();
        let signable = SignableTransaction::with_entries(tx.clone(), entries.clone());
        let mut reused = SigHashReusedValuesUnsync::new();
        if use_ecdsa {
                let sk = match SecretKey::from_slice(&sk_bytes) { Ok(k) => k, Err(_) => return ptr::null_mut() };
                for input_index in 0..signable.tx.inputs.len() {
                        let sig_hash = calc_ecdsa_signature_hash(&signable.as_verifiable(), input_index, sig_type, &mut reused);
                        let msg = match Message::from_digest_slice(&sig_hash.as_bytes()) { Ok(m) => m, Err(_) => return ptr::null_mut() };
                        let sig = secp.sign_ecdsa(&msg, &sk);
                        let mut der = sig.serialize_der().to_vec();
                        der.push(sig_type.to_u8());
                        let mut sig_script: Vec<u8> = Vec::with_capacity(der.len() + 5);
                        crate::script_push_data(&mut sig_script, &der);
                        tx.inputs[input_index].signature_script = sig_script;
                }
        } else {
                let keypair = match Keypair::from_seckey_slice(&secp, &sk_bytes) { Ok(k) => k, Err(_) => return ptr::null_mut() };
                for input_index in 0..signable.tx.inputs.len() {
                        let sig_hash = calc_schnorr_signature_hash(&signable.as_verifiable(), input_index, sig_type, &mut reused);
                        let msg = match Message::from_digest_slice(&sig_hash.as_bytes()) { Ok(m) => m, Err(_) => return ptr::null_mut() };
                        let aux = [0u8;32];
                        let sig = secp.sign_schnorr_with_aux_rand(&msg, &keypair, &aux);
                        let sig_bytes: [u8;64] = sig.as_ref().clone();
                        let mut sig_script = Vec::with_capacity(1 + 64 + 1);
                        sig_script.push(64u8 + 1u8);
                        sig_script.extend_from_slice(&sig_bytes);
                        sig_script.push(sig_type.to_u8());
                        tx.inputs[input_index].signature_script = sig_script;
                }
        }
        tx.finalize();
        let id = tx.id().to_string();
        let mass = {
                use kaspa_consensus_core::config::params::Params;
                use kaspa_consensus_core::network::NetworkType;
                use kaspa_consensus_core::mass::{MassCalculator};
                let params: Params = NetworkType::Mainnet.into();
                let mc = MassCalculator::new_with_consensus_params(&params);
                let non = mc.calc_non_contextual_masses(&tx);
                let ctx = mc.calc_contextual_masses(&(&SignableTransaction::with_entries(tx.clone(), entries.clone())).as_verifiable()).unwrap_or(kaspa_consensus_core::mass::ContextualMasses::new(0));
                ctx.max(non)
        };
        let mut inputs_json: Vec<SafeJsonInput> = Vec::with_capacity(tx.inputs.len());
        for (i, inp) in tx.inputs.iter().enumerate() {
                let (txid_be_hex, index) = &prev_outpoints[i];
                let utxo_spk_prefixed = format!("0000{}", utxo_scripts_hex[i].to_lowercase());
                let utxo_amount_str = utxos[i].amount.to_string();
                let utxo_block_daa_score_str = "0".to_string();
                let utxo_is_coinbase = false;
                inputs_json.push(SafeJsonInput {
                        transaction_id: txid_be_hex.clone(),
                        index: *index,
                        signature_script: hex::encode(&inp.signature_script),
                        sequence: inp.sequence.to_string(),
                        sig_op_count: 1,
                        utxo: SafeJsonInputUtxo {
                                address: None,
                                amount: utxo_amount_str,
                                script_public_key: utxo_spk_prefixed,
                                block_daa_score: utxo_block_daa_score_str,
                                is_coinbase: utxo_is_coinbase,
                        },
                });
        }
        let mut outputs_json: Vec<SafeJsonOutput> = Vec::with_capacity(tx.outputs.len());
        for (idx, out) in tx.outputs.iter().enumerate() {
                let spk_hex = hex::encode(&outputs_spk_bytes[idx].as_slice());
                let spk_prefixed = format!("0000{}", spk_hex);
                outputs_json.push(SafeJsonOutput { value: out.value.to_string(), script_public_key: spk_prefixed });
        }
        let safe = SafeJsonTx {
                id,
                inputs: inputs_json,
                outputs: outputs_json,
                version: tx.version,
                lock_time: tx.lock_time.to_string(),
                gas: tx.gas.to_string(),
                subnetwork_id: format!("{:040}", 0),
                payload: hex::encode(&payload),
                mass: mass.to_string(),
        };
        match serde_json::to_string(&safe) { Ok(s) => CString::new(s).ok().map(CString::into_raw).unwrap_or(ptr::null_mut()), Err(_) => ptr::null_mut() }
}

// C ABI wrappers expected by callers
#[no_mangle]
pub extern "C" fn kaspa_tx_generator_new(is_testnet: bool) -> c_int {
        tx_generator_new(is_testnet)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_free(handle: c_int) -> c_int {
        tx_generator_free(handle)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_clear(handle: c_int) -> c_int {
        tx_generator_clear(handle)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_set_change_address(handle: c_int, address: *const c_char) -> c_int {
        tx_generator_set_change_address(handle, address)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_set_fee_rate(handle: c_int, fee_rate_sompi_per_kilomass: i64) -> c_int {
        tx_generator_set_fee_rate(handle, fee_rate_sompi_per_kilomass)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_add_utxo(handle: c_int, utxo_ptr: *const KaspaUtxoEntry) -> c_int {
        tx_generator_add_utxo(handle, utxo_ptr)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_add_output(handle: c_int, output_ptr: *const KaspaOutputEntry) -> c_int {
        tx_generator_add_output(handle, output_ptr)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_set_payload_hex(handle: c_int, payload_hex: *const c_char) -> c_int {
        tx_generator_set_payload_hex(handle, payload_hex)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_build_unsigned_safejson(gen: c_int) -> *mut c_char {
        tx_generator_build_unsigned_safejson(gen)
}

#[no_mangle]
pub extern "C" fn kaspa_tx_generator_build_and_sign_safejson_with_type_and_algo(
        gen: c_int,
        private_key_hex: *const c_char,
        sighash_type: u8,
        algo: u8,
) -> *mut c_char {
        tx_generator_build_and_sign_safejson_with_type_and_algo(gen, private_key_hex, sighash_type, algo)
}

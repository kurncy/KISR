use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;

use serde::Serialize;
use kaspa_addresses as kaddr;
use kaspa_txscript::pay_to_address_script;

use crate::{KaspaUtxoEntry, KaspaOutputEntry, set_last_error};

#[no_mangle]
pub extern "C" fn kaspa_estimate_fee_from_entries(
        utxos_ptr: *const KaspaUtxoEntry,
        utxos_len: c_int,
        outputs_ptr: *const KaspaOutputEntry,
        outputs_len: c_int,
        network_is_testnet: bool,
        fee_rate_sompi_per_kilomass: i64,
        payload_hex: *const c_char,
) -> *mut c_char {
        use kaspa_consensus_core::tx::{Transaction, TransactionInput, TransactionOutpoint, TransactionOutput, ScriptPublicKey, UtxoEntry};
        use kaspa_consensus_core::subnets::SubnetworkId;

        if utxos_ptr.is_null() || utxos_len <= 0 || outputs_ptr.is_null() || outputs_len <= 0 {
                set_last_error("kaspa_estimate_fee_from_entries: invalid arguments");
                return ptr::null_mut();
        }

        let utxos: &[KaspaUtxoEntry] = unsafe { std::slice::from_raw_parts(utxos_ptr, utxos_len as usize) };
        let outputs_in: &[KaspaOutputEntry] = unsafe { std::slice::from_raw_parts(outputs_ptr, outputs_len as usize) };

        let mut inputs: Vec<TransactionInput> = Vec::with_capacity(utxos.len());
        let mut entries: Vec<UtxoEntry> = Vec::with_capacity(utxos.len());
        let mut total_input: u64 = 0;

        for u in utxos.iter() {
                if u.txid_be_hex.is_null() || u.script_pub_key_hex.is_null() { set_last_error("kaspa_estimate_fee_from_entries: null utxo fields"); return ptr::null_mut(); }
                let txid_be_hex = unsafe { CStr::from_ptr(u.txid_be_hex) }.to_string_lossy().to_string();
                let script_hex = unsafe { CStr::from_ptr(u.script_pub_key_hex) }.to_string_lossy().to_string();
                let txid_be_bytes = match hex::decode(txid_be_hex.trim()) { Ok(v) => v, Err(_) => { set_last_error("kaspa_estimate_fee_from_entries: invalid utxo txid hex"); return ptr::null_mut() } };
                if txid_be_bytes.len() != 32 { set_last_error("kaspa_estimate_fee_from_entries: utxo txid len != 32"); return ptr::null_mut(); }
                let mut txid_arr = [0u8;32]; txid_arr.copy_from_slice(&txid_be_bytes);
                let spk_bytes = match crate::decode_spk_hex_strip_optional_version_prefix(&script_hex) { Ok(v) => v, Err(_) => { set_last_error("kaspa_estimate_fee_from_entries: invalid utxo script hex"); return ptr::null_mut() } };
                let script = ScriptPublicKey::new(0, spk_bytes.into());

                let input = TransactionInput::new(
                        TransactionOutpoint { transaction_id: txid_arr.into(), index: u.index },
                        vec![],
                        0,
                        1,
                );
                inputs.push(input);
                entries.push(UtxoEntry::new(u.amount, script.clone(), 0, false));
                total_input = total_input.saturating_add(u.amount);
        }

        let mut outputs: Vec<TransactionOutput> = Vec::with_capacity(outputs_in.len());
        let mut total_output: u64 = 0;
        for o in outputs_in.iter() {
                if o.address.is_null() { set_last_error("kaspa_estimate_fee_from_entries: null output address"); return ptr::null_mut(); }
                let addr_str = unsafe { CStr::from_ptr(o.address) }.to_string_lossy().to_string();
                let addr = match kaddr::Address::try_from(addr_str.as_str()) { Ok(a) => a, Err(_) => { set_last_error("kaspa_estimate_fee_from_entries: invalid output address"); return ptr::null_mut() } };
                let expected_prefix = if network_is_testnet { kaddr::Prefix::Testnet } else { kaddr::Prefix::Mainnet };
                if addr.prefix != expected_prefix { set_last_error("kaspa_estimate_fee_from_entries: address prefix mismatch"); return ptr::null_mut(); }
                let spk = pay_to_address_script(&addr);
                outputs.push(TransactionOutput { value: o.amount, script_public_key: spk });
                total_output = total_output.saturating_add(o.amount);
        }

        let payload_bytes: Vec<u8> = if payload_hex.is_null() { vec![] } else {
                let s = unsafe { CStr::from_ptr(payload_hex) }.to_string_lossy().to_string();
                let t = s.trim();
                if t.is_empty() { vec![] } else { match hex::decode(t) { Ok(v) => v, Err(_) => { set_last_error("kaspa_estimate_fee_from_entries: invalid payload hex"); return ptr::null_mut() } } }
        };

        let mut tx = Transaction::new(
                0,
                inputs,
                outputs,
                0,
                SubnetworkId::default(),
                0,
                payload_bytes,
        );

        for inp in tx.inputs.iter_mut() { inp.signature_script = vec![0u8; 66]; }
        tx.finalize();
        let mass: u64 = {
                use kaspa_consensus_core::config::params::Params;
                use kaspa_consensus_core::network::NetworkType;
                use kaspa_consensus_core::mass::{MassCalculator};
                use kaspa_consensus_core::tx::SignableTransaction;
                let signable = SignableTransaction::with_entries(tx.clone(), entries.clone());
                let params: Params = NetworkType::Mainnet.into();
                let mc = MassCalculator::new_with_consensus_params(&params);
                let non = mc.calc_non_contextual_masses(&signable.tx);
                let ctx = mc.calc_contextual_masses(&signable.as_verifiable()).unwrap_or(kaspa_consensus_core::mass::ContextualMasses::new(0));
                ctx.max(non)
        };

        let default_rate: u64 = 1000;
        let rate = if fee_rate_sompi_per_kilomass <= 0 { default_rate } else { fee_rate_sompi_per_kilomass as u64 };
        let min_fee = ((mass as u128) * (rate as u128) + 999) / 1000;
        let min_fee_u64 = if min_fee > u64::MAX as u128 { u64::MAX } else { min_fee as u64 };
        let change: i128 = (total_input as i128) - (total_output as i128) - (min_fee_u64 as i128);

        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct EstOut { mass: u64, min_fee: u64, total_input: u64, total_output: u64, change: i64 }
        let out = EstOut {
                mass,
                min_fee: min_fee_u64,
                total_input,
                total_output,
                change: if change < i64::MIN as i128 { i64::MIN } else if change > i64::MAX as i128 { i64::MAX } else { change as i64 },
        };
        match serde_json::to_string(&out) {
                Ok(s) => CString::new(s).ok().map(CString::into_raw).unwrap_or(ptr::null_mut()),
                Err(_) => { set_last_error("kaspa_estimate_fee_from_entries: serialization error"); ptr::null_mut() },
        }
}

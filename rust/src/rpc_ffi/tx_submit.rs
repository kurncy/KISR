use super::*;
use kaspa_rpc_core::api::rpc::RpcApi;

#[no_mangle]
pub extern "C" fn kaspa_rpc_submit_safe_json(handle: i32, safe_json: *const c_char, _network: *const c_char) -> *mut c_char {
        use kaspa_consensus_core::tx::{Transaction, TransactionInput, TransactionOutpoint, TransactionOutput, ScriptPublicKey};
        use kaspa_consensus_core::subnets::SubnetworkId;
        if safe_json.is_null() { set_last_error("kaspa_rpc_submit_safe_json: null safe_json"); return ptr::null_mut(); }
        let Some(inner) = get_client(handle) else { set_last_error("kaspa_rpc_submit_safe_json: invalid handle"); return ptr::null_mut(); };
        let json = unsafe { CStr::from_ptr(safe_json) }.to_string_lossy().to_string();
        let parsed: SafeJsonTx = match serde_json::from_str(&json) { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid json: {:?}", e)); return ptr::null_mut() } };
        let mut inputs: Vec<TransactionInput> = Vec::with_capacity(parsed.inputs.len());
        for inp in parsed.inputs.iter() {
                let txid_be_bytes = match hex::decode(inp.transaction_id.trim()) { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid input txid hex: {:?}", e)); return ptr::null_mut() } };
                if txid_be_bytes.len() != 32 { set_last_error("kaspa_rpc_submit_safe_json: input txid len != 32"); return ptr::null_mut(); }
                let mut txid_arr = [0u8;32];
                txid_arr.copy_from_slice(&txid_be_bytes);
                let sig_script = match hex::decode(inp.signature_script.trim()) { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid signature_script hex: {:?}", e)); return ptr::null_mut() } };
                let sequence_u64 = match inp.sequence.parse::<u64>() { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid sequence: {:?}", e)); return ptr::null_mut() } };
                let input = TransactionInput::new(
                        TransactionOutpoint { transaction_id: txid_arr.into(), index: inp.index },
                        sig_script,
                        sequence_u64,
                        inp.sig_op_count,
                );
                inputs.push(input);
        }
        let mut outputs: Vec<TransactionOutput> = Vec::with_capacity(parsed.outputs.len());
        for out in parsed.outputs.iter() {
                let value_u64 = match out.value.parse::<u64>() { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid output value: {:?}", e)); return ptr::null_mut() } };
                let spk = out.script_public_key.trim();
                if spk.len() < 4 { set_last_error("kaspa_rpc_submit_safe_json: invalid script_public_key encoding"); return ptr::null_mut(); }
                let ver_hex = &spk[0..4];
                let script_hex = &spk[4..];
                let ver = match u16::from_str_radix(ver_hex, 16) { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid spk version: {:?}", e)); return ptr::null_mut() } };
                let script_bytes = match hex::decode(script_hex) { Ok(v) => v, Err(e) => { set_last_error(format!("kaspa_rpc_submit_safe_json: invalid spk script hex: {:?}", e)); return ptr::null_mut() } };
                let spk_obj = ScriptPublicKey::new(ver, script_bytes.into());
                outputs.push(TransactionOutput { value: value_u64, script_public_key: spk_obj });
        }
        let lock_time = match parsed.lock_time.parse::<u64>() { Ok(v) => v, Err(_) => 0 };
        let gas = match parsed.gas.parse::<u64>() { Ok(v) => v, Err(_) => 0 };
        let payload: Vec<u8> = if parsed.payload.is_empty() { vec![] } else { match hex::decode(parsed.payload.trim()) { Ok(v) => v, Err(_) => vec![] } };
        let mut tx = Transaction::new(parsed.version, inputs, outputs, lock_time, SubnetworkId::default(), gas, payload);
        tx.finalize();
        let tx_id = tx.id().to_string();
        let rt = GlobalRt::get();
        let res = rt.block_on(async move {
                inner.client.submit_transaction(kaspa_rpc_core::model::RpcTransaction::from(&tx), false).await.map_err(|e| format!("submit_transaction error: {:?}", e))
        });
        match res {
                Ok(_) => CString::new(tx_id).ok().map(CString::into_raw).unwrap_or(ptr::null_mut()),
                Err(e) => { set_last_error(e); ptr::null_mut() },
        }
}

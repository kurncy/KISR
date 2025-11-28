use super::*;

#[no_mangle]
pub extern "C" fn kaspa_rpc_get_utxos(handle: i32, address: *const c_char) -> *mut c_char {
        if address.is_null() { set_last_error("kaspa_rpc_get_utxos: null address"); return ptr::null_mut(); }
        let Some(inner) = get_client(handle) else { set_last_error("kaspa_rpc_get_utxos: invalid handle"); return ptr::null_mut(); };
        let addr_str = unsafe { CStr::from_ptr(address) }.to_string_lossy().to_string();
        let addr = match RpcAddress::try_from(addr_str.as_str()) { Ok(a) => a, Err(e) => { set_last_error(format!("kaspa_rpc_get_utxos: invalid address: {:?}", e)); return ptr::null_mut() } };
        let rt = GlobalRt::get();
        let res = rt.block_on(async move {
                let utxos = inner.client.get_utxos_by_addresses(vec![addr]).await.map_err(|e| format!("get_utxos_by_addresses error: {:?}", e))?;
                Ok::<String, String>(serde_json::to_string(&utxos).unwrap_or_else(|_| "[]".to_string()))
        });
        match res { Ok(s) => CString::new(s).ok().map(CString::into_raw).unwrap_or(ptr::null_mut()), Err(e) => { set_last_error(e); ptr::null_mut() } }
}

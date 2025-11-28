use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::cell::RefCell;

use serde::{Serialize, Deserialize};

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = RefCell::new(None);
}

pub fn set_last_error<S: Into<String>>(msg: S) {
    LAST_ERROR.with(|e| *e.borrow_mut() = Some(msg.into()));
}

pub fn take_last_error() -> Option<String> {
    LAST_ERROR.with(|e| e.borrow_mut().take())
}

#[no_mangle]
pub extern "C" fn kaspa_last_error_message() -> *mut c_char {
    match take_last_error() {
        Some(s) => CString::new(s).ok().map(CString::into_raw).unwrap_or(ptr::null_mut()),
        None => ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn kaspa_string_free(ptr_str: *mut c_char) {
    if ptr_str.is_null() { return; }
    unsafe { drop(CString::from_raw(ptr_str)); }
}

#[repr(C)]
#[derive(Clone)]
pub struct KaspaUtxoEntry {
    pub txid_be_hex: *const c_char,
    pub index: u32,
    pub amount: u64,
    pub script_pub_key_hex: *const c_char,
}

#[repr(C)]
#[derive(Clone)]
pub struct KaspaOutputEntry {
    pub address: *const c_char,
    pub amount: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SafeJsonInputUtxo {
    pub(crate) address: Option<String>,
    pub(crate) amount: String,
    pub(crate) script_public_key: String,
    pub(crate) block_daa_score: String,
    pub(crate) is_coinbase: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SafeJsonInput {
    pub(crate) transaction_id: String,
    pub(crate) index: u32,
    pub(crate) signature_script: String,
    pub(crate) sequence: String,
    pub(crate) sig_op_count: u8,
    pub(crate) utxo: SafeJsonInputUtxo,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SafeJsonOutput {
    pub(crate) value: String,
    pub(crate) script_public_key: String,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SafeJsonTx {
    pub(crate) id: String,
    pub(crate) inputs: Vec<SafeJsonInput>,
    pub(crate) outputs: Vec<SafeJsonOutput>,
    pub(crate) version: u16,
    pub(crate) lock_time: String,
    pub(crate) gas: String,
    pub(crate) subnetwork_id: String,
    pub(crate) payload: String,
    pub(crate) mass: String,
}

// Helper shared with fee & rpc code
pub(crate) fn decode_spk_hex_strip_optional_version_prefix(hex_str: &str) -> Result<Vec<u8>, ()> {
    let s = hex_str.trim();
    let payload = if s.len() >= 4 && s[..4].eq_ignore_ascii_case("0000") { &s[4..] } else { s };
    hex::decode(payload).map_err(|_| ())
}

pub mod tx;
pub mod fee;

#[cfg(feature = "rpc")]
pub mod rpc_ffi;

// Re-export the exact FFI symbols expected by KISRService / kisr.rs
pub use crate::tx::generator::{
    kaspa_tx_generator_new,
    kaspa_tx_generator_free,
    kaspa_tx_generator_clear,
    kaspa_tx_generator_set_change_address,
    kaspa_tx_generator_set_fee_rate,
    kaspa_tx_generator_add_utxo,
    kaspa_tx_generator_add_output,
    kaspa_tx_generator_set_payload_hex,
    kaspa_tx_generator_build_unsigned_safejson,
    kaspa_tx_generator_build_and_sign_safejson_with_type_and_algo,
};

pub use crate::fee::kaspa_estimate_fee_from_entries;

#[cfg(feature = "rpc")]
pub use crate::rpc_ffi::utxo::kaspa_rpc_get_utxos;

#[cfg(feature = "rpc")]
pub use crate::rpc_ffi::tx_submit::kaspa_rpc_submit_safe_json;

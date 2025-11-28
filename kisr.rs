// Minimal Kaspa FFI surface required by KISR flows.
//
// This module is intended to be used from a Rust crate that depends on
// the existing `kaspa_ffi` crate (with the `rpc` feature enabled).
//
// It re-exports only the small subset of C-ABI types and functions
// that are actually used by the Kurncy KISRService on iOS.

// Core error / memory helpers
pub use kaspa_ffi::{
    kaspa_last_error_message,
    kaspa_string_free,
};

// UTXO / output entry structs used when calling fee & tx generator FFI
pub use kaspa_ffi::{
    KaspaUtxoEntry,
    KaspaOutputEntry,
};

// Transaction generator FFI needed for KISR pre-sign and redemption flows
pub use kaspa_ffi::{
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

// Fee estimator used when assembling the redemption transaction
pub use kaspa_ffi::fee::kaspa_estimate_fee_from_entries;

// RPC helpers (require `kaspa_ffi` to be built with `rpc` feature)
#[cfg(feature = "rpc")]
pub use kaspa_ffi::rpc_ffi::utxo::kaspa_rpc_get_utxos;

#[cfg(feature = "rpc")]
pub use kaspa_ffi::rpc_ffi::tx_submit::kaspa_rpc_submit_safe_json;

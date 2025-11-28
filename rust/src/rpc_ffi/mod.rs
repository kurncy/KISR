use crate::*;
use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use std::sync::Arc;
use tokio::runtime::Runtime;
use kaspa_rpc_core::api::rpc::RpcApi;
use kaspa_wrpc_client::client::KaspaRpcClient as RpcClient;
use kaspa_wrpc_client::resolver::Resolver;
use workflow_rpc::encoding::Encoding;
use kaspa_consensus_core::network::{NetworkId, NetworkType};
use kaspa_rpc_core::model::RpcAddress;
use url::Url;
use core::str::FromStr;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use kaspa_wrpc_client::prelude::{Scope, VirtualDaaScoreChangedScope, BlockAddedScope, Notification, ListenerId, ChannelConnection, ChannelType};
use async_channel::Receiver as AsyncNotificationReceiver;

pub(super) struct GlobalRt;
impl GlobalRt {
        pub(super) fn get() -> &'static Runtime {
                static RT: OnceCell<Runtime> = OnceCell::new();
                RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().enable_all().worker_threads(2).build().expect("tokio rt"))
        }
}

pub(super) struct ClientInner {
        pub(super) client: RpcClient,
        pub(super) listener_id: ListenerId,
        pub(super) notification_receiver: AsyncNotificationReceiver<Notification>,
}

static CLIENTS: OnceCell<Mutex<Vec<Option<Arc<ClientInner>>>>> = OnceCell::new();
static FORWARDERS: OnceCell<Mutex<Vec<bool>>> = OnceCell::new();

pub(super) fn with_clients<F, R>(f: F) -> R where F: FnOnce(&Mutex<Vec<Option<Arc<ClientInner>>>>) -> R {
        let cell = CLIENTS.get_or_init(|| Mutex::new(Vec::new()));
        f(cell)
}

pub(super) fn store_client(c: Arc<ClientInner>) -> i32 {
        with_clients(|m| {
                let mut v = m.lock();
                for (idx, slot) in v.iter_mut().enumerate() {
                        if slot.is_none() { *slot = Some(c.clone()); return idx as i32; }
                }
                v.push(Some(c));
                (v.len() as i32) - 1
        })
}

pub(super) fn take_client(handle: i32) -> Option<Arc<ClientInner>> {
        with_clients(|m| {
                let mut v = m.lock();
                let idx = handle as usize;
                if idx >= v.len() { return None; }
                v[idx].take()
        })
}

pub(super) fn get_client(handle: i32) -> Option<Arc<ClientInner>> {
        with_clients(|m| {
                let v = m.lock();
                let idx = handle as usize;
                v.get(idx).and_then(|o| o.as_ref().cloned())
        })
}

pub(super) fn parse_network_id(network: &str) -> Option<NetworkId> {
        match network {
                "mainnet" => Some(NetworkId::new(NetworkType::Mainnet)),
                "testnet" => Some(NetworkId::with_suffix(NetworkType::Testnet, 10)),
                "testnet-10" => Some(NetworkId::with_suffix(NetworkType::Testnet, 10)),
                "simnet" => Some(NetworkId::new(NetworkType::Simnet)),
                "devnet" => Some(NetworkId::new(NetworkType::Devnet)),
                other => NetworkId::from_str(other).ok(),
        }
}

pub(super) fn with_forwarders<F, R>(f: F) -> R where F: FnOnce(&Mutex<Vec<bool>>) -> R {
        let cell = FORWARDERS.get_or_init(|| Mutex::new(Vec::new()));
        f(cell)
}

pub(super) fn ensure_forwarder_running(handle: i32, inner: Arc<ClientInner>) {
        let already_running = with_forwarders(|m| {
                let mut v = m.lock();
                let idx = handle as usize;
                if v.len() <= idx { v.resize(idx + 1, false); }
                let running = v[idx];
                if !running { v[idx] = true; }
                running
        });
        if already_running { return; }
        let _ = GlobalRt::get().spawn(async move {
                let rx = inner.notification_receiver.clone();
                loop {
                        match rx.recv().await {
                                Ok(notification) => {
                                        let mut maybe_json: Option<String> = None;
                                        match notification {
                                                Notification::BlockAdded(n) => {
                                                        let payload = serde_json::json!({"type": "blockAdded", "data": n});
                                                        maybe_json = Some(payload.to_string());
                                                }
                                                Notification::VirtualDaaScoreChanged(n) => {
                                                        let payload = serde_json::json!({"type": "virtualDaaScoreChanged", "data": n});
                                                        maybe_json = Some(payload.to_string());
                                                }
                                                _ => {}
                                        }
                                        if let Some(s) = maybe_json {
                                                with_watchers(|m| {
                                                        let map = m.lock();
                                                        let idx = handle as usize;
                                                        if let Some(Some(w)) = map.get(idx) {
                                                                let _ = w._out_tx.send(s);
                                                        }
                                                });
                                        }
                                }
                                Err(_) => { break; }
                        }
                }
        });
}

pub(super) struct Watcher {
        pub(super) shutdown_tx: Option<mpsc::UnboundedSender<()>>,
        pub(super) out_rx: mpsc::UnboundedReceiver<String>,
        pub(super) _out_tx: mpsc::UnboundedSender<String>,
        pub(super) _handle: JoinHandle<()>,
}

static WATCHERS: OnceCell<Mutex<Vec<Option<Watcher>>>> = OnceCell::new();

pub(super) fn with_watchers<F, R>(f: F) -> R where F: FnOnce(&Mutex<Vec<Option<Watcher>>>) -> R {
        let cell = WATCHERS.get_or_init(|| Mutex::new(Vec::new()));
        f(cell)
}

pub mod utxo;
pub mod tx_submit;

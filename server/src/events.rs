//! Environment config + whatsapp-rust Bot construction and event wiring.

use anyhow::{Context, Result};
use std::sync::Arc;
use tokio::sync::oneshot;
use whatsapp_rust::passkey::{AssertionRequest, CallbackAuthenticator, PasskeyError};
use whatsapp_rust::prelude::*;

use crate::state::{AppState, Event, PasskeyAnswer};

#[derive(Debug, Clone)]
pub struct Config {
    pub port: String,
    pub token: String,
    pub db_path: String,
    pub media_dir: String,
}

impl Config {
    pub fn from_env() -> Self {
        Self {
            port: std::env::var("PORT").unwrap_or_else(|_| "18770".into()),
            token: std::env::var("WHATSAPP_TOKEN").unwrap_or_default(),
            db_path: std::env::var("DB_PATH").unwrap_or_else(|_| "data/whatsapp.db".into()),
            media_dir: std::env::var("MEDIA_DIR").unwrap_or_else(|_| "data/media".into()),
        }
    }
}

/// Build the whatsapp-rust Bot and wire its events into the AppState, then
/// spawn it (runs in the background). Returns the handle and the client Arc.
pub async fn build_bot(
    cfg: Arc<Config>,
    state: AppState,
) -> Result<(BotHandle, Arc<Client>)> {
    // Ensure the DB parent dir exists before sqlite opens it.
    if let Some(parent) = std::path::Path::new(&cfg.db_path).parent() {
        std::fs::create_dir_all(parent).context("create data dir")?;
    }
    let store = SqliteStore::new(&cfg.db_path)
        .await
        .context("open sqlite store")?;

    let builder = Bot::builder()
        .with_backend(store)
        .on_qr_code({
            let tx = state.tx.clone();
            let st = state.clone();
            move |code, _timeout| {
                let tx = tx.clone();
                let st = st.clone();
                async move {
                    log::info!("QR code issued ({} chars)", code.len());
                    st.set_qr(&code);
                    let _ = tx.send(Event::Qr { qr: code });
                }
            }
        })
        .on_connected({
            let tx = state.tx.clone();
            let st = state.clone();
            move |client| {
                let tx = tx.clone();
                let st = st.clone();
                async move {
                    let phone = client.pn().map(|j| j.to_non_ad_string()).unwrap_or_default();
                    log::info!("connected as {}", phone);
                    st.set_phone(&phone);
                    st.set_qr("");
                    let _ = tx.send(Event::Linked { phone });
                    // History sync is requested automatically by whatsapp-rust
                    // on connect (skip_history_sync defaults to false).
                }
            }
        })
        .on_event_for(
            &[whatsapp_rust::types::events::EventKind::HistorySync],
            {
                let tx = state.tx.clone();
                let st = state.clone();
                move |event, _client| {
                    let tx = tx.clone();
                    let st = st.clone();
                    async move {
                        if let whatsapp_rust::types::events::Event::HistorySync(lazy) = &*event {
                            match lazy.get() {
                                Some(decoded) => crate::history::apply_history_sync(&st, decoded),
                                None => log::warn!("history sync blob unavailable"),
                            }
                            let _ = tx.send(Event::Chats);
                        }
                    }
                }
            },
        )
        .on_event_for(
            &[whatsapp_rust::types::events::EventKind::Receipt],
            {
                let tx = state.tx.clone();
                let st = state.clone();
                move |event, _client| {
                    let tx = tx.clone();
                    let st = st.clone();
                    async move {
                        if let whatsapp_rust::types::events::Event::Receipt(receipt) = &*event {
                            use whatsapp_rust::wacore::types::presence::ReceiptType;
                            let status = match receipt.r#type {
                                ReceiptType::Read | ReceiptType::ReadSelf => "read",
                                ReceiptType::Delivered => "delivered",
                                _ => return,
                            };
                            let chat = receipt.source.chat.to_non_ad_string();
                            for id in &receipt.message_ids {
                                st.store.set_status(&chat, id, status);
                            }
                            let _ = tx.send(Event::Receipt { chat });
                        }
                    }
                }
            },
        )
        .on_event_for(
            &[whatsapp_rust::types::events::EventKind::IncomingCall],
            {
                let st = state.clone();
                move |event, _client| {
                    let st = st.clone();
                    async move {
                        if let whatsapp_rust::types::events::Event::IncomingCall(call) = &*event {
                            crate::calls::on_incoming_call(&st, call).await;
                        }
                    }
                }
            },
        )
        .on_message({
            let tx = state.tx.clone();
            let st = state.clone();
            move |ctx| {
                let tx = tx.clone();
                let st = st.clone();
                async move {
                    crate::history::on_message(&st, &ctx).await;
                    let _ = tx.send(Event::Message {
                        chat: ctx.info.source.chat.to_non_ad_string(),
                    });
                }
            }
        })
        .on_logged_out({
            let tx = state.tx.clone();
            let st = state.clone();
            move |_info| {
                let tx = tx.clone();
                let st = st.clone();
                async move {
                    log::warn!("bot logged out");
                    st.set_phone("");
                    let _ = tx.send(Event::LoggedOut);
                }
            }
        })
        .on_event_for(&[whatsapp_rust::types::events::EventKind::PairPasskeyConfirmation], {
            let tx = state.tx.clone();
            move |event, _client| {
                let tx = tx.clone();
                async move {
                    if let whatsapp_rust::types::events::Event::PairPasskeyConfirmation(c) = &*event {
                        log::info!(
                            "passkey confirmation (skip_handoff_ux={})",
                            c.skip_handoff_ux
                        );
                        // The library auto-confirms re-links; a fresh link's code
                        // still needs to reach the app for the user to verify.
                        let _ = tx.send(crate::state::Event::PasskeyConfirmation {
                            code: c.code.clone(),
                        });
                    }
                }
            }
        })
        .on_event_for(&[whatsapp_rust::types::events::EventKind::PairPasskeyError], {
            let tx = state.tx.clone();
            move |event, _client| {
                let tx = tx.clone();
                async move {
                    if let whatsapp_rust::types::events::Event::PairPasskeyError(e) = &*event {
                        log::warn!("passkey error: {}", e.error);
                        let _ = tx.send(crate::state::Event::PasskeyError {
                            error: e.error.clone(),
                        });
                    }
                }
            }
        });

    let bot = builder.build().await.context("build bot")?;
    let handle = bot.spawn();
    let client = handle.client();

    // SHORTCAKE passkey gate: register a host-driven authenticator so the
    // library auto-drives the WebAuthn assertion step. The closure broadcasts a
    // passkey_request to the app, then awaits the app's assertion (or cancel)
    // via a oneshot installed on AppState.
    install_passkey_authenticator(&state, &client).await;

    Ok((handle, client))
}

/// How long the app has to answer a passkey (WebAuthn) request before the
/// ceremony is cancelled.
const PASSKEY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// Register a `CallbackAuthenticator` that defers the WebAuthn assertion to the
/// HarmonyOS app. The flow:
///  1. the library parses the server's `PublicKeyCredentialRequestOptions` and
///     calls `get_assertion` with an `AssertionRequest`;
///  2. we broadcast `Event::PasskeyRequest{options}` and store the raw options
///     (so `/passkey/request` can serve it if the app missed the WS event);
///  3. we install a oneshot the app resolves via `POST /passkey/assertion` (or
///     `/passkey/cancel`);
///  4. we await the answer (with a timeout) and hand the `Assertion` back.
///
/// With this registered, the library auto-drives the assertion and — on a
/// re-link (handoff proof) — auto-confirms without a verification code. A fresh
/// link still emits `Event::PairPasskeyConfirmation` for the app to display;
/// that is handled in the WS relay in `web.rs`.
pub async fn install_passkey_authenticator(state: &AppState, client: &Arc<Client>) {
    let auth = CallbackAuthenticator::new({
        let state = state.clone();
        move |request: AssertionRequest| {
            let state = state.clone();
            Box::pin(async move {
                let options = request.raw_options_json.clone();
                state.set_passkey_pending(options.clone());
                let _ = state.tx.send(Event::PasskeyRequest { options });

                let (tx, rx) = oneshot::channel();
                state.set_passkey_answer(tx);
                let answer = tokio::time::timeout(PASSKEY_TIMEOUT, rx).await;
                // If the timeout fired or the sender dropped (app vanished),
                // cancel the ceremony.
                match answer {
                    Ok(Ok(PasskeyAnswer::Assertion(assertion))) => Ok(assertion),
                    Ok(Ok(PasskeyAnswer::Cancelled)) => Err(PasskeyError::Cancelled),
                    Ok(Err(_)) | Err(_) => Err(PasskeyError::Cancelled),
                }
            })
        }
    });
    client
        .set_passkey_authenticator(Arc::new(auth))
        .await;
}

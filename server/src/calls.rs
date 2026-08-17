//! WhatsApp-native call slice: signaling + media relay.
//!
//! whatsapp-rust's `voip` module (feature `voip-mlow`) provides the call
//! state machine, DTLS/SCTP transport and the media channels. This module
//! exposes it over HTTP + WS for the app:
//!
//!   POST /call           {chat, video?}  → start an outgoing call
//!   POST /call/end       {callId}        → hang up
//!   POST /call/mute      {callId, muted}
//!   POST /call/camera    {callId, on}
//!   GET  /call/state     {callId?}       → current call state
//!   WS   /ws  push {type:"incoming_call", from, video}
//!              push {type:"call_state", callId, state}
//!
//! Media relay direction (from whatsapp-rust's trait impls):
//!   AudioSource  = async_channel::Receiver<Vec<i16>>  ← app mic frames
//!   AudioSink    = async_channel::Sender<Vec<i16>>    → app speaker frames
//!   VideoSource  = async_channel::Receiver<Vec<u8>>   ← app camera H.264 AUs
//!   VideoSink    = async_channel::Sender<VideoFrame>   → app display H.264 AUs
//!
//! The app sends/receives frames over the same WS as binary messages.

use anyhow::{Context, Result};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use whatsapp_rust::async_channel;
use whatsapp_rust::prelude::*;
use whatsapp_rust::voip::CallHandle;
use whatsapp_rust::voip::VideoFrame;
use whatsapp_rust::wacore::types::call::CallAction;
use whatsapp_rust::wacore::types::call::IncomingCall;

use crate::state::{AppState, Event};

/// One active call's server-side relay handles.
///
/// Media direction (whatsapp-rust trait impls):
///   AudioSource  = Receiver<Vec<i16>>  ← whatsapp reads (we push via mic_tx)
///   AudioSink    = Sender<Vec<i16>>    → whatsapp writes (we read peer_audio_rx)
///   VideoSource  = Receiver<Vec<u8>>   ← whatsapp reads (we push via cam_tx)
///   VideoSink    = Sender<VideoFrame>  → whatsapp writes (we read peer_video_rx)
#[derive(Clone)]
pub struct CallRelay {
    pub call_id: String,
    pub peer: String,
    pub video: bool,
    /// App mic frames → whatsapp-rust AudioSource (Sender end we push to).
    pub mic_tx: async_channel::Sender<Vec<i16>>,
    /// whatsapp-rust peer audio (AudioSink) → app speaker (read the Receiver).
    pub peer_audio_rx: async_channel::Receiver<Vec<i16>>,
    /// App camera H.264 AUs → whatsapp-rust VideoSource (Sender we push to).
    pub cam_tx: Option<async_channel::Sender<Vec<u8>>>,
    /// whatsapp-rust peer video (VideoSink) → app display (read the Receiver).
    pub peer_video_rx: Option<async_channel::Receiver<VideoFrame>>,
    /// The call handle — drives hangup/mute/video.
    pub handle: Option<Arc<CallHandle>>,
}

/// The call registry shared across the API handlers + event loop.
#[derive(Clone, Default)]
pub struct CallRegistry {
    inner: Arc<Mutex<HashMap<String, CallRelay>>>,
    /// Incoming calls awaiting accept/reject, keyed by call id.
    pending: Arc<Mutex<HashMap<String, PendingIncoming>>>,
}

/// An incoming call the app hasn't answered yet.
#[derive(Clone)]
pub struct PendingIncoming {
    pub call_id: String,
    pub from: String,
    pub video: bool,
    /// The whatsapp-rust IncomingCall, needed to accept/reject.
    pub incoming: Option<Box<IncomingCall>>,
}

impl CallRegistry {
    pub fn insert(&self, relay: CallRelay) {
        self.inner.lock().unwrap().insert(relay.call_id.clone(), relay);
    }
    pub fn get(&self, id: &str) -> Option<CallRelay> {
        self.inner.lock().unwrap().get(id).cloned()
    }
    pub fn remove(&self, id: &str) {
        self.inner.lock().unwrap().remove(id);
    }
    pub fn list(&self) -> Vec<(String, String, bool)> {
        self.inner
            .lock()
            .unwrap()
            .values()
            .map(|r| (r.call_id.clone(), r.peer.clone(), r.video))
            .collect()
    }
    pub fn insert_pending(&self, p: PendingIncoming) {
        self.pending.lock().unwrap().insert(p.call_id.clone(), p);
    }
    pub fn take_pending(&self, id: &str) -> Option<PendingIncoming> {
        self.pending.lock().unwrap().remove(id)
    }
    pub fn pending_list(&self) -> Vec<(String, String, bool)> {
        self.pending
            .lock()
            .unwrap()
            .values()
            .map(|p| (p.call_id.clone(), p.from.clone(), p.video))
            .collect()
    }
}

/// Extract the call id from an IncomingCall action (Offer/OfferNotice/etc.).
pub fn incoming_call_id(incoming: &IncomingCall) -> String {
    match &incoming.action {
        CallAction::Offer { call_id, .. }
        | CallAction::OfferNotice { call_id, .. }
        | CallAction::PreAccept { call_id, .. }
        | CallAction::Accept { call_id, .. }
        | CallAction::Reject { call_id, .. } => call_id.clone(),
        _ => incoming.stanza_id.clone(),
    }
}

/// Place an outgoing call to `chat` (JID). Returns the call id.
pub async fn start_call(
    client: &Arc<Client>,
    registry: &CallRegistry,
    chat: &str,
    video: bool,
) -> Result<String> {
    let peer: Jid = chat.parse().context("bad jid")?;
    let voip = client.voip();
    let mut builder = voip.call(&peer);

    // Media channels: mic_rx = whatsapp reads (we push via mic_tx);
    // peer_tx = whatsapp writes (we read peer_rx to relay to app).
    let (mic_tx, mic_rx) = async_channel::bounded(64);
    let (peer_tx, peer_rx) = async_channel::bounded(64);
    builder = builder.audio(mic_rx, peer_tx.clone());

    let (cam_tx, peer_video_rx) = if video {
        let (cam_tx, cam_rx) = async_channel::bounded(16);
        let (video_tx, video_rx) = async_channel::bounded(16);
        builder = builder.video(cam_rx, video_tx.clone());
        (Some(cam_tx), Some(video_rx))
    } else {
        (None, None)
    };

    let handle = builder.start().await.context("start call")?;
    let call_id = handle.call_id().to_string();
    registry.insert(CallRelay {
        call_id: call_id.clone(),
        peer: chat.to_string(),
        video,
        mic_tx,
        peer_audio_rx: peer_rx,
        cam_tx,
        peer_video_rx,
        handle: Some(Arc::new(handle)),
    });
    log::info!("call {} started to {}", call_id, chat);
    Ok(call_id)
}

/// Accept an incoming call.
pub async fn accept_call(
    client: &Arc<Client>,
    registry: &CallRegistry,
    incoming: &IncomingCall,
    video: bool,
) -> Result<String> {
    let voip = client.voip();
    let mut builder = voip.accept(incoming);
    let (mic_tx, mic_rx) = async_channel::bounded(64);
    let (peer_tx, peer_rx) = async_channel::bounded(64);
    builder = builder.audio(mic_rx, peer_tx.clone());

    let (cam_tx, peer_video_rx) = if video {
        let (cam_tx, cam_rx) = async_channel::bounded(16);
        let (video_tx, video_rx) = async_channel::bounded(16);
        builder = builder.video(cam_rx, video_tx.clone());
        (Some(cam_tx), Some(video_rx))
    } else {
        (None, None)
    };

    let handle = builder.start().await.context("accept call")?;
    let call_id = handle.call_id().to_string();
    registry.insert(CallRelay {
        call_id: call_id.clone(),
        peer: incoming.from.to_non_ad_string(),
        video,
        mic_tx,
        peer_audio_rx: peer_rx,
        cam_tx,
        peer_video_rx,
        handle: Some(Arc::new(handle)),
    });
    log::info!("call {} accepted from {}", call_id, incoming.from);
    Ok(call_id)
}

/// Reject an incoming call.
pub async fn reject_call(client: &Arc<Client>, incoming: &IncomingCall) -> Result<()> {
    client.voip().reject(incoming).await.context("reject call")
}

/// Hang up an active call (from its stored handle).
pub async fn hangup(registry: &CallRegistry, call_id: &str) -> Result<()> {
    if let Some(relay) = registry.get(call_id) {
        if let Some(handle) = relay.handle {
            handle.hangup().await;
        }
        registry.remove(call_id);
    }
    Ok(())
}

/// Mute/unmute an active call.
pub async fn set_muted(registry: &CallRegistry, call_id: &str, muted: bool) -> Result<()> {
    if let Some(relay) = registry.get(call_id) {
        if let Some(handle) = relay.handle {
            handle.set_muted(muted);
        }
    }
    Ok(())
}

/// Handle an incoming-call event from the bot: store it for accept/reject and
/// push it to the app over WS.
pub async fn on_incoming_call(state: &AppState, incoming: &IncomingCall) {
    let video = match &incoming.action {
        CallAction::Offer { is_video, .. } => *is_video,
        CallAction::OfferNotice { is_video, .. } => *is_video,
        _ => false,
    };
    let call_id = incoming_call_id(incoming);
    state.calls.insert_pending(PendingIncoming {
        call_id: call_id.clone(),
        from: incoming.from.to_non_ad_string(),
        video,
        incoming: Some(Box::new(incoming.clone())),
    });
    let _ = state.tx.send(Event::IncomingCall {
        call_id: call_id.clone(),
        from: incoming.from.to_non_ad_string(),
        video,
    });
    log::info!("incoming call {} from {}", call_id, incoming.from);
}

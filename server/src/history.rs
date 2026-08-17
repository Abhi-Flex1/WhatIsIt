//! History sync + live message handling: decode whatsapp-rust events into our
//! store and respond.

use whatsapp_rust::prelude::*;

use crate::state::AppState;
use crate::store::{MediaRef, Message};

/// Store a chat from history sync (name, unread, pinned, messages).
pub fn apply_history_sync(state: &AppState, history: &wa::HistorySync) {
    let mut count = 0usize;
    for conv in &history.conversations {
        let chat = conv.id.clone();
        if chat.is_empty() {
            continue;
        }
        let name = conv.name.clone().unwrap_or_default();
        let unread = conv.unread_count.unwrap_or(0) as usize;
        let pinned = conv.pinned.unwrap_or(0) > 0;
        if !name.is_empty() {
            state.store.set_name(&chat, &name);
        }
        state.store.upsert_chat_meta(&chat, &name, unread, pinned);

        for hs_msg in &conv.messages {
            let Some(web_msg) = hs_msg.message.as_option() else {
                continue;
            };
            if let Some(msg) = parse_web_message(&chat, web_msg) {
                state.store.upsert_message(msg);
                count += 1;
            }
        }
    }
    log::info!(
        "history sync applied ({} conversations, {} messages)",
        history.conversations.len(),
        count
    );
}
/// Convert a wa::WebMessageInfo (from history sync) into our Message.
fn parse_web_message(chat: &str, web: &wa::WebMessageInfo) -> Option<Message> {
    let msg = web.message.as_option()?;
    let key = web.key.as_option()?;
    let from_me = key.from_me.unwrap_or(false);
    let msg_id = key.id.clone().unwrap_or_default();
    if msg_id.is_empty() {
        return None;
    }
    let ts_secs = web.message_timestamp.unwrap_or(0) as i64;
    let text = extract_text(msg);
    let media = extract_media(msg, &msg_id);
    Some(Message {
        id: msg_id,
        chat: chat.to_string(),
        text,
        dir: if from_me { "out" } else { "in" }.to_string(),
        time: ts_secs * 1000,
        status: if from_me { "sent" } else { "" }.to_string(),
        reply_to: String::new(),
        reactions: Vec::new(),
        media,
        from_me,
    })
}

/// Best-effort text extraction from a wa::Message.
fn extract_text(msg: &wa::Message) -> String {
    if let Some(t) = &msg.conversation {
        return t.clone();
    }
    if let Some(et) = msg.extended_text_message.as_option() {
        if let Some(t) = &et.text {
            return t.clone();
        }
    }
    if let Some(im) = msg.image_message.as_option() {
        return im.caption.clone().unwrap_or_default();
    }
    if let Some(vm) = msg.video_message.as_option() {
        return vm.caption.clone().unwrap_or_default();
    }
    if let Some(dm) = msg.document_message.as_option() {
        return dm.caption.clone().unwrap_or_default();
    }
    String::new()
}

/// Detect media in a wa::Message and produce a MediaRef pointing at our cache.
fn extract_media(msg: &wa::Message, msg_id: &str) -> Option<MediaRef> {
    if let Some(im) = msg.image_message.as_option() {
        return Some(MediaRef {
            kind: "image".into(),
            url: format!("/media/{msg_id}/image"),
            thumb_url: format!("/media/{msg_id}/thumb"),
            caption: im.caption.clone().unwrap_or_default(),
            mime: im.mimetype.clone().unwrap_or_default(),
        });
    }
    if let Some(vm) = msg.video_message.as_option() {
        return Some(MediaRef {
            kind: "video".into(),
            url: format!("/media/{msg_id}/video"),
            thumb_url: format!("/media/{msg_id}/thumb"),
            caption: vm.caption.clone().unwrap_or_default(),
            mime: vm.mimetype.clone().unwrap_or_default(),
        });
    }
    if let Some(am) = msg.audio_message.as_option() {
        let kind = if am.ptt.unwrap_or(false) { "voice" } else { "audio" }.to_string();
        return Some(MediaRef {
            kind,
            url: format!("/media/{msg_id}/audio"),
            thumb_url: String::new(),
            caption: String::new(),
            mime: am.mimetype.clone().unwrap_or_default(),
        });
    }
    if let Some(dm) = msg.document_message.as_option() {
        return Some(MediaRef {
            kind: "document".into(),
            url: format!("/media/{msg_id}/document"),
            thumb_url: String::new(),
            caption: dm.caption.clone().unwrap_or_default(),
            mime: dm.mimetype.clone().unwrap_or_default(),
        });
    }
    if let Some(sm) = msg.sticker_message.as_option() {
        return Some(MediaRef {
            kind: "sticker".into(),
            url: format!("/media/{msg_id}/sticker"),
            thumb_url: String::new(),
            caption: String::new(),
            mime: sm.mimetype.clone().unwrap_or_default(),
        });
    }
    None
}

/// Live incoming/outgoing message from on_message.
pub async fn on_message(state: &AppState, ctx: &MessageContext) {
    let chat = ctx.info.source.chat.to_non_ad_string();
    let from_me = ctx.info.source.is_from_me;
    let msg_id = ctx.info.id.clone();
    let ts = ctx.info.timestamp.timestamp();
    let text = ctx.message.text_content().unwrap_or_default();
    let media = extract_media(&ctx.message, &msg_id);
    // Contact name for incoming DMs (use the sender's push name).
    if !from_me && ctx.info.source.sender.is_pn() && !ctx.info.push_name.is_empty() {
        state
            .store
            .set_name(&ctx.info.source.sender.to_non_ad_string(), &ctx.info.push_name);
    }
    let msg = Message {
        id: msg_id,
        chat: chat.clone(),
        text: text.to_string(),
        dir: if from_me { "out" } else { "in" }.to_string(),
        time: ts * 1000,
        status: if from_me { "sent" } else { "" }.to_string(),
        reply_to: String::new(),
        reactions: Vec::new(),
        media,
        from_me,
    };
    state.store.upsert_message(msg);
    if !from_me {
        state.store.bump_unread(&chat);
    }
    // Best-effort media download to the cache so /media can serve it.
    if let Err(e) = crate::media::maybe_cache_media(state, ctx).await {
        log::warn!("media cache failed: {e}");
    }
}

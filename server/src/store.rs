//! In-memory history store: chats, messages, contact/group names, pinned/unread
//! flags. Persisted as a JSON snapshot so the app's chat list survives restarts
//! (the whatsapp-rust SqliteStore holds the session; this holds what the app reads).

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use crate::events::Config;

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Message {
    pub id: String,
    pub chat: String,
    pub text: String,
    pub dir: String, // "in" | "out"
    pub time: i64,   // unix millis
    pub status: String, // "sent" | "delivered" | "read"
    #[serde(default)]
    pub reply_to: String,
    #[serde(default)]
    pub reactions: Vec<String>,
    #[serde(default)]
    pub media: Option<MediaRef>,
    #[serde(default)]
    pub from_me: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct MediaRef {
    pub kind: String, // image | video | audio | voice | document | sticker
    pub url: String,
    #[serde(default)]
    pub thumb_url: String,
    #[serde(default)]
    pub caption: String,
    #[serde(default)]
    pub mime: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct ChatSummary {
    pub id: String,
    pub name: String,
    pub preview: String,
    pub time: i64,
    pub unread: usize,
    pub pinned: bool,
    pub group: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
struct Conversation {
    messages: Vec<Message>,
    unread: usize,
    pinned: bool,
}

#[derive(Serialize, Deserialize, Default)]
struct Snapshot {
    chats: HashMap<String, Conversation>,
    names: HashMap<String, String>,
    phone: String,
}

pub struct HistoryStore {
    inner: Mutex<Inner>,
    snapshot_path: PathBuf,
}

#[derive(Default)]
struct Inner {
    chats: HashMap<String, Conversation>,
    names: HashMap<String, String>,
    phone: String,
}

const MAX_MESSAGES: usize = 2000;

impl HistoryStore {
    pub async fn new(cfg: Arc<Config>) -> Result<Self> {
        let snapshot_path = PathBuf::from(&cfg.db_path)
            .parent()
            .map(|p| p.join("history.json"))
            .unwrap_or_else(|| PathBuf::from("history.json"));
        let inner = Self::load(&snapshot_path).await;
        Ok(Self {
            inner: Mutex::new(inner),
            snapshot_path,
        })
    }

    async fn load(path: &std::path::Path) -> Inner {
        match tokio::fs::read(path).await {
            Ok(bytes) => match serde_json::from_slice::<Snapshot>(&bytes) {
                Ok(snap) => Inner {
                    chats: snap.chats,
                    names: snap.names,
                    phone: snap.phone,
                },
                Err(e) => {
                    log::warn!("history snapshot unreadable: {e}");
                    Inner::default()
                }
            },
            Err(_) => Inner::default(),
        }
    }

    pub async fn flush(&self) {
        let snap = {
            let inner = self.inner.lock().unwrap();
            Snapshot {
                chats: inner.chats.clone(),
                names: inner.names.clone(),
                phone: inner.phone.clone(),
            }
        };
        if let Some(dir) = self.snapshot_path.parent() {
            let _ = tokio::fs::create_dir_all(dir).await;
        }
        if let Ok(bytes) = serde_json::to_vec(&snap) {
            let _ = tokio::fs::write(&self.snapshot_path, bytes).await;
        }
    }

    // ---- setters (called from history sync / message events) ----

    pub fn set_name(&self, jid: &str, name: &str) {
        if !name.is_empty() {
            self.inner.lock().unwrap().names.insert(jid.to_string(), name.to_string());
        }
    }

    pub fn set_phone(&self, phone: &str) {
        self.inner.lock().unwrap().phone = phone.to_string();
    }

    pub fn upsert_chat_meta(&self, chat: &str, name: &str, unread: usize, pinned: bool) {
        let mut inner = self.inner.lock().unwrap();
        if !name.is_empty() {
            inner.names.insert(chat.to_string(), name.to_string());
        }
        let conv = inner.chats.entry(chat.to_string()).or_default();
        if unread > 0 {
            conv.unread = unread;
        }
        conv.pinned = pinned;
    }

    pub fn upsert_message(&self, msg: Message) {
        let mut inner = self.inner.lock().unwrap();
        let conv = inner.chats.entry(msg.chat.clone()).or_default();
        if let Some(existing) = conv.messages.iter_mut().find(|m| m.id == msg.id) {
            if !msg.status.is_empty() {
                existing.status = msg.status.clone();
            }
            if !msg.text.is_empty() {
                existing.text = msg.text.clone();
            }
            if let Some(media) = &msg.media {
                existing.media = Some(media.clone());
            }
            return;
        }
        conv.messages.push(msg);
        if conv.messages.len() > MAX_MESSAGES {
            let overflow = conv.messages.len() - MAX_MESSAGES;
            conv.messages.drain(0..overflow);
        }
    }

    pub fn bump_unread(&self, chat: &str) {
        let mut inner = self.inner.lock().unwrap();
        let conv = inner.chats.entry(chat.to_string()).or_default();
        conv.unread += 1;
    }

    pub fn mark_read(&self, chat: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(conv) = inner.chats.get_mut(chat) {
            conv.unread = 0;
        }
    }

    pub fn set_status(&self, chat: &str, id: &str, status: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(conv) = inner.chats.get_mut(chat) {
            if let Some(m) = conv.messages.iter_mut().find(|m| m.id == id) {
                m.status = status.to_string();
            }
        }
    }

    pub fn add_reaction(&self, chat: &str, id: &str, reaction: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(conv) = inner.chats.get_mut(chat) {
            if let Some(m) = conv.messages.iter_mut().find(|m| m.id == id) {
                if reaction.is_empty() {
                    m.reactions.clear();
                } else {
                    m.reactions = vec![reaction.to_string()];
                }
            }
        }
    }

    // ---- getters ----

    pub fn name_for(&self, jid: &str) -> String {
        self.inner
            .lock()
            .unwrap()
            .names
            .get(jid)
            .cloned()
            .unwrap_or_else(|| jid.to_string())
    }

    pub fn phone(&self) -> String {
        self.inner.lock().unwrap().phone.clone()
    }

    /// Chat list sorted by last message time (pinned first).
    pub fn chats(&self) -> Vec<ChatSummary> {
        let inner = self.inner.lock().unwrap();
        let mut out: Vec<ChatSummary> = inner
            .chats
            .iter()
            .map(|(jid, conv)| {
                let last = conv.messages.last();
                ChatSummary {
                    id: jid.clone(),
                    name: inner
                        .names
                        .get(jid)
                        .cloned()
                        .unwrap_or_else(|| jid.clone()),
                    preview: last.map(|m| {
                        if !m.text.is_empty() {
                            m.text.clone()
                        } else if let Some(media) = &m.media {
                            format!("📎 {}", media.kind)
                        } else {
                            String::new()
                        }
                    }).unwrap_or_default(),
                    time: last.map(|m| m.time).unwrap_or(0),
                    unread: conv.unread,
                    pinned: conv.pinned,
                    group: jid.ends_with("@g.us"),
                }
            })
            .collect();
        out.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then(b.time.cmp(&a.time))
        });
        out
    }

    pub fn messages(&self, chat: &str, limit: usize) -> Vec<Message> {
        let inner = self.inner.lock().unwrap();
        let conv = match inner.chats.get(chat) {
            Some(c) => c,
            None => return Vec::new(),
        };
        let msgs = conv.messages.clone();
        let start = msgs.len().saturating_sub(limit);
        msgs[start..].to_vec()
    }

    pub fn unread_total(&self) -> usize {
        self.inner.lock().unwrap().chats.values().map(|c| c.unread).sum()
    }

    pub fn latest_unread(&self) -> Option<(String, String)> {
        let inner = self.inner.lock().unwrap();
        inner
            .chats
            .iter()
            .filter(|(_, c)| c.unread > 0)
            .filter_map(|(jid, c)| c.messages.last().map(|m| (jid.clone(), m.time, c.unread)))
            .max_by_key(|(_, t, _)| *t)
            .map(|(jid, _, _)| {
                let name = inner.names.get(&jid).cloned().unwrap_or_else(|| jid.clone());
                (jid, name)
            })
    }
}


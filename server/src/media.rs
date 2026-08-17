//! Media handling: download incoming media to a cache, serve it, upload+send
//! outbound media, and reactions.

use anyhow::{Context, Result};
use axum::response::{IntoResponse, Response};
use std::path::PathBuf;
use whatsapp_rust::prelude::*;
use whatsapp_rust::wacore::download::MediaType;
use whatsapp_rust::upload::UploadOptions;

use crate::web::ApiState;

fn media_path(media_dir: &str, id: &str, kind: &str) -> PathBuf {
    let ext = match kind {
        "image" => "img",
        "video" => "vid",
        "audio" | "voice" => "aud",
        "document" => "doc",
        "sticker" => "stk",
        "thumb" => "thm",
        _ => "bin",
    };
    PathBuf::from(media_dir).join(format!("{id}.{ext}"))
}

/// On a live message, download the media to the cache if it has an attachment.
pub async fn maybe_cache_media(state: &crate::state::AppState, ctx: &MessageContext) -> Result<()> {
    let base = ctx.message.get_base_message();
    let (kind, downloadable): (&str, &dyn whatsapp_rust::download::Downloadable) =
        if let Some(img) = base.image_message.as_option() {
            ("image", img)
        } else if let Some(vid) = base.video_message.as_option() {
            ("video", vid)
        } else if let Some(aud) = base.audio_message.as_option() {
            ("audio", aud)
        } else if let Some(doc) = base.document_message.as_option() {
            ("document", doc)
        } else {
            return Ok(()); // no media
        };
    let client = ctx.client.clone();
    let bytes = client.download(downloadable).await?;
    let path = media_path(&state.cfg.media_dir, &ctx.info.id, kind);
    if let Some(dir) = path.parent() {
        tokio::fs::create_dir_all(dir).await?;
    }
    tokio::fs::write(&path, bytes).await?;
    Ok(())
}

/// Serve a cached media file.
pub async fn serve_media(api: &ApiState, id: &str, kind: &str) -> Response {
    let path = media_path(&api.state.cfg.media_dir, id, kind);
    match tokio::fs::read(&path).await {
        Ok(bytes) => {
            let mime = match kind {
                "image" => "image/jpeg",
                "video" => "video/mp4",
                "audio" | "voice" => "audio/ogg",
                "sticker" => "image/webp",
                "thumb" => "image/jpeg",
                _ => "application/octet-stream",
            };
            (
                axum::http::StatusCode::OK,
                [(axum::http::header::CONTENT_TYPE, mime)],
                bytes,
            )
                .into_response()
        }
        Err(_) => (
            axum::http::StatusCode::NOT_FOUND,
            axum::Json(serde_json::json!({ "error": "media not cached yet" })),
        )
            .into_response(),
    }
}

/// Upload + send a media file from a multipart upload.
pub async fn handle_send_media(
    api: &ApiState,
    multipart: &mut axum::extract::Multipart,
) -> Result<String> {
    let mut chat = String::new();
    let mut caption = String::new();
    let mut filename = String::new();
    let mut file_bytes: Option<Vec<u8>> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .context("read multipart field")?
    {
        match field.name() {
            Some("chat") => chat = field.text().await.context("read chat")?,
            Some("caption") => caption = field.text().await.context("read caption")?,
            Some("file") => {
                filename = field
                    .file_name()
                    .map(|s| s.to_string())
                    .unwrap_or_else(|| "file".into());
                file_bytes = Some(field.bytes().await.context("read file")?.to_vec());
            }
            _ => {}
        }
    }
    if chat.is_empty() {
        anyhow::bail!("chat required");
    }
    let bytes = file_bytes.ok_or_else(|| anyhow::anyhow!("file required"))?;

    let jid: Jid = chat.parse().context("bad jid")?;
    let client = api.client.clone();

    let media_type = match filename
        .rsplit('.')
        .next()
        .map(|e| e.to_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") | Some("png") | Some("gif") | Some("webp") => MediaType::Image,
        Some("mp4") | Some("mov") | Some("mkv") | Some("3gp") => MediaType::Video,
        Some("mp3") | Some("m4a") | Some("ogg") | Some("opus") | Some("wav") => MediaType::Audio,
        _ => MediaType::Document,
    };

    let up = client
        .upload(bytes.clone(), media_type, UploadOptions::default())
        .await
        .context("upload")?;

    // Build the media message with the upload handle attached.
    let msg = match media_type {
        MediaType::Image => wa::Message {
            image_message: wa::message::ImageMessage {
                url: Some(up.url),
                mimetype: Some("image/jpeg".into()),
                caption: Some(caption.clone()),
                file_length: Some(up.file_length),
                ..Default::default()
            }
            .into(),
            ..Default::default()
        },
        MediaType::Video => wa::Message {
            video_message: wa::message::VideoMessage {
                url: Some(up.url),
                mimetype: Some("video/mp4".into()),
                caption: Some(caption.clone()),
                file_length: Some(up.file_length),
                ..Default::default()
            }
            .into(),
            ..Default::default()
        },
        MediaType::Audio => wa::Message {
            audio_message: wa::message::AudioMessage {
                url: Some(up.url),
                mimetype: Some("audio/ogg".into()),
                file_length: Some(up.file_length),
                ..Default::default()
            }
            .into(),
            ..Default::default()
        },
        _ => wa::Message {
            document_message: wa::message::DocumentMessage {
                url: Some(up.url),
                mimetype: Some("application/octet-stream".into()),
                file_name: Some(filename.clone()),
                caption: Some(caption.clone()),
                file_length: Some(up.file_length),
                ..Default::default()
            }
            .into(),
            ..Default::default()
        },
    };

    let sent = client.send_message(jid, msg).await?;
    Ok(sent.message_id)
}

/// Send (or remove with "") a reaction emoji on a message.
pub async fn send_reaction(api: &ApiState, jid: Jid, message_id: &str, emoji: &str) -> Result<()> {
    let target_key = wa::MessageKey {
        remote_jid: Some(jid.to_string()),
        from_me: Some(true),
        id: Some(message_id.to_string()),
        participant: None,
    };
    api.client.send_reaction(jid, target_key, emoji).await?;
    Ok(())
}

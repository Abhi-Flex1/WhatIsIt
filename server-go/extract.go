package server

import (
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types/events"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
)

// mediaDownloadable returns the DownloadableMessage for a media message, if any.
func mediaDownloadable(m *waE2E.Message) (whatsmeow.DownloadableMessage, bool) {
	switch {
	case m.GetImageMessage() != nil:
		return m.GetImageMessage(), true
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage(), true
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage(), true
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage(), true
	case m.GetStickerMessage() != nil:
		return m.GetStickerMessage(), true
	}
	return nil, false
}

// extractMessage fills the text/media/reply fields of msg from a whatsmeow
// message event, matching the Rust server's Message extraction.
func extractMessage(e *events.Message, msg *Message) {
	conv := e.Message.GetConversation()
	if conv != "" {
		msg.Text = conv
		return
	}
	// Extended text.
	if ext := e.Message.GetExtendedTextMessage(); ext != nil {
		msg.Text = ext.GetText()
		if ext.GetContextInfo() != nil {
			msg.ReplyTo = ext.GetContextInfo().GetStanzaID()
		}
		return
	}
	// Media messages: image, video, audio, voice, document, sticker.
	media := mediaFromMessage(e.Message)
	if media != nil {
		msg.Media = media
		msg.Text = media.Caption
		return
	}
	// Reaction messages.
	if reac := e.Message.GetReactionMessage(); reac != nil {
		msg.Reactions = []string{reac.GetText()}
		return
	}
}

// mediaFromMessage extracts a MediaRef from a message's media content, or nil.
func mediaFromMessage(m *waE2E.Message) *MediaRef {
	switch {
	case m.GetImageMessage() != nil:
		img := m.GetImageMessage()
		thumb := ""
		if img.GetJPEGThumbnail() != nil || img.GetThumbnailDirectPath() != "" {
			thumb = img.GetThumbnailDirectPath()
		}
		return &MediaRef{
			Kind:     "image",
			URL:      img.GetURL(),
			ThumbURL: thumb,
			Caption:  img.GetCaption(),
			Mime:     img.GetMimetype(),
		}
	case m.GetVideoMessage() != nil:
		v := m.GetVideoMessage()
		return &MediaRef{Kind: "video", URL: v.GetURL(), Caption: v.GetCaption(), Mime: v.GetMimetype()}
	case m.GetAudioMessage() != nil:
		a := m.GetAudioMessage()
		kind := "audio"
		if a.GetPTT() {
			kind = "voice"
		}
		return &MediaRef{Kind: kind, URL: a.GetURL(), Mime: a.GetMimetype()}
	case m.GetDocumentMessage() != nil:
		d := m.GetDocumentMessage()
		return &MediaRef{Kind: "document", URL: d.GetURL(), Caption: d.GetCaption(), Mime: d.GetMimetype()}
	case m.GetStickerMessage() != nil:
		s := m.GetStickerMessage()
		return &MediaRef{Kind: "sticker", URL: s.GetURL(), Mime: s.GetMimetype()}
	}
	return nil
}

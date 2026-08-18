package server

import (
	"log"

	"go.mau.fi/whatsmeow/proto/waE2E"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

// onHistorySync backfills the store from a WhatsApp history sync blob. The
// linked phone pushes recent chats shortly after pairing; whatsmeow downloads
// the blob and dispatches events.HistorySync (mirrors the Rust server's
// history.rs::apply_history_sync, which the Go port was previously missing).
func (wc *WAClient) onHistorySync(e *events.HistorySync) {
	if e.Data == nil {
		log.Printf("history sync: no data")
		return
	}
	count := 0
	convs := e.Data.GetConversations()
	for _, conv := range convs {
		chat := conv.GetID()
		if chat == "" {
			continue
		}
		name := conv.GetName()
		unread := int(conv.GetUnreadCount())
		pinned := conv.GetPinned() > 0
		if name != "" {
			wc.state.Store.SetName(chat, name)
		}
		wc.state.Store.UpsertChatMeta(chat, name, unread, pinned)
		for _, hsMsg := range conv.GetMessages() {
			web := hsMsg.GetMessage()
			if web == nil {
				continue
			}
			// Status posts ride on the status@broadcast chat; surface the
			// latest per contact in the Status tab (history syncs include
			// them on some phone setups even though they are ephemeral).
			if chat == types.StatusBroadcastJID.String() {
				if entry := statusFromWebMessage(wc, web); entry != nil {
					wc.state.Store.AddStatusIfNewer(*entry)
				}
			}
			if msg := parseWebMessage(chat, web); msg != nil {
				wc.state.Store.UpsertMessage(*msg)
				count++
			}
		}
	}
	// Persist the backfilled history so a server restart keeps it.
	wc.state.Store.Flush()
	log.Printf("history sync applied (%d conversations, %d messages)", len(convs), count)
	wc.state.Bus.Publish(EvChats())
}

// parseWebMessage converts a history-sync WebMessageInfo into our Message
// (same merge rules as history.rs::parse_web_message).
func parseWebMessage(chat string, web *waWeb.WebMessageInfo) *Message {
	msg := web.GetMessage()
	key := web.GetKey()
	if msg == nil || key == nil {
		return nil
	}
	fromMe := key.GetFromMe()
	msgID := key.GetID()
	if msgID == "" {
		return nil
	}
	text, replyTo, media := extractWebFields(msg)
	dir := "in"
	status := ""
	if fromMe {
		dir = "out"
		status = "sent"
	}
	return &Message{
		ID:        msgID,
		Chat:      chat,
		Text:      text,
		Dir:       dir,
		Time:      int64(web.GetMessageTimestamp()) * 1000,
		Status:    status,
		ReplyTo:   replyTo,
		Reactions: []string{},
		Media:     media,
		FromMe:    fromMe,
	}
}

// extractWebFields pulls text/reply/media from a raw waE2E.Message (history
// sync path; reactions ride on separate stubs, so they are skipped here).
func extractWebFields(m *waE2E.Message) (text, replyTo string, media *MediaRef) {
	if conv := m.GetConversation(); conv != "" {
		return conv, "", nil
	}
	if ext := m.GetExtendedTextMessage(); ext != nil {
		reply := ""
		if ci := ext.GetContextInfo(); ci != nil {
			reply = ci.GetStanzaID()
		}
		return ext.GetText(), reply, nil
	}
	if md := mediaFromMessage(m); md != nil {
		return md.Caption, "", md
	}
	return "", "", nil
}

// statusFromWebMessage builds a StatusEntry from a status@broadcast message in
// a history sync. Self-posts and messages without a sender are skipped.
func statusFromWebMessage(wc *WAClient, web *waWeb.WebMessageInfo) *StatusEntry {
	key := web.GetKey()
	msg := web.GetMessage()
	if key == nil || msg == nil || key.GetFromMe() {
		return nil
	}
	sender := key.GetParticipant()
	if sender == "" {
		return nil
	}
	text, _, media := extractWebFields(msg)
	kind := "text"
	if media != nil {
		kind = media.Kind
	}
	name := sender
	if jid, err := types.ParseJID(sender); err == nil {
		name = wc.contactName(jid)
	}
	return &StatusEntry{
		Sender: sender,
		Name:   name,
		Text:   text,
		Kind:   kind,
		Time:   int64(web.GetMessageTimestamp()) * 1000,
		Media:  media,
	}
}
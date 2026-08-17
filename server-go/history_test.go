package server

import (
	"path/filepath"
	"testing"

	"go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

// history_test validates the history-sync backfill (history.go) against the
// store, mirroring the Rust server's history.rs::apply_history_sync.

func testHistoryState(t *testing.T) (*AppState, *WAClient) {
	t.Helper()
	// A real temp file path (not ":memory:") so Flush() writes history.json
	// into the test dir instead of the repo working directory.
	cfg := &Config{Token: "", Port: "0", Host: "127.0.0.1", DBPath: filepath.Join(t.TempDir(), "test.db"), MediaDir: t.TempDir()}
	state, err := NewAppState(cfg)
	if err != nil {
		t.Fatalf("NewAppState: %v", err)
	}
	return state, &WAClient{state: state}
}

// TestHistorySyncBackfills: a whatsmeow HistorySync blob is applied into the
// store (chats + messages) and a "chats" event is broadcast on the bus.
func TestHistorySyncBackfills(t *testing.T) {
	state, wc := testHistoryState(t)
	ev := &events.HistorySync{Data: &waHistorySync.HistorySync{
		SyncType: waHistorySync.HistorySync_RECENT.Enum(),
		Conversations: []*waHistorySync.Conversation{
			{
				ID:          proto.String("393512345678@s.whatsapp.net"),
				Name:        proto.String("Alice"),
				UnreadCount: proto.Uint32(3),
				Pinned:      proto.Uint32(1),
				Messages: []*waHistorySync.HistorySyncMsg{
					{Message: &waWeb.WebMessageInfo{
						Key: &waCommon.MessageKey{
							ID:        proto.String("IN1"),
							FromMe:    proto.Bool(false),
							RemoteJID: proto.String("393512345678@s.whatsapp.net"),
						},
						Message:         &waE2E.Message{Conversation: proto.String("hey from history")},
						MessageTimestamp: proto.Uint64(1700000000),
					}},
					{Message: &waWeb.WebMessageInfo{
						Key: &waCommon.MessageKey{
							ID:        proto.String("OUT1"),
							FromMe:    proto.Bool(true),
							RemoteJID: proto.String("393512345678@s.whatsapp.net"),
						},
						Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
							Text:        proto.String("reply text"),
							ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String("IN1")},
						}},
						MessageTimestamp: proto.Uint64(1700000060),
					}},
				},
			},
		},
	}}

	sub := state.Bus.Subscribe()
	wc.onHistorySync(ev)
	select {
	case got := <-sub:
		if got.Type != "chats" {
			t.Fatalf("bus event type = %q, want chats", got.Type)
		}
	default:
		t.Fatal("no chats event broadcast after history sync")
	}

	chats := state.Store.Chats()
	if len(chats) != 1 {
		t.Fatalf("chats = %d, want 1", len(chats))
	}
	c := chats[0]
	if c.Name != "Alice" {
		t.Errorf("chat name = %q, want Alice", c.Name)
	}
	if c.Unread != 3 {
		t.Errorf("chat unread = %d, want 3", c.Unread)
	}
	if !c.Pinned {
		t.Errorf("chat pinned = false, want true")
	}
	if c.Preview != "reply text" {
		t.Errorf("chat preview = %q, want 'reply text' (last message)", c.Preview)
	}

	msgs := state.Store.Messages("393512345678@s.whatsapp.net", 50)
	if len(msgs) != 2 {
		t.Fatalf("messages = %d, want 2", len(msgs))
	}
	m0, m1 := msgs[0], msgs[1]
	if m0.ID != "IN1" || m0.Dir != "in" || m0.Text != "hey from history" {
		t.Errorf("m0 = %+v, want inbound 'hey from history'", m0)
	}
	if m0.Time != 1700000000000 {
		t.Errorf("m0 time = %d, want 1700000000000 (secs*1000)", m0.Time)
	}
	if m1.ID != "OUT1" || m1.Dir != "out" || m1.Status != "sent" {
		t.Errorf("m1 = %+v, want outbound 'sent'", m1)
	}
	if m1.ReplyTo != "IN1" {
		t.Errorf("m1 reply_to = %q, want IN1", m1.ReplyTo)
	}
}

// TestHistorySyncMedia: a media message in history sync gets a MediaRef and the
// caption as its text.
func TestHistorySyncMedia(t *testing.T) {
	state, wc := testHistoryState(t)
	ev := &events.HistorySync{Data: &waHistorySync.HistorySync{
		SyncType: waHistorySync.HistorySync_RECENT.Enum(),
		Conversations: []*waHistorySync.Conversation{
			{
				ID: proto.String("19998887777@s.whatsapp.net"),
				Messages: []*waHistorySync.HistorySyncMsg{
					{Message: &waWeb.WebMessageInfo{
						Key: &waCommon.MessageKey{
							ID:     proto.String("IMG1"),
							FromMe: proto.Bool(false),
						},
						Message: &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
							URL:      proto.String("https://cdn.example/img"),
							Mimetype: proto.String("image/jpeg"),
							Caption:  proto.String("look"),
						}},
						MessageTimestamp: proto.Uint64(1700000100),
					}},
				},
			},
		},
	}}
	wc.onHistorySync(ev)
	msgs := state.Store.Messages("19998887777@s.whatsapp.net", 10)
	if len(msgs) != 1 {
		t.Fatalf("messages = %d, want 1", len(msgs))
	}
	m := msgs[0]
	if m.Media == nil || m.Media.Kind != "image" || m.Media.Caption != "look" {
		t.Fatalf("media = %+v, want image MediaRef", m.Media)
	}
	if m.Text != "look" {
		t.Errorf("text = %q, want caption 'look'", m.Text)
	}
}

// TestHistorySyncEmptyChatID: conversations without an ID are skipped.
func TestHistorySyncEmptyChatID(t *testing.T) {
	state, wc := testHistoryState(t)
	ev := &events.HistorySync{Data: &waHistorySync.HistorySync{
		SyncType: waHistorySync.HistorySync_RECENT.Enum(),
		Conversations: []*waHistorySync.Conversation{
			{ID: proto.String("")},
			{ID: proto.String("39355556666@s.whatsapp.net"), Name: proto.String("Bob")},
		},
	}}
	wc.onHistorySync(ev)
	chats := state.Store.Chats()
	if len(chats) != 1 {
		t.Fatalf("chats = %d, want 1 (empty-ID conversation skipped)", len(chats))
	}
	if chats[0].Name != "Bob" {
		t.Errorf("chat name = %q, want Bob", chats[0].Name)
	}
}
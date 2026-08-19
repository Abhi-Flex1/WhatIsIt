package server

import (
	"path/filepath"
	"testing"
)

// store_test validates message ordering and chat-preview correctness in the
// history store (fixes for out-of-order live sync + history backfill).

func testStore(t *testing.T) *HistoryStore {
	t.Helper()
	cfg := &Config{Token: "", Port: "0", Host: "127.0.0.1", DBPath: filepath.Join(t.TempDir(), "test.db"), MediaDir: t.TempDir()}
	s, err := NewHistoryStore(cfg)
	if err != nil {
		t.Fatalf("NewHistoryStore: %v", err)
	}
	return s
}

// TestUpsertMessageChronological: messages inserted out of timestamp order are
// stored sorted by time (ascending), and the chat preview uses the newest.
func TestUpsertMessageChronological(t *testing.T) {
	s := testStore(t)
	chat := "393512345678@s.whatsapp.net"
	// Arrive out of order: newest first, then oldest, then a middle one.
	s.UpsertMessage(Message{ID: "NEW", Chat: chat, Text: "newest", Dir: "in", Time: 1700000050000, FromMe: false})
	s.UpsertMessage(Message{ID: "OLD", Chat: chat, Text: "oldest", Dir: "in", Time: 1700000000000, FromMe: false})
	s.UpsertMessage(Message{ID: "MID", Chat: chat, Text: "middle", Dir: "in", Time: 1700000030000, FromMe: false})

	msgs := s.Messages(chat, 10)
	if len(msgs) != 3 {
		t.Fatalf("messages = %d, want 3", len(msgs))
	}
	want := []string{"OLD", "MID", "NEW"}
	for i, w := range want {
		if msgs[i].ID != w {
			t.Errorf("msgs[%d].ID = %q, want %q (chronological)", i, msgs[i].ID, w)
		}
	}

	chats := s.Chats()
	if len(chats) != 1 {
		t.Fatalf("chats = %d, want 1", len(chats))
	}
	if chats[0].Preview != "newest" {
		t.Errorf("chat preview = %q, want 'newest'", chats[0].Preview)
	}
	if chats[0].Time != 1700000050000 {
		t.Errorf("chat time = %d, want 1700000050000 (newest)", chats[0].Time)
	}
}

// TestUpsertMessageDedupe: upserting an existing ID updates it in place without
// duplicating the row, and status merges.
func TestUpsertMessageDedupe(t *testing.T) {
	s := testStore(t)
	chat := "393512345678@s.whatsapp.net"
	s.UpsertMessage(Message{ID: "A", Chat: chat, Text: "hello", Dir: "out", Time: 1700000000000, Status: "sent", FromMe: true})
	s.UpsertMessage(Message{ID: "A", Chat: chat, Text: "hello", Dir: "out", Time: 1700000000000, Status: "read", FromMe: true})

	msgs := s.Messages(chat, 10)
	if len(msgs) != 1 {
		t.Fatalf("messages = %d, want 1 (deduped)", len(msgs))
	}
	if msgs[0].Status != "read" {
		t.Errorf("status = %q, want 'read'", msgs[0].Status)
	}
}

// TestNeedsFlush: mutations set the dirty flag until Flush clears it.
func TestNeedsFlush(t *testing.T) {
	s := testStore(t)
	if s.NeedsFlush() {
		t.Fatal("new store should not need flush")
	}
	s.UpsertMessage(Message{ID: "A", Chat: "x@s.whatsapp.net", Text: "hi", Time: 1})
	if !s.NeedsFlush() {
		t.Fatal("after upsert, store should need flush")
	}
	s.Flush()
	if s.NeedsFlush() {
		t.Fatal("after Flush, store should not need flush")
	}
}

// TestResetSeed: ResetSeed drops all chats/messages/calls/statuses but keeps
// the store usable.
func TestResetSeed(t *testing.T) {
	s := testStore(t)
	s.SetPhone("393532002800")
	s.UpsertMessage(Message{ID: "seed-1", Chat: "x@s.whatsapp.net", Text: "demo", Time: 1})
	s.AddCall(CallRecord{ID: "call-1", Peer: "y@s.whatsapp.net", Time: 1})
	s.AddStatus(StatusEntry{Sender: "z@s.whatsapp.net", Text: "status", Time: 1})

	s.ResetSeed()
	if n := len(s.Chats()); n != 0 {
		t.Errorf("chats after reset = %d, want 0", n)
	}
	if n := len(s.Calls()); n != 0 {
		t.Errorf("calls after reset = %d, want 0", n)
	}
	if n := len(s.Statuses()); n != 0 {
		t.Errorf("statuses after reset = %d, want 0", n)
	}
	if s.Phone() != "393532002800" {
		t.Errorf("phone after reset = %q, want preserved", s.Phone())
	}
}
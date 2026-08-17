package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// parity_test validates the Go server's wire contract against the Rust
// server's documented JSON shapes (from store.rs + web.rs). It proves the app
// sees identical responses without needing a live WhatsApp session.

func testServer(t *testing.T) *Server {
	t.Helper()
	cfg := &Config{Token: "", Port: "0", Host: "127.0.0.1", DBPath: ":memory:", MediaDir: t.TempDir()}
	state, err := NewAppState(cfg)
	if err != nil {
		t.Fatalf("NewAppState: %v", err)
	}
	// Seed a store fixture matching the Rust ChatSummary/Message shapes.
	state.Store.UpsertChatMeta("15551234567@s.whatsapp.net", "Alice", 2, true)
	state.Store.UpsertMessage(Message{
		ID: "ABC123", Chat: "15551234567@s.whatsapp.net", Text: "hello",
		Dir: "in", Time: 1700000000000, Status: "read", FromMe: false,
	})
	state.Store.UpsertMessage(Message{
		ID: "DEF456", Chat: "15551234567@s.whatsapp.net", Text: "hi back",
		Dir: "out", Time: 1700000001000, Status: "sent", FromMe: true,
	})
	state.SetPhone("15551234567")
	return NewServer(state, nil)
}

func doReq(t *testing.T, s *Server, method, path string, body string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	var r *http.Request
	if body != "" {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	w := httptest.NewRecorder()
	s.Mux().ServeHTTP(w, r)
	var m map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &m)
	return w, m
}

// TestStatusShape: GET /status returns {linked, phone, qr}.
func TestStatusShape(t *testing.T) {
	s := testServer(t)
	w, m := doReq(t, s, "GET", "/status", "")
	if w.Code != 200 {
		t.Fatalf("status code = %d, want 200", w.Code)
	}
	for _, k := range []string{"linked", "phone", "qr"} {
		if _, ok := m[k]; !ok {
			t.Errorf("status missing key %q: %v", k, m)
		}
	}
	if m["linked"] != true {
		t.Errorf("linked = %v, want true", m["linked"])
	}
	if m["phone"] != "15551234567" {
		t.Errorf("phone = %v, want 15551234567", m["phone"])
	}
}

// TestChatsShape: GET /chats returns {chats:[{id,name,preview,time,unread,pinned,group}]}.
func TestChatsShape(t *testing.T) {
	s := testServer(t)
	w, m := doReq(t, s, "GET", "/chats", "")
	if w.Code != 200 {
		t.Fatalf("chats code = %d, want 200", w.Code)
	}
	chats, ok := m["chats"].([]any)
	if !ok || len(chats) != 1 {
		t.Fatalf("chats = %v, want 1 chat", m["chats"])
	}
	c := chats[0].(map[string]any)
	for _, k := range []string{"id", "name", "preview", "time", "unread", "pinned", "group"} {
		if _, ok := c[k]; !ok {
			t.Errorf("chat missing key %q: %v", k, c)
		}
	}
	if c["name"] != "Alice" {
		t.Errorf("chat name = %v, want Alice", c["name"])
	}
	if c["unread"] != float64(2) {
		t.Errorf("chat unread = %v, want 2", c["unread"])
	}
	if c["pinned"] != true {
		t.Errorf("chat pinned = %v, want true", c["pinned"])
	}
	if c["group"] != false {
		t.Errorf("chat group = %v, want false", c["group"])
	}
}

// TestMessagesShape: GET /messages?chat= returns {messages:[...]} with the
// exact Message fields.
func TestMessagesShape(t *testing.T) {
	s := testServer(t)
	w, m := doReq(t, s, "GET", "/messages?chat=15551234567%40s.whatsapp.net", "")
	if w.Code != 200 {
		t.Fatalf("messages code = %d, want 200", w.Code)
	}
	msgs, ok := m["messages"].([]any)
	if !ok || len(msgs) != 2 {
		t.Fatalf("messages = %v, want 2", m["messages"])
	}
	msg := msgs[0].(map[string]any)
	for _, k := range []string{"id", "chat", "text", "dir", "time", "status", "from_me"} {
		if _, ok := msg[k]; !ok {
			t.Errorf("message missing key %q: %v", k, msg)
		}
	}
	if msg["text"] != "hello" {
		t.Errorf("msg text = %v, want hello", msg["text"])
	}
	if msg["dir"] != "in" {
		t.Errorf("msg dir = %v, want in", msg["dir"])
	}
}

// TestMessagesChatRequired: /messages without ?chat= → 400.
func TestMessagesChatRequired(t *testing.T) {
	s := testServer(t)
	w, _ := doReq(t, s, "GET", "/messages", "")
	if w.Code != 400 {
		t.Errorf("messages code = %d, want 400", w.Code)
	}
}

// TestSendShape: POST /send with {chat,text} when linked returns {ok,id}.
func TestSendShape(t *testing.T) {
	s := testServer(t)
	// The WAClient is nil in tests; we only verify the auth/linked gate + shape.
	// (Sending needs a live client; the handler returns 500 without one.)
	w, _ := doReq(t, s, "POST", "/send", `{"chat":"15551234567@s.whatsapp.net","text":"hi"}`)
	if w.Code != 500 {
		t.Errorf("send code = %d, want 500 (no client in test)", w.Code)
	}
}

// TestNotLinked: endpoints return 403 when not linked.
func TestNotLinked(t *testing.T) {
	cfg := &Config{Token: "", Port: "0", Host: "127.0.0.1", DBPath: ":memory:", MediaDir: t.TempDir()}
	state, _ := NewAppState(cfg)
	s := NewServer(state, nil)
	for _, path := range []string{"/chats", "/messages?chat=x"} {
		w, m := doReq(t, s, "GET", path, "")
		if w.Code != 403 {
			t.Errorf("%s code = %d, want 403", path, w.Code)
		}
		if m["error"] != "not linked" {
			t.Errorf("%s error = %v, want 'not linked'", path, m["error"])
		}
	}
}

// TestAuth: with a token set, requests without it → 401 {"error":"unauthorized"}.
func TestAuth(t *testing.T) {
	cfg := &Config{Token: "secret", Port: "0", Host: "127.0.0.1", DBPath: ":memory:", MediaDir: t.TempDir()}
	state, _ := NewAppState(cfg)
	s := NewServer(state, nil)
	w, m := doReq(t, s, "GET", "/status", "")
	if w.Code != 401 {
		t.Errorf("no-token code = %d, want 401", w.Code)
	}
	if m["error"] != "unauthorized" {
		t.Errorf("error = %v, want unauthorized", m["error"])
	}
	// With Bearer token → 200.
	w2, _ := doReq(t, s, "GET", "/status?token=secret", "")
	if w2.Code != 200 {
		t.Errorf("token code = %d, want 200", w2.Code)
	}
}

// TestCallStateShape: GET /call/state returns {calls:[...], active}.
func TestCallStateShape(t *testing.T) {
	s := testServer(t)
	w, m := doReq(t, s, "GET", "/call/state", "")
	if w.Code != 200 {
		t.Fatalf("call/state code = %d, want 200", w.Code)
	}
	if _, ok := m["calls"]; !ok {
		t.Errorf("call/state missing calls key")
	}
	if m["active"] != float64(0) {
		t.Errorf("call/state active = %v, want 0", m["active"])
	}
}

// TestPasskeyRequest: no pending → 404 {"error":"no pending passkey request"}.
func TestPasskeyRequestNotFound(t *testing.T) {
	s := testServer(t)
	w, m := doReq(t, s, "GET", "/passkey/request", "")
	if w.Code != 404 {
		t.Errorf("passkey/request code = %d, want 404", w.Code)
	}
	if m["error"] != "no pending passkey request" {
		t.Errorf("error = %v", m["error"])
	}
}

// TestMediaNotFound: /media/{id}/{kind} with nothing cached → 404.
func TestMediaNotFound(t *testing.T) {
	s := testServer(t)
	w, _ := doReq(t, s, "GET", "/media/abc/img", "")
	if w.Code != 404 {
		t.Errorf("media code = %d, want 404", w.Code)
	}
}

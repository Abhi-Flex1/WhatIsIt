package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// Message mirrors store.rs::Message exactly (serde field names preserved).
type Message struct {
	ID        string    `json:"id"`
	Chat      string    `json:"chat"`
	Text      string    `json:"text"`
	Dir       string    `json:"dir"` // "in" | "out"
	Time      int64     `json:"time"`
	Status    string    `json:"status"` // "sent" | "delivered" | "read"
	ReplyTo   string    `json:"reply_to,omitempty"`
	Reactions []string  `json:"reactions,omitempty"`
	Media     *MediaRef `json:"media,omitempty"`
	FromMe    bool      `json:"from_me"`
}

// MediaRef mirrors store.rs::MediaRef.
type MediaRef struct {
	Kind     string `json:"kind"` // image | video | audio | voice | document | sticker
	URL      string `json:"url"`
	ThumbURL string `json:"thumb_url,omitempty"`
	Caption  string `json:"caption,omitempty"`
	Mime     string `json:"mime,omitempty"`
}

// ChatSummary mirrors store.rs::ChatSummary.
type ChatSummary struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Preview string `json:"preview"`
	Time    int64  `json:"time"`
	Unread  int    `json:"unread"`
	Pinned  bool   `json:"pinned"`
	Group   bool   `json:"group"`
}

type conversation struct {
	Messages []Message `json:"messages"`
	Unread   int       `json:"unread"`
	Pinned   bool      `json:"pinned"`
}

// CallRecord is one entry in the WhatsApp call history (audio/video, in/out).
type CallRecord struct {
	ID     string `json:"id"` // whatsmeow call id (unique)
	Peer   string `json:"peer"` // JID
	Dir    string `json:"dir"`  // "in" | "out"
	Video  bool   `json:"video"`
	Missed bool   `json:"missed"`
	Time   int64  `json:"time"` // unix millis
}

type snapshot struct {
	Chats map[string]*conversation `json:"chats"`
	Names map[string]string        `json:"names"`
	Phone string                   `json:"phone"`
	Calls []CallRecord             `json:"calls"`
}

// HistoryStore is the in-memory chat/message store, persisted as history.json.
type HistoryStore struct {
	mu           sync.Mutex
	chats        map[string]*conversation
	names        map[string]string
	phone        string
	calls        []CallRecord
	snapshotPath string
}

const maxMessages = 2000
const maxCalls = 300

// NewHistoryStore loads (or initializes) the store from <dbdir>/history.json.
func NewHistoryStore(cfg *Config) (*HistoryStore, error) {
	path := filepath.Join(filepath.Dir(cfg.DBPath), "history.json")
	s := &HistoryStore{
		chats:        make(map[string]*conversation),
		names:        make(map[string]string),
		snapshotPath: path,
	}
	if b, err := os.ReadFile(path); err == nil {
		var snap snapshot
		if err := json.Unmarshal(b, &snap); err == nil {
			if snap.Chats == nil {
				snap.Chats = make(map[string]*conversation)
			}
			if snap.Names == nil {
				snap.Names = make(map[string]string)
			}
			s.chats = snap.Chats
			s.names = snap.Names
			s.phone = snap.Phone
			s.calls = snap.Calls
		}
	}
	return s, nil
}

// Flush persists the store to history.json (best-effort, like store.rs::flush).
func (s *HistoryStore) Flush() {
	s.mu.Lock()
	snap := snapshot{Chats: s.chats, Names: s.names, Phone: s.phone, Calls: s.calls}
	s.mu.Unlock()
	if b, err := json.Marshal(&snap); err == nil {
		_ = os.MkdirAll(filepath.Dir(s.snapshotPath), 0o755)
		_ = os.WriteFile(s.snapshotPath, b, 0o644)
	}
}

// SetName stores a display name for a JID.
func (s *HistoryStore) SetName(jid, name string) {
	if name == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.names[jid] = name
}

// SetPhone records the linked phone number.
func (s *HistoryStore) SetPhone(phone string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.phone = phone
}

// UpsertChatMeta updates name/unread/pinned for a chat.
func (s *HistoryStore) UpsertChatMeta(chat, name string, unread int, pinned bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if name != "" {
		s.names[chat] = name
	}
	conv := s.chats[chat]
	if conv == nil {
		conv = &conversation{}
		s.chats[chat] = conv
	}
	if unread > 0 {
		conv.Unread = unread
	}
	conv.Pinned = pinned
}

// UpsertMessage inserts or updates a message (same merge rules as store.rs).
func (s *HistoryStore) UpsertMessage(msg Message) {
	s.mu.Lock()
	defer s.mu.Unlock()
	conv := s.chats[msg.Chat]
	if conv == nil {
		conv = &conversation{}
		s.chats[msg.Chat] = conv
	}
	for i := range conv.Messages {
		if conv.Messages[i].ID == msg.ID {
			if msg.Status != "" {
				conv.Messages[i].Status = msg.Status
			}
			if msg.Text != "" {
				conv.Messages[i].Text = msg.Text
			}
			if msg.Media != nil {
				conv.Messages[i].Media = msg.Media
			}
			return
		}
	}
	conv.Messages = append(conv.Messages, msg)
	if len(conv.Messages) > maxMessages {
		overflow := len(conv.Messages) - maxMessages
		conv.Messages = conv.Messages[overflow:]
	}
}

// BumpUnread increments the unread count.
func (s *HistoryStore) BumpUnread(chat string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	conv := s.chats[chat]
	if conv == nil {
		conv = &conversation{}
		s.chats[chat] = conv
	}
	conv.Unread++
}

// MarkRead zeroes the unread count.
func (s *HistoryStore) MarkRead(chat string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv := s.chats[chat]; conv != nil {
		conv.Unread = 0
	}
}

// SetStatus updates a message's delivery status.
func (s *HistoryStore) SetStatus(chat, id, status string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv := s.chats[chat]; conv != nil {
		for i := range conv.Messages {
			if conv.Messages[i].ID == id {
				conv.Messages[i].Status = status
				return
			}
		}
	}
}

// AddReaction sets or clears a message's reactions (same semantics as store.rs).
func (s *HistoryStore) AddReaction(chat, id, reaction string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv := s.chats[chat]; conv != nil {
		for i := range conv.Messages {
			if conv.Messages[i].ID == id {
				if reaction == "" {
					conv.Messages[i].Reactions = nil
				} else {
					conv.Messages[i].Reactions = []string{reaction}
				}
				return
			}
		}
	}
}

// NameFor returns the display name for a JID, falling back to the JID.
func (s *HistoryStore) NameFor(jid string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if n, ok := s.names[jid]; ok {
		return n
	}
	return jid
}

// MessageCount returns how many messages are stored for a chat (used to show
// update counts for channels).
func (s *HistoryStore) MessageCount(chat string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv, ok := s.chats[chat]; ok {
		return len(conv.Messages)
	}
	return 0
}

// Phone returns the linked phone number.
func (s *HistoryStore) Phone() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.phone
}

// AddCall appends a call-history entry (deduped by call id), capped at maxCalls.
func (s *HistoryStore) AddCall(rec CallRecord) {
	if rec.ID == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.calls {
		if s.calls[i].ID == rec.ID {
			s.calls[i] = rec
			return
		}
	}
	s.calls = append(s.calls, rec)
	if len(s.calls) > maxCalls {
		s.calls = s.calls[len(s.calls)-maxCalls:]
	}
}

// MarkCallAnswered flips a recorded incoming call from missed to answered.
func (s *HistoryStore) MarkCallAnswered(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.calls {
		if s.calls[i].ID == id {
			s.calls[i].Missed = false
			return
		}
	}
}

// Calls returns the call history sorted newest-first (same shape as store.rs).
func (s *HistoryStore) Calls() []CallRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]CallRecord, len(s.calls))
	copy(out, s.calls)
	sort.Slice(out, func(i, j int) bool { return out[i].Time > out[j].Time })
	return out
}

// Chats returns the chat list sorted pinned-first then by last-message time
// desc (same as store.rs::chats).
func (s *HistoryStore) Chats() []ChatSummary {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]ChatSummary, 0, len(s.chats))
	for jid, conv := range s.chats {
		var last *Message
		if n := len(conv.Messages); n > 0 {
			last = &conv.Messages[n-1]
		}
		preview := ""
		var time int64
		if last != nil {
			if last.Text != "" {
				preview = last.Text
			} else if last.Media != nil {
				preview = "📎 " + last.Media.Kind
			}
			time = last.Time
		}
		name := jid
		if n, ok := s.names[jid]; ok {
			name = n
		}
		out = append(out, ChatSummary{
			ID:      jid,
			Name:    name,
			Preview: preview,
			Time:    time,
			Unread:  conv.Unread,
			Pinned:  conv.Pinned,
			Group:   len(jid) > 4 && jid[len(jid)-4:] == "@g.us",
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Pinned != out[j].Pinned {
			return out[i].Pinned
		}
		return out[i].Time > out[j].Time
	})
	return out
}

// Messages returns the last `limit` messages for a chat (same as store.rs).
func (s *HistoryStore) Messages(chat string, limit int) []Message {
	s.mu.Lock()
	defer s.mu.Unlock()
	conv := s.chats[chat]
	if conv == nil {
		return []Message{}
	}
	n := len(conv.Messages)
	start := 0
	if n > limit {
		start = n - limit
	}
	out := make([]Message, n-start)
	copy(out, conv.Messages[start:])
	return out
}

package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
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
	ID     string `json:"id"`   // whatsmeow call id (unique)
	Peer   string `json:"peer"` // JID
	Dir    string `json:"dir"`  // "in" | "out"
	Video  bool   `json:"video"`
	Missed bool   `json:"missed"`
	Time   int64  `json:"time"` // unix millis
}

// StatusEntry is one contact's most recent WhatsApp status update. WhatsApp
// statuses arrive as messages in the status@broadcast chat; we record the
// latest per sender so the Status tab can list "Recent updates".
type StatusEntry struct {
	Sender string    `json:"sender"` // JID of the poster
	Name   string    `json:"name"`   // display name for the row
	Text   string    `json:"text"`
	Kind   string    `json:"kind"` // text | image | video | voice | ...
	Time   int64     `json:"time"` // unix millis
	Media  *MediaRef `json:"media,omitempty"`
}

type snapshot struct {
	Chats    map[string]*conversation `json:"chats"`
	Names    map[string]string        `json:"names"`
	Phone    string                   `json:"phone"`
	Calls    []CallRecord             `json:"calls"`
	Statuses []StatusEntry            `json:"statuses"`
}

// HistoryStore is the in-memory chat/message store, persisted as history.json.
type HistoryStore struct {
	mu           sync.Mutex
	chats        map[string]*conversation
	names        map[string]string
	statuses     map[string]*StatusEntry
	phone        string
	calls        []CallRecord
	snapshotPath string
	dirty        bool
}

const maxMessages = 5000
const maxCalls = 300

// HistoryPath returns the persisted snapshot location for a config.
func HistoryPath(cfg *Config) string {
	return filepath.Join(filepath.Dir(cfg.DBPath), "history.json")
}

// NewHistoryStore loads (or initializes) the store from <dbdir>/history.json.
func NewHistoryStore(cfg *Config) (*HistoryStore, error) {
	path := HistoryPath(cfg)
	s := &HistoryStore{
		chats:        make(map[string]*conversation),
		names:        make(map[string]string),
		statuses:     make(map[string]*StatusEntry),
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
			s.statuses = make(map[string]*StatusEntry)
			for i := range snap.Statuses {
				e := snap.Statuses[i]
				if e.Sender != "" {
					s.statuses[e.Sender] = &e
				}
			}
			s.phone = snap.Phone
			s.calls = snap.Calls
		}
	}
	return s, nil
}

// Flush persists the store to history.json (best-effort, like store.rs::flush)
// and clears the dirty flag.
func (s *HistoryStore) Flush() {
	s.mu.Lock()
	snap := snapshot{Chats: s.chats, Names: s.names, Phone: s.phone, Calls: s.calls, Statuses: s.StatusesLocked()}
	s.dirty = false
	s.mu.Unlock()
	if b, err := json.Marshal(&snap); err == nil {
		_ = os.MkdirAll(filepath.Dir(s.snapshotPath), 0o755)
		_ = os.WriteFile(s.snapshotPath, b, 0o644)
	}
}

// NeedsFlush reports whether the store has unpersisted changes since the last
// Flush (used by the periodic auto-flush ticker).
func (s *HistoryStore) NeedsFlush() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dirty
}

// ResetSeed clears all stored chat messages so a fresh WhatsApp history sync
// (or live traffic) starts from a clean store. Only used to drop demo/seed
// data; the phone number is preserved.
func (s *HistoryStore) ResetSeed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.chats = make(map[string]*conversation)
	s.names = make(map[string]string)
	s.statuses = make(map[string]*StatusEntry)
	s.calls = nil
	s.dirty = true
}

// SetName stores a display name for a JID.
func (s *HistoryStore) SetName(jid, name string) {
	if name == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.names[jid] = name
	s.dirty = true
}

// SetPhone records the linked phone number.
func (s *HistoryStore) SetPhone(phone string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.phone = phone
	s.dirty = true
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
	s.dirty = true
}

// UpsertMessage inserts or updates a message (same merge rules as store.rs).
// Messages are kept sorted by timestamp so chat ordering, previews and the
// newest-first chat list stay correct regardless of arrival order.
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
			s.dirty = true
			return
		}
	}
	conv.Messages = append(conv.Messages, msg)
	sort.SliceStable(conv.Messages, func(i, j int) bool { return conv.Messages[i].Time < conv.Messages[j].Time })
	if len(conv.Messages) > maxMessages {
		conv.Messages = conv.Messages[len(conv.Messages)-maxMessages:]
	}
	s.dirty = true
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
	s.dirty = true
}

// MarkRead zeroes the unread count.
func (s *HistoryStore) MarkRead(chat string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv := s.chats[chat]; conv != nil {
		conv.Unread = 0
		s.dirty = true
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
				s.dirty = true
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
				s.dirty = true
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

// OldestMessage returns the oldest stored message for a chat (messages are kept
// time-ascending), or nil when the chat has none. Used to anchor on-demand
// history backfill requests.
func (s *HistoryStore) OldestMessage(chat string) *Message {
	s.mu.Lock()
	defer s.mu.Unlock()
	conv := s.chats[chat]
	if conv == nil || len(conv.Messages) == 0 {
		return nil
	}
	m := conv.Messages[0]
	return &m
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
			s.dirty = true
			return
		}
	}
	s.calls = append(s.calls, rec)
	if len(s.calls) > maxCalls {
		s.calls = s.calls[len(s.calls)-maxCalls:]
	}
	s.dirty = true
}

// MarkCallAnswered flips a recorded incoming call from missed to answered.
func (s *HistoryStore) MarkCallAnswered(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.calls {
		if s.calls[i].ID == id {
			s.calls[i].Missed = false
			s.dirty = true
			return
		}
	}
}

// AddStatus records (or replaces) a contact's latest status update.
func (s *HistoryStore) AddStatus(entry StatusEntry) {
	if entry.Sender == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.statuses[entry.Sender] = &entry
	s.dirty = true
}

// AddStatusIfNewer records a status update only when it is newer than the one
// already stored for the sender (used for history-sync backfill, where status
// messages can arrive out of order).
func (s *HistoryStore) AddStatusIfNewer(entry StatusEntry) {
	if entry.Sender == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if cur, ok := s.statuses[entry.Sender]; ok && cur.Time >= entry.Time {
		return
	}
	s.statuses[entry.Sender] = &entry
	s.dirty = true
}

// Statuses returns the latest status per contact, newest first (same shape as
// the store.rs status list).
func (s *HistoryStore) Statuses() []StatusEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.StatusesLocked()
}

// StatusesLocked builds the sorted status list; caller must hold s.mu.
func (s *HistoryStore) StatusesLocked() []StatusEntry {
	out := make([]StatusEntry, 0, len(s.statuses))
	for _, e := range s.statuses {
		out = append(out, *e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Time > out[j].Time })
	return out
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
		// Status posts (status@broadcast) are surfaced in the Status tab, not
		// as a normal chat in the Chats list.
		if strings.HasSuffix(jid, "@broadcast") {
			continue
		}
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

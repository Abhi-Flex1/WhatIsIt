package adapter

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	EventQR           = "qr"
	EventLinked       = "linked"
	EventMessage      = "message"
	EventReceipt      = "receipt"
	EventChats        = "chats"
	EventLoggedOut    = "logged_out"
	EventPasskeyReq   = "passkey_request"
	EventPasskeyConf  = "passkey_confirmation"
	EventPasskeyError = "passkey_error"
	EventPairCode     = "pair_code"
)

type BackendEvent struct {
	Type    string `json:"type"`
	QR      string `json:"qr,omitempty"`
	Phone   string `json:"phone,omitempty"`
	Chat    string `json:"chat,omitempty"`
	Linked  bool   `json:"linked,omitempty"`
	Options string `json:"options,omitempty"`
	Code    string `json:"code,omitempty"`
	Error   string `json:"error,omitempty"`
}

type Message struct {
	ID        string     `json:"id"`
	Chat      string     `json:"chat"`
	Text      string     `json:"text"`
	Dir       string     `json:"dir"`
	Time      int64      `json:"time"`
	Status    string     `json:"status"`
	ReplyTo   string     `json:"reply_to,omitempty"`
	Reactions []string   `json:"reactions,omitempty"`
	Media     *MediaRef  `json:"media,omitempty"`
	FromMe    bool       `json:"from_me"`
}

type MediaRef struct {
	Kind     string `json:"kind"`
	URL      string `json:"url"`
	ThumbURL string `json:"thumb_url,omitempty"`
	Caption  string `json:"caption,omitempty"`
	Mime     string `json:"mime,omitempty"`
}

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

type HistoryStore struct {
	mu       sync.Mutex
	chats    map[string]*conversation
	names    map[string]string
	phone    string
	qr       string
	pairCode string
}

func NewHistoryStore() *HistoryStore {
	return &HistoryStore{
		chats: make(map[string]*conversation),
		names: make(map[string]string),
	}
}

func NewHistoryStoreFromPath(path string) *HistoryStore {
	s := NewHistoryStore()
	if b, err := os.ReadFile(path); err == nil {
		var snap map[string]any
		if json.Unmarshal(b, &snap) == nil {
			if chats, ok := snap["chats"].(map[string]any); ok {
				for jid, convAny := range chats {
					if convMap, ok := convAny.(map[string]any); ok {
						conv := &conversation{}
						if msgs, ok := convMap["messages"].([]any); ok {
							for _, mAny := range msgs {
								if mMap, ok := mAny.(map[string]any); ok {
									msg := Message{
										ID:     getStringFromMap(mMap, "id"),
										Chat:   getStringFromMap(mMap, "chat"),
										Text:   getStringFromMap(mMap, "text"),
										Dir:    getStringFromMap(mMap, "dir"),
										Status: getStringFromMap(mMap, "status"),
										ReplyTo: getStringFromMap(mMap, "reply_to"),
										FromMe: getBoolFromMap(mMap, "from_me"),
									}
									if t, ok := mMap["time"].(float64); ok {
										msg.Time = int64(t)
									}
									if reactions, ok := mMap["reactions"].([]any); ok {
										for _, rAny := range reactions {
											if r, ok := rAny.(string); ok {
												msg.Reactions = append(msg.Reactions, r)
											}
										}
									}
									if media, ok := mMap["media"].(map[string]any); ok {
										msg.Media = &MediaRef{
											Kind:     getStringFromMap(media, "kind"),
											URL:      getStringFromMap(media, "url"),
											ThumbURL: getStringFromMap(media, "thumb_url"),
											Caption:  getStringFromMap(media, "caption"),
											Mime:     getStringFromMap(media, "mime"),
										}
									}
									conv.Messages = append(conv.Messages, msg)
								}
							}
						}
						if unread, ok := convMap["unread"].(float64); ok {
							conv.Unread = int(unread)
						}
						if pinned, ok := convMap["pinned"].(bool); ok {
							conv.Pinned = pinned
						}
						s.chats[jid] = conv
					}
				}
			}
			if names, ok := snap["names"].(map[string]any); ok {
				for jid, nameAny := range names {
					if name, ok := nameAny.(string); ok {
						s.names[jid] = name
					}
				}
			}
			if phone, ok := snap["phone"].(string); ok {
				s.phone = phone
			}
		}
	}
	return s
}

func getStringFromMap(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func getBoolFromMap(m map[string]any, key string) bool {
	if v, ok := m[key].(bool); ok {
		return v
	}
	return false
}

func (s *HistoryStore) SetPhone(phone string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.phone = phone
}

func (s *HistoryStore) Phone() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.phone
}

func (s *HistoryStore) SetQR(qr string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.qr = qr
}

func (s *HistoryStore) QR() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.qr
}

func (s *HistoryStore) SetPairCode(code string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pairCode = code
}

func (s *HistoryStore) PairCode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pairCode
}

func (s *HistoryStore) SetName(jid, name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if name != "" {
		s.names[jid] = name
	}
}

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
			if len(msg.Reactions) > 0 {
				conv.Messages[i].Reactions = msg.Reactions
			}
			return
		}
	}
	conv.Messages = append(conv.Messages, msg)
	if len(conv.Messages) > 2000 {
		overflow := len(conv.Messages) - 2000
		conv.Messages = conv.Messages[overflow:]
	}
}

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

func (s *HistoryStore) MarkRead(chat string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if conv := s.chats[chat]; conv != nil {
		conv.Unread = 0
	}
}

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

func (s *HistoryStore) NameFor(jid string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if n, ok := s.names[jid]; ok {
		return n
	}
	return jid
}

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
		var t int64
		if last != nil {
			if last.Text != "" {
				preview = last.Text
			} else if last.Media != nil {
				preview = "📎 " + last.Media.Kind
			}
			t = last.Time
		}
		name := jid
		if n, ok := s.names[jid]; ok {
			name = n
		}
		out = append(out, ChatSummary{
			ID:      jid,
			Name:    name,
			Preview: preview,
			Time:    t,
			Unread:  conv.Unread,
			Pinned:  conv.Pinned,
			Group:   len(jid) > 4 && strings.HasSuffix(jid, "@g.us"),
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

func (s *HistoryStore) Flush(path string) {
	s.mu.Lock()
	snap := map[string]any{
		"chats": s.chats,
		"names": s.names,
		"phone": s.phone,
	}
	s.mu.Unlock()
	b, _ := json.Marshal(snap)
	_ = os.WriteFile(path, b, 0o644)
}

type WSClient struct {
	conn *websocket.Conn
	send chan []byte
}

type WSHub struct {
	mu      sync.Mutex
	clients map[*WSClient]struct{}
}

func NewWSHub() *WSHub {
	return &WSHub{clients: make(map[*WSClient]struct{})}
}

func (h *WSHub) Add(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	client := &WSClient{conn: c, send: make(chan []byte, 256)}
	h.clients[client] = struct{}{}
	go client.writePump()
	go client.readPump()
}

func (h *WSHub) Remove(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for client := range h.clients {
		if client.conn == c {
			close(client.send)
			delete(h.clients, client)
			break
		}
	}
}

func (h *WSHub) Broadcast(event BackendEvent) {
	b, _ := json.Marshal(event)
	h.mu.Lock()
	defer h.mu.Unlock()
	for client := range h.clients {
		select {
		case client.send <- b:
		default:
			close(client.send)
			delete(h.clients, client)
		}
	}
}

func (c *WSClient) readPump() {
	defer c.conn.Close()
	for {
		if _, _, err := c.conn.ReadMessage(); err != nil {
			break
		}
	}
}

func (c *WSClient) writePump() {
	defer c.conn.Close()
	for msg := range c.send {
		if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			break
		}
	}
}

func (h *WSHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("ws upgrade:", err)
		return
	}
	h.Add(c)
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type Adapter struct {
	store           *HistoryStore
	hub             *WSHub
	whatsMiau       string
	instanceID      string
	apiKey          string
	mediaDir        string
	httpClient      *http.Client
	listenAddr      string
	storePath       string
	mediaPublicURL  string
	webhookPublicURL string
}

func NewAdapter(store *HistoryStore, hub *WSHub, whatsMiau, instanceID, apiKey, mediaDir, storePath string) *Adapter {
	return &Adapter{
		store:      store,
		hub:        hub,
		whatsMiau:  whatsMiau,
		instanceID: instanceID,
		apiKey:     apiKey,
		mediaDir:   mediaDir,
		storePath:  storePath,
		httpClient: &http.Client{Timeout: 120 * time.Second},
	}
}

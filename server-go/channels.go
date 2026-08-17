package server

import (
	"encoding/json"
	"log"
	"net/http"
	"sort"
	"sync"
	"time"

	"go.mau.fi/whatsmeow/types"
)

// ChannelSummary is the JSON shape served by /channels (the "followed
// channels" list for the Status tab).
type ChannelSummary struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Subscribers int    `json:"subscribers"`
	Updates     int    `json:"updates"`
	InviteCode  string `json:"invite"`
	Pic         bool   `json:"pic"`
}

// channelCache caches the subscribed-newsletter metadata briefly so the app's
// 5s polls don't hammer WhatsApp's IQ endpoints.
type channelCache struct {
	mu       sync.Mutex
	updated  time.Time
	channels []ChannelSummary
}

func (c *channelCache) get() ([]ChannelSummary, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.channels) == 0 || time.Since(c.updated) > 60*time.Second {
		return nil, false
	}
	return c.channels, true
}

func (c *channelCache) set(ch []ChannelSummary) {
	c.mu.Lock()
	c.channels = ch
	c.updated = time.Now()
	c.mu.Unlock()
}

// channels serves the list of followed channels (newsletters). Falls back to
// the local store when the WhatsApp connection is unavailable.
func (s *Server) channels(w http.ResponseWriter, r *http.Request) {
	if ch, ok := s.state.ChannelCache.get(); ok {
		writeJSON(w, http.StatusOK, map[string]any{"channels": ch})
		return
	}
	out := s.wa.subscribedChannels(r)
	s.state.ChannelCache.set(out)
	writeJSON(w, http.StatusOK, map[string]any{"channels": out})
}

// followChannel subscribes to a WhatsApp channel (POST /channel/follow {chat}).
func (s *Server) followChannel(w http.ResponseWriter, r *http.Request) {
	var body chatBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	chat := body.Chat
	if chat == "" {
		http.Error(w, "chat required", http.StatusBadRequest)
		return
	}
	jid, err := types.ParseJID(chat)
	if err != nil || !isNewsletterJID(jid.String()) {
		http.Error(w, "bad newsletter jid", http.StatusBadRequest)
		return
	}
	if s.wa.cli == nil || !s.wa.cli.IsConnected() {
		http.Error(w, "not connected", http.StatusServiceUnavailable)
		return
	}
	if err := s.wa.cli.FollowNewsletter(r.Context(), jid); err != nil {
		log.Printf("FollowNewsletter %s: %v", jid, err)
		http.Error(w, "follow failed", http.StatusInternalServerError)
		return
	}
	s.state.ChannelCache.set(nil) // force refresh on next poll
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// unfollowChannel unsubscribes from a WhatsApp channel (POST /channel/unfollow {chat}).
func (s *Server) unfollowChannel(w http.ResponseWriter, r *http.Request) {
	var body chatBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	chat := body.Chat
	if chat == "" {
		http.Error(w, "chat required", http.StatusBadRequest)
		return
	}
	jid, err := types.ParseJID(chat)
	if err != nil || !isNewsletterJID(jid.String()) {
		http.Error(w, "bad newsletter jid", http.StatusBadRequest)
		return
	}
	if s.wa.cli == nil || !s.wa.cli.IsConnected() {
		http.Error(w, "not connected", http.StatusServiceUnavailable)
		return
	}
	if err := s.wa.cli.UnfollowNewsletter(r.Context(), jid); err != nil {
		log.Printf("UnfollowNewsletter %s: %v", jid, err)
		http.Error(w, "unfollow failed", http.StatusInternalServerError)
		return
	}
	s.state.ChannelCache.set(nil) // force refresh on next poll
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// subscribedChannels resolves subscribed newsletters, enriched with local
// message counts and picture availability.
func (wc *WAClient) subscribedChannels(r *http.Request) []ChannelSummary {
	var raw []*types.NewsletterMetadata
	if wc.cli != nil && wc.cli.IsConnected() {
		subs, err := wc.cli.GetSubscribedNewsletters(r.Context())
		if err != nil {
			log.Printf("GetSubscribedNewsletters: %v", err)
		} else {
			raw = subs
		}
	}
	// Local fallback: derive channel summaries from the store (names numeric).
	if len(raw) == 0 {
		for _, c := range wc.state.Store.Chats() {
			if isNewsletterJID(c.ID) {
				raw = append(raw, &types.NewsletterMetadata{
					ID: types.NewJID(c.ID[:len(c.ID)-11], types.NewsletterServer),
					ThreadMeta: types.NewsletterThreadMetadata{
						Name: types.NewsletterText{Text: c.Name},
					},
				})
			}
		}
	}
	out := make([]ChannelSummary, 0, len(raw))
	for _, sub := range raw {
		name := sub.ThreadMeta.Name.Text
		if name == "" {
			name = sub.ID.String()
		}
		// Cache the human name in the store so /chats and threads show it too.
		wc.state.Store.SetName(sub.ID.String(), name)
		pic := sub.ThreadMeta.Picture != nil && sub.ThreadMeta.Picture.URL != ""
		if !pic {
			pic = sub.ThreadMeta.Preview.URL != ""
		}
		if !pic {
			pic = sub.ThreadMeta.Preview.DirectPath != ""
		}
		out = append(out, ChannelSummary{
			ID:          sub.ID.String(),
			Name:        name,
			Description: sub.ThreadMeta.Description.Text,
			Subscribers: sub.ThreadMeta.SubscriberCount,
			Updates:     wc.state.Store.MessageCount(sub.ID.String()),
			InviteCode:  sub.ThreadMeta.InviteCode,
			Pic:         pic,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func isNewsletterJID(id string) bool {
	return len(id) > 11 && id[len(id)-11:] == "@newsletter"
}
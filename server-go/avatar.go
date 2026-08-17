package server

import (
	"context"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

// avatarCache caches profile-picture bytes on disk keyed by JID. It is
// best-effort: a missing/stale file is refetched from WhatsApp on demand.
type avatarCache struct {
	dir string
	mu  sync.Mutex
}

func newAvatarCache(dbPath string) *avatarCache {
	return &avatarCache{dir: filepath.Join(filepath.Dir(dbPath), "avatars")}
}

func (c *avatarCache) path(jid string) string {
	// JIDs may contain '@' and other chars that are awkward in filenames.
	slug := strings.NewReplacer("@", "_", "/", "_", ":", "_").Replace(jid)
	return filepath.Join(c.dir, slug+".jpg")
}

// get returns cached bytes if present and younger than ttl, else ok=false.
func (c *avatarCache) get(jid string, ttl time.Duration) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p := c.path(jid)
	st, err := os.Stat(p)
	if err != nil || time.Since(st.ModTime()) > ttl {
		return nil, false
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, false
	}
	return data, true
}

func (c *avatarCache) put(jid string, data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return
	}
	_ = os.WriteFile(c.path(jid), data, 0o644)
}

// avatarURL resolves the profile-picture URL for a JID (regular users/groups
// and newsletters). Returns "" when the JID has no picture or the query fails.
func (wc *WAClient) avatarURL(ctx context.Context, jid types.JID) string {
	if wc.cli == nil || !wc.cli.IsConnected() {
		return ""
	}
	if jid.Server == "newsletter" {
		meta, err := wc.cli.GetNewsletterInfo(ctx, jid)
		if err != nil {
			log.Printf("avatar newsletter %s: %v", jid, err)
			return ""
		}
		if meta == nil {
			return ""
		}
		if meta.ThreadMeta.Picture != nil && meta.ThreadMeta.Picture.URL != "" {
			return meta.ThreadMeta.Picture.URL
		}
		if meta.ThreadMeta.Preview.URL != "" {
			return meta.ThreadMeta.Preview.URL
		}
		if dp := meta.ThreadMeta.Preview.DirectPath; dp != "" {
			return "https://mmg.whatsapp.net" + dp
		}
		return ""
	}
	info, err := wc.cli.GetProfilePictureInfo(ctx, jid, &whatsmeow.GetProfilePictureParams{})
	if err != nil || info == nil {
		if err != nil {
			log.Printf("avatar pic %s: %v", jid, err)
		}
		return ""
	}
	return info.URL
}

// fetchAvatarBytes downloads a URL's bytes (best-effort, with a timeout).
func fetchAvatarBytes(url string) ([]byte, error) {
	client := &http.Client{Timeout: 20 * time.Second}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "WhatIsIt/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, io.EOF
	}
	return io.ReadAll(io.LimitReader(resp.Body, 4<<20))
}

// handleAvatar serves /avatar?chat=<jid>: cached profile picture bytes.
func (s *Server) avatar(w http.ResponseWriter, r *http.Request) {
	chat := r.URL.Query().Get("chat")
	if chat == "" {
		http.Error(w, "chat required", http.StatusBadRequest)
		return
	}
	jid, err := types.ParseJID(chat)
	if err != nil {
		http.Error(w, "bad jid", http.StatusBadRequest)
		return
	}
	const ttl = 24 * time.Hour
	if data, ok := s.state.Avatars.get(chat, ttl); ok {
		writeImage(w, data)
		return
	}
	url := s.wa.avatarURL(r.Context(), jid)
	if url == "" {
		http.NotFound(w, r)
		return
	}
	data, err := fetchAvatarBytes(url)
	if err != nil || len(data) == 0 {
		log.Printf("avatar download %s: %v", chat, err)
		http.NotFound(w, r)
		return
	}
	s.state.Avatars.put(chat, data)
	writeImage(w, data)
}

func writeImage(w http.ResponseWriter, data []byte) {
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	_, _ = w.Write(data)
}
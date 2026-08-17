package server

import (
	"os"
	"path/filepath"
	"sync"
	"time"
)

// mediaCache mirrors media.rs: downloads incoming media to <media_dir>/{id}.{ext}
// and serves it. Concurrent-safe, best-effort disk cache.
type mediaCache struct {
	dir string
	mu  sync.Mutex
}

func newMediaCache(dir string) *mediaCache {
	return &mediaCache{dir: dir}
}

// ext maps a media kind to its cache file extension (media.rs::media_path).
func mediaExt(kind string) string {
	switch kind {
	case "image":
		return "img"
	case "video":
		return "vid"
	case "audio", "voice":
		return "aud"
	case "document":
		return "doc"
	case "sticker":
		return "stk"
	case "thumb":
		return "thm"
	}
	return "bin"
}

// mime maps a media kind to its served Content-Type (media.rs::serve_media).
func mediaMime(kind string) string {
	switch kind {
	case "image":
		return "image/jpeg"
	case "video":
		return "video/mp4"
	case "audio", "voice":
		return "audio/ogg"
	case "sticker":
		return "image/webp"
	case "thumb":
		return "image/jpeg"
	}
	return "application/octet-stream"
}

func (c *mediaCache) path(id, kind string) string {
	return filepath.Join(c.dir, id+"."+mediaExt(kind))
}

// Put writes media bytes to the cache.
func (c *mediaCache) Put(id, kind string, data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(c.path(id, kind), data, 0o644)
}

// Get returns cached media bytes, or false.
func (c *mediaCache) Get(id, kind string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	data, err := os.ReadFile(c.path(id, kind))
	if err != nil {
		return nil, false
	}
	return data, true
}

func nowMillis() int64 { return time.Now().UnixMilli() }
func timeNow() time.Time { return time.Now() }

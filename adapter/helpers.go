package adapter

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
)

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (a *Adapter) getString(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func (a *Adapter) digits(s string) string {
	var b strings.Builder
	for _, c := range s {
		if c >= '0' && c <= '9' {
			b.WriteRune(c)
		}
	}
	return b.String()
}

func (a *Adapter) ensureDir(path string) {
	_ = os.MkdirAll(path, 0o755)
}

func (a *Adapter) flushStore() {
	if a.storePath != "" {
		a.store.Flush(a.storePath)
	}
}

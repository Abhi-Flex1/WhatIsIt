package server

import (
	"net/http"
	"strings"
)

// authorized mirrors web.rs::authorized: require Bearer token or ?token= when
// the token is set; allow all when empty.
func authorized(r *http.Request, cfg *Config) bool {
	if cfg.Token == "" {
		return true
	}
	if h := r.Header.Get("Authorization"); h == "Bearer "+cfg.Token {
		return true
	}
	if q := r.URL.Query(); q.Get("token") == cfg.Token {
		return true
	}
	return false
}

// reject mirrors web.rs::reject: 401 {"error":"unauthorized"}.
func reject(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusUnauthorized)
	w.Write([]byte(`{"error":"unauthorized"}`))
}

func containsBearer(h string, tok string) bool {
	return strings.TrimPrefix(h, "Bearer ") == tok
}

// Package server is the WhatsApp backend for the HarmonyOS app.
//
// It is a wire-compatible port of the Rust whatsapp-rust server, built on
// go.mau.fi/whatsmeow + github.com/purpshell/meowcaller. The HTTP routes, WS
// event types, and binary media framing match the Rust server exactly so the
// app needs no changes.
package server

import (
	"os"
)

// Config mirrors the Rust server's events::Config (env-driven).
type Config struct {
	// Token for Bearer auth. Empty = auth disabled.
	Token string
	// Port to listen on.
	Port string
	// Host to bind.
	Host string
	// Path to the SQLite session DB.
	DBPath string
	// Directory for cached media (incoming downloads).
	MediaDir string
}

// Load reads configuration from the environment, matching the Rust server.
func Load() Config {
	return Config{
		Token:    os.Getenv("WHATSAPP_TOKEN"),
		Port:     getenv("PORT", "18770"),
		Host:     getenv("HOST", "0.0.0.0"),
		DBPath:   getenv("DB_PATH", "whatsapp.db"),
		MediaDir: getenv("MEDIA_DIR", "media"),
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

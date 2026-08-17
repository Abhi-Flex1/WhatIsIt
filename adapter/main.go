package main

import (
	"context"
	"log"
	"os"

	"whatisit/adapter"
)

func main() {
	whatsMiau := getEnv("WHATSMIAM_URL", "http://localhost:8080")
	instanceID := getEnv("INSTANCE_ID", "default")
	apiKey := getEnv("API_KEY", "")
	mediaDir := getEnv("MEDIA_DIR", "media")
	listenAddr := getEnv("LISTEN_ADDR", "0.0.0.0:18770")
	storePath := getEnv("STORE_PATH", "history.json")
	mediaPublicURL := getEnv("MEDIA_PUBLIC_URL", "")
	webhookPublicURL := getEnv("WEBHOOK_PUBLIC_URL", "")

	var store *adapter.HistoryStore
	if _, err := os.Stat(storePath); err == nil {
		store = adapter.NewHistoryStoreFromPath(storePath)
	} else {
		store = adapter.NewHistoryStore()
	}
	hub := adapter.NewWSHub()
	a := adapter.NewAdapter(store, hub, whatsMiau, instanceID, apiKey, mediaDir, storePath)
	a.mediaPublicURL = mediaPublicURL
	a.webhookPublicURL = webhookPublicURL

	ctx := context.Background()
	if err := a.Run(ctx, listenAddr); err != nil {
		log.Fatalf("adapter failed: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

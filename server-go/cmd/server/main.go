// Command server is the WhatsApp backend for the HarmonyOS app.
//
// Wire-compatible with the Rust whatsapp-rust server, built on whatsmeow +
// meowcaller. See the package doc in server.go for the contract.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"whatisit/server-go"
)

func main() {
	resetStore := flag.Bool("reset", false, "clear the persisted chat store (history.json) before starting")
	flag.Parse()

	cfg := server.Load()

	if *resetStore {
		if err := os.Remove(server.HistoryPath(&cfg)); err != nil && !os.IsNotExist(err) {
			log.Printf("warning: failed to remove history.json: %v", err)
		}
		log.Printf("store reset: history.json removed")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	state, err := server.NewAppState(&cfg)
	if err != nil {
		log.Fatalf("init state: %v", err)
	}
	wa, err := server.NewWAClient(ctx, &cfg, state)
	if err != nil {
		log.Fatalf("init whatsmeow: %v", err)
	}

	// Install the meowcaller call engine (must be before connect).
	mc := server.NewMeowcallerClient(wa.Client())
	state.Calls.SetState(state)
	state.Calls.SetMeowcaller(mc)
	mc.OnIncomingCall(state.Calls.OnIncomingCall)

	// Connect (or start QR pairing).
	if err := wa.Connect(ctx); err != nil {
		log.Fatalf("connect: %v", err)
	}

	app := server.NewServer(state, wa)
	addr := cfg.Host + ":" + cfg.Port
	srv := &http.Server{Addr: addr, Handler: app.Mux()}

	// Periodically flush unpersisted changes so live messages survive a crash
	// or restart (Flush was previously only triggered by a history sync).
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if state.Store.NeedsFlush() {
					state.Store.Flush()
				}
			}
		}
	}()

	go func() {
		log.Printf("whatisit-server-go listening on %s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-ctx.Done()
	log.Printf("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	state.Store.Flush()
}
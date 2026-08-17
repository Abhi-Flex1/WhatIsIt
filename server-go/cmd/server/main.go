// Command server is the WhatsApp backend for the HarmonyOS app.
//
// Wire-compatible with the Rust whatsapp-rust server, built on whatsmeow +
// meowcaller. See the package doc in server.go for the contract.
package main

import (
	"context"
	"log"
	"net/http"

	"whatisit/server-go"
)

func main() {
	cfg := server.Load()

	ctx := context.Background()
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
	log.Printf("whatisit-server-go listening on %s", addr)
	if err := http.ListenAndServe(addr, app.Mux()); err != nil {
		log.Fatalf("listen: %v", err)
	}
}

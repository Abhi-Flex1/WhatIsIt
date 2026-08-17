# WhatIsIt — WhatsApp on HarmonyOS (native protocol client)

A native HarmonyOS WhatsApp client whose session runs on a **whatisit-server**
(always-on VPS). The user links once by scanning an in-app QR code — or typing
an 8-char phone-number code — with the WhatsApp Android/iPhone app; after that
the server keeps the session alive — no PC, no Chrome, no container needed.

```
HarmonyOS device (WhatIsIt)
   native ArkUI: QR pairing screen → chat list → thread (native bubbles, media,
   reactions, delivery ticks, WhatsApp-native calls)
        │  HTTP: /status /pair /pair-code /passkey/* /chats /messages /send
        │        /send-media /read /react /logout /call/* /media/{id}/{kind}
        │  WS:   /ws push {qr, linked, message, receipt, chats, logged_out,
        │        incoming_call, passkey_request, passkey_confirmation} + binary
        │        media frames (audio PCM + H.264 video)
        ▼
whatisit-server (Go, whatsmeow + meowcaller) — WhatsApp Multi-Device protocol,
Signal E2EE, SQLite session store, keepalive + auto-reconnect, media cache,
1:1 voice/video calls, SHORTCAKE passkey linking
```

> **Backend**: `server-go/` is the current backend — a wire-compatible port of
> the original Rust `server/` (whatsapp-rust). The Go server is built and its
> parity tests pass; the Rust server is kept as the known-good reference until
> the Go server passes a live link + call test on a real account.

## How it works

1. The user opens the app — it shows a **QR code** (native ArkUI `QRCode`), or
   taps **Link with phone number instead** to get an 8-char code typed into
   WhatsApp.
2. WhatsApp → Linked Devices → Link a Device → scan (or enter the code).
3. If the account is in WhatsApp's **passkey cohort**, the server pushes a
   `passkey_request` event; the app completes the WebAuthn assertion (see
   "Passkey linking" below) and shows any verification code.
4. The app auto-routes to the chat list. Chats/messages come from the server
   over HTTP + WebSocket push (no browser, no DOM scraping).
5. The server keeps the socket alive (own keepalive + auto-reconnect), so the
   session survives indefinitely while the VPS is up — the app needs no
   keep-alive ping (battery win).

## Passkey linking (SHORTCAKE)

Meta's 2026 passkey device-link gate requires a WebAuthn assertion from a
passkey already registered to the account. `whatsmeow` implements the
handshake; the server bridges the app into it:

- WS `passkey_request {options}` — the `PublicKeyCredentialRequestOptions` JSON;
  the app runs a WebAuthn `get` and POSTs the assertion to `/passkey/assertion`.
- WS `passkey_confirmation {code}` — a verification code to show on the phone
  (fresh links).
- HTTP `/passkey/request`, `/passkey/assertion`, `/passkey/confirm`,
  `/passkey/cancel` — the app ↔ server seam.

> This SDK version has no Credential Manager / WebAuthn API, so the app's
> passkey card accepts a pasted assertion JSON as a developer fallback. Swap in
> a native `navigator.credentials.get` call in `PasskeyService.obtainAssertion`
> the moment `@kit` ships WebAuthn.

## Files

| File | Purpose |
|---|---|
| `server-go/` | Go backend (current): `config.go`, `auth.go`, `state.go`, `events.go`, `store.go`, `client.go` (whatsmeow wrapper), `media.go`, `extract.go`, `calls.go` (meowcaller relay), `web.go` (HTTP + WS + passkey + call endpoints), `ws.go` (WS + media relay), `parity_test.go` (wire-compat suite), `Dockerfile`, `deploy/`. |
| `server/` | Rust backend (reference, pre-migration): `main.rs`, `events.rs`, `state.rs`, `history.rs`, `store.rs`, `media.rs`, `web.rs`, `calls.rs`, `DEPLOY.md`. |
| `entry/src/main/ets/services/CdpBridge.ets` | The app's backend client (HTTP + WS + passkey + calls); keeps the page-facing API. |
| `entry/src/main/ets/services/PasskeyService.ets` | SHORTCAKE passkey ceremony orchestration (assertion submit/confirm/cancel). |
| `entry/src/main/ets/services/ServerConfig.ets` | Hidden backend host/port/token constants (no UI plumbing). |
| `entry/src/main/ets/pages/MainPage.ets` | QR pairing screen (QR + phone-code + passkey card) → chats → thread. |
| `entry/src/main/ets/pages/ChatListView.ets` / `ChatThreadView.ets` | Native chat list + thread (media, reactions, ticks, WhatsApp-native calls). |
| `entry/src/main/ets/pages/CallSurfaceView.ets` / `services/CallService.ets` / `CallAudio.ets` | WhatsApp-native call UI (XComponent surfaces, PiP) + media relay. |
| `entry/src/main/cpp/` | Native `call_media` module: OH_VideoEncoder/Decoder (H.264), NAPI bridge. |
| `entry/src/main/ets/services/MediaDownloader.ets` | Downloads `/media/{id}` into the private sandbox for native rendering. |

## Capabilities (honest)

| Feature | Status |
|---|---|
| QR pairing in-app (scan with phone) | ✅ |
| Phone-number 8-char code pairing + country code | ✅ (`/pair-code` + on-screen code with country prefix) |
| Provisioning QR (air-gapped / per-customer) | ✅ (`whatisit://provision` deep link + QR) |
| Passkey (SHORTCAKE) linking | 🟡 server + app flow done; on-device WebAuthn needs SDK Credential Manager (manual-paste dev fallback) |
| Chat list, 1:1 + group text | ✅ |
| Instant send, replies, reactions, mark-read | ✅ |
| Delivery / read ticks | ✅ (server receipt events → WS) |
| Media send + receive (image/video/audio/doc) | ✅ (cached server-side) |
| Persistent session (no re-link) | ✅ SQLite + server keepalive |
| WhatsApp-native voice calls | 🟡 meowcaller bridge implemented + compiles; **not yet live-validated** |
| WhatsApp-native video calls | 🟡 H.264 via native `call_media` encode/decode; meowcaller video path unproven — test after voice |
| Status / Channels / Communities tabs | ❌ honest empty states (not on the protocol surface) |

## Backends

### server-go (current)
Wire-compatible port of the original Rust `server/` to **Go** on `whatsmeow` + `meowcaller`. See `server-go/README.md` for details.

### WhatsMiau Adapter (experimental)
A thin Go adapter that sits in front of [WhatsMiau](https://github.com/verbeux-ai/whatsmiau), translating its Evolution API-compatible routes and webhooks into the custom API the app expects. See `adapter/README.md` for architecture, run instructions, and Docker Compose.

> **Note**: the adapter does not yet proxy WhatsApp-native calls or the full SHORTCAKE passkey ceremony. Use `server-go` if you need those features.

## Build & run

**server-go backend:**
```bash
cd server-go
go build ./... && go test ./...   # needs Go >= 1.25 (auto-downloads)
go run ./cmd/server               # starts :18770 (see server-go/README.md)
```

**WhatsMiau + Adapter backend:**
```bash
# 1. Start WhatsMiau
cd server-whatsmiau
cp .env.example .env
go mod tidy
go run main.go                    # starts :8080

# 2. Start adapter
cd adapter
go mod tidy
go run main.go                    # starts :18770
```

Or with Docker Compose:
```bash
docker compose -f docker-compose.adapter.yml up -d --build
```

**App:**
```bash
oniro-app lint --files entry/src/main/ets/**
oniro-app build
oniro-app app apply
oniro-app app launch
```

> Note: the app build requires the HarmonyOS SDK (DevEco command-line-tools +
> SDK components). The Go backends build anywhere with Go 1.25+ (pure Go, no
> CGO).

## Deploy

See `server-go/DEPLOY.md` — free VPS (GCP e2-micro), Docker or systemd, Caddy/
Cloudflare Tunnel for TLS. The app's `ServerConfig.BACKEND_HOST` (or the
hidden `backend_host` pref) points at the server.

For the WhatsMiau + Adapter stack, use `docker-compose.adapter.yml` and point
the app at the adapter host on port 18770.

## Notes

- **Single account per server** — one linked WhatsApp number per instance.
  Multi-user on a shared VPS IP is a ban risk (the same verdict as before).
- **Unofficial client** — using custom WhatsApp clients may violate Meta's
  ToS and could result in account suspension. Use at your own risk.
- **No browser, no Chrome, no container, no Jitsi** — the CDP/real-Chrome path
  and the Jitsi fallback are fully removed; calls are WhatsApp-native through
  the Go backend.

# WhatIsIt — Test User Setup Guide

This guide gets a test user from fresh device to linked + chat usage with the
**Go backend** (`server-go/`, whatsmeow + meowcaller) on a VPS. No PC, no
Chrome, no container needed after linking. Total time: ~5 minutes.

> **Backend status**: `server-go/` is the current backend — a wire-compatible
> port of the original Rust `server/` (whatsapp-rust). It is built and its
> parity tests pass, but it has **not yet been live-linked** to a real
> WhatsApp account on a VPS. The Rust `server/` is kept as the known-good
> reference until the Go server passes the live link + call test.

---

## What you need

- A Huawei device (HarmonyOS) with the **WhatIsIt** app installed.
- The **WhatsApp** app on any phone (the same device or another one) for
  scanning the QR.
- A running **whatisit-server** (see `server-go/DEPLOY.md` or the
  **WhatsMiau Adapter** below) — the backend that holds the session.

> The server must be reachable from the phone (LAN IP or a public host).
> Set it in the app's hidden `backend_host` preference (compile-time
> `ServerConfig.BACKEND_HOST` default, or the admin endpoint override).

---

## Step 1 — Install + point the app at the server

1. Install WhatIsIt on the Huawei device.
2. Set the backend host once (hidden — no UI field):
   - Default: `127.0.0.1:18770` (server on the same machine — dev only).
   - Real usage: your VPS IP or host, port 18770.

---

## Step 2 — Link with the QR code (or phone number)

1. Open **WhatIsIt** — it shows a **QR code** on the Link screen.
2. Open **WhatsApp** → **Settings → Linked devices → Link a device**.
3. Scan the QR shown in WhatIsIt.
4. **Prefer a code?** Tap **"Link with phone number instead"**, enter the
   country code + number, tap **Get code**, and type the 8-char code into
   WhatsApp's "Link with phone number instead" screen.
5. The app auto-routes to the **chat list** the moment linking completes.

> The QR refreshes automatically (first 60s, then 20s). No browser, no PC,
> no manual "connect" step.

---

## Step 3 — Use chats

- **Chat list** loads from the server (names, previews, unread badges).
- Tap a chat → thread opens instantly (no openChat wait).
- Send text, replies, reactions; media attachments upload via the server.
- **Delivery ticks**: single tick = sent, double = delivered, blue = read.

---

## Step 4 — Keep it alive (indefinite)

- The server keeps the WhatsApp socket alive (its own keepalive +
  auto-reconnect). **As long as the VPS is up, the session stays linked.**
- The app needs **no keep-alive ping** — battery friendly.
- Restart the server any time: SQLite keeps the session, `/status` flips back
  to `linked:true` after a brief reconnect.

---

## Calls

- **WhatsApp-native voice calls**: use the 📞 button in a chat — the server
  runs the call over the WhatsApp protocol (meowcaller VoIP) and relays the
  audio to the app over the WebSocket.
- **WhatsApp-native video calls**: use the 📹 button — H.264 is encoded/
  decoded by the native `call_media` module (OH_VideoEncoder/Decoder) and
  rendered on native XComponent surfaces (PiP overlay for the local camera).
- No Jitsi, no browser, no third-party media servers.

> **Call status**: the meowcaller bridge is implemented and compiles, but has
> not been validated against a live peer yet. meowcaller's video send/receive
> paths are marked "NOT VALIDATED" upstream. Test voice first, then video.

---

## Passkey linking (SHORTCAKE)

Some WhatsApp accounts now require a **passkey check** when linking a new
device (Meta's 2026 security rollout). If your account hits this:

1. The app shows a **"WhatsApp security check"** card on the Link screen.
2. It expects a WebAuthn assertion from a passkey registered to the account.
   This SDK has no native Credential Manager API yet, so the card accepts a
   **pasted assertion JSON** (developer fallback) — a future `@kit` WebAuthn
   API will make this a one-tap biometric prompt.
3. If a **verification code** appears, enter it in WhatsApp when asked, then
   tap **Confirm** in the app.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "Can't reach the server" | The server is down or the `backend_host` is wrong. Start it (`go run ./cmd/server` in `server-go/`) or fix the hidden pref. |
| QR shows but never links | Check the server log for "QR code issued"; scan within the QR's 60/20s window. |
| "WhatsApp security check" card stuck | Complete the passkey assertion (see Passkey linking); or tap "Use the QR code instead" to cancel the ceremony. |
| Chat list empty | History sync may take a few seconds after linking; pull-to-refresh or reopen. |
| Media shows "not cached" | Old media from before this session may not be cached; new incoming media is cached live. |
| Status/Channels/Communities tabs empty | Not implemented over the protocol — honest empty states. |
| Session lost | `POST /logout` was called, or the VPS was down >14 days with the phone also offline. Re-scan the QR. |

---

## What the test user should report back

1. Did the QR scan link successfully?
2. Did the phone-number 8-char code link work?
3. Did the passkey security check complete (if your account requires it)?
4. Did the chat list load?
5. Did tapping a chat open the thread instantly?
6. Did sending text + an image work?
7. Did delivery ticks appear (sent → delivered → read)?
8. Did a WhatsApp-native voice call work? A video call?
9. (Next day) Is it still linked without re-scanning?

## Alternative backend: WhatsMiau Adapter

If you want to use [WhatsMiau](https://github.com/verbeux-ai/whatsmiau) as the
WhatsApp engine (robust, Evolution API-compatible, lightweight), run the
adapter instead of `server-go`:

```bash
# 1. Start WhatsMiau
cd server-whatsmiau
cp .env.example .env
go mod tidy
go run main.go

# 2. Start adapter
cd adapter
go mod tidy
go run main.go
```

Or with Docker Compose:

```bash
docker compose -f docker-compose.adapter.yml up -d --build
```

The adapter listens on port 18770 and exposes the same API the app expects.
It auto-creates a single WhatsMiau instance, forwards send operations, and
receives webhooks to build the local chat/message history the app polls.

See `adapter/README.md` for full details, environment variables, and known
limitations.

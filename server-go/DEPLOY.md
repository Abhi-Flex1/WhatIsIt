# WhatIsIt Backend (Go) — Deploy to a free VPS

Same architecture as the Rust server: the WhatsApp session lives on an
**always-on** host (the session dies if the box sleeps). The phone app pairs
once via QR (or phone number), then talks to this server over HTTP + WebSocket.

## Build (Linux)

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o whatisit-server ./cmd/server
```

No CGO, pure Go — the binary is static and runs anywhere.

## Option A: Docker

```sh
docker build -t whatisit-server .
docker run -d --restart=always --name whatisit \
  -e WHATSAPP_TOKEN=change-me \
  -e DB_PATH=/data/whatsapp.db \
  -e MEDIA_DIR=/data/media \
  -v whatisit-data:/data \
  -p 18770:18770 whatisit-server
```

## Option B: systemd (no Docker)

```sh
# 1. Copy the binary to /usr/local/bin/
sudo cp whatisit-server /usr/local/bin/

# 2. Install the unit
sudo cp deploy/whatisit-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now whatisit-server
```

## Point the app at the VPS

1. Install the app, set `BACKEND_HOST` to the VPS IP (hidden pref).
2. `POST /pair` → scan the QR (or `POST /pair-code` with country+phone for the
   8-char code).
3. The app routes to the chat list. The session now lives on the VPS.

## Notes

- Set `WHATSAPP_TOKEN` and send it as `Authorization: Bearer <token>` (or
  `?token=`) or the API returns 401.
- The session stays warm as long as the VPS is up. WhatsApp's 14-day
  inactivity rule applies only if the *phone* is offline.

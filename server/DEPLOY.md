# WhatIsIt Backend — Deploy to a free VPS

The backend is a single static Rust binary (whatsapp-rust). It keeps the
WhatsApp session in SQLite, so it must run on an **always-on** host — the
session dies if the box sleeps. The phone app pairs once by scanning a QR
rendered in the app; after that the server keeps the socket alive (its own
keepalive + auto-reconnect), so **no PC is ever needed again**.

## Hosting

**Eclipse Xpanse is not a host** — it's an orchestration layer that provisions
real clouds. Skip it. Use one of these **free, never-sleeping** tiers:

| Host | Notes |
|---|---|
| **Google Cloud e2-micro** (free forever) | Recommended: 1 vCPU / 1 GB, never sleeps. |
| Azure B1s (12-month free) | Good if you want Azure credits. |
| AWS t2.micro (12-month free) | Fine; a bit slower. |
| Home Raspberry Pi | Free, always-on; needs a static/DDNS address. |

Avoid Render/Railway free tiers — they sleep, which kills the WhatsApp socket.

## Option A — Docker (recommended for GCP)

Build (Linux) or cross-build, push to a registry, run on the VM:

```bash
# Build
docker build -t whatisit-server .

# Run (set your token!)
docker run -d --restart=always --name whatisit \
  -p 18770:18770 \
  -v whatisit-data:/srv/whatisit/data \
  -e WHATSAPP_TOKEN='CHANGE_ME' \
  whatisit-server
```

## Option B — systemd (no Docker)

On the VM:

```bash
# 1. Copy the binary (build with: cargo build --release --target x86_64-unknown-linux-musl)
sudo install -m 755 target/release/whatisit-server /usr/local/bin/whatisit-server

# 2. Data dir + user
sudo useradd --system --home /srv/whatisit --shell /usr/sbin/nologin whatisit
sudo mkdir -p /srv/whatisit/data
sudo chown -R whatisit:whatisit /srv/whatisit

# 3. Token (MUST be set — a missing token caused 401s before)
echo 'WHATSAPP_TOKEN=CHANGE_ME' | sudo tee /etc/whatisit.env
sudo chmod 600 /etc/whatisit.env

# 4. Service
sudo cp deploy/whatisit-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now whatisit-server
sudo systemctl status whatisit-server
```

## Expose it to the app

The app's `ServerConfig.BACKEND_HOST` (or the hidden `backend_host` pref)
must point at the VPS. Two options:

- **Plain HTTP** on port 18770: set `BACKEND_HOST` to the VPS IP. Works but
  the token is sent in clear over the internet (acceptable for a personal
  tool; prefer TLS).
- **TLS (recommended)** — Caddy reverse proxy or Cloudflare Tunnel (free):

  Caddy:
  ```
  # Caddyfile
  chat.example.com {
      reverse_proxy 127.0.0.1:18770
  }
  ```

  Cloudflare Tunnel (matches the earlier accepted pattern):
  ```bash
  # on the VPS
  cloudflared tunnel --url http://localhost:18770
  ```
  Then set `BACKEND_HOST` to the tunnel's `https://` host (the app's
  `getWsUrl` uses `ws://`; change to `wss://` if using TLS — the app's
  `ServerConfig` default is plain HTTP).

## First link

1. Install the app on the phone, set `BACKEND_HOST` to the VPS (hidden pref).
2. Open the app → it shows a **QR code** (native ArkUI `QRCode`).
3. WhatsApp → Linked Devices → Link a Device → scan.
4. The app auto-routes to the chat list. The session now lives on the VPS.

## Keep-alive & 14-day window

- whatsapp-rust sends its own websocket keepalives and auto-reconnects, so
  the session stays warm **as long as the VPS is up**.
- WhatsApp's 14-day inactivity rule still applies only if the *phone* is
  offline the whole window AND the server can't reconnect. With the server
  always-on, the window is never hit.
- Restart the server any time — SQLite keeps the session; `/status` flips to
  `linked:true` again after a brief reconnect.

## Logout / re-link

- `POST /logout` (or the app's logout) removes the session; the app shows a
  fresh QR for re-linking.

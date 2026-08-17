# WhatIsIt Cloud Deployment Guide

Deploy the WhatsMiau + Adapter stack on a cloud VPS for use with the HarmonyOS HAP native app.

## Prerequisites

- A cloud VPS (Ubuntu 22.04+/Debian 12+) with at least 2 GB RAM and 2 vCPUs
- A public IP address or domain name
- Ports 18770 (adapter) and 8080 (WhatsMiau) accessible from the internet
- Root or sudo access

## Zero-Config Overview

The HarmonyOS app automatically discovers the backend on first launch. No manual IP configuration is needed by end users.

### How it works

1. The app ships with a default production domain (`api.whatisit.app`) baked into `ServerConfig.ets`
2. On first launch, the app probes known hosts in order:
   - The stored host (if previously saved)
   - `api.whatisit.app` (production default)
   - `localhost` (emulator/local)
   - `127.0.0.1` (local fallback)
3. The first reachable host wins and is saved to hidden preferences
4. Subsequent launches reuse the saved host

### Production setup (recommended)

1. Deploy the stack using Docker Compose or systemd (see below)
2. Point a DNS A record for `api.whatisit.app` to your VPS public IP
   - Or use your own domain and update `ServerConfig.ets`
3. Rebuild the HAP with the updated `ServerConfig.ets`
4. Upload to AppGallery Connect
5. Users install the HAP — it auto-connects

### Local development setup

For emulator or local device testing without DNS:
1. Run the stack locally on `localhost:8080` and `localhost:18770`
2. The app auto-discovers `localhost` as a fallback
3. Or manually override via the hidden `backend_host` preference if needed

## Provisioning QR (air-gapped / per-customer)

For deployments where end users should not manually configure a backend host, use the provisioning QR flow:

### How it works

1. The adapter exposes `GET /provision/qr?host=<backend>&port=<port>`
2. The response contains a `provision_url` in the format `whatisit://provision?host=...&port=...`
3. Encode this URL as a QR code (the app can render it natively, or use any QR generator)
4. The user scans the QR with any QR reader
5. If WhatIsIt is installed, it opens the app and auto-saves the backend URL
6. If not installed, the URL is shown and can be copied

### Generate a provisioning QR

```bash
# From the adapter host
curl "http://localhost:18770/provision/qr?host=api.example.com&port=18770"
```

Response:
```json
{
  "provision_url": "whatisit://provision?host=api.example.com&port=18770",
  "backend_host": "api.example.com",
  "backend_port": "18770",
  "adapter_url": "http://localhost:18770"
}
```

### In-app provisioning QR

The WhatIsIt app also includes a "Provision another device" button on the connect screen. Tapping it shows a QR code containing the provisioning deep link. This is useful for per-customer deployments where an admin can provision multiple devices by sharing the QR.

### Deep-link format

```
whatisit://provision?host=<backend>&port=<port>
```

Example:
```
whatisit://provision?host=api.whatisit.app&port=18770
```

The app registers this scheme in its `module.json` intent filter, so scanning the QR opens the app directly.

## Quick Deploy with Docker Compose

### 1. Prepare the VPS

```bash
# Update packages
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker

# Install Docker Compose
sudo apt install -y docker-compose
```

### 2. Deploy the stack

```bash
# Clone the repository (or copy your local repo to the VPS)
git clone https://github.com/verbeux-ai/whatsmiau.git /opt/whatisit
cd /opt/whatisit

# Copy adapter files if you have local changes
# cp -r /path/to/local/adapter/* adapter/

# Start services
docker compose -f docker-compose.cloud.yml up -d --build
```

### 3. Verify

```bash
# Check status
docker compose -f docker-compose.cloud.yml ps

# Check logs
docker compose -f docker-compose.cloud.yml logs -f adapter
docker compose -f docker-compose.cloud.yml logs -f whatsMiau
```

### 4. Get your public IP

```bash
curl -s https://ifconfig.me
```

Or if using a domain:
```bash
# Point your domain A record to the VPS IP
# Example: api.yourdomain.com → VPS_IP
```

### 5. Update the HarmonyOS app

For production with a custom domain, edit `entry/src/main/ets/services/ServerConfig.ets`:

```typescript
export class ServerConfig {
  static readonly BACKEND_HOST: string = 'your-domain.com';
  static readonly BACKEND_PORT: number = 18770;
  static readonly BACKEND_TOKEN: string = '';
  static readonly BACKEND_HOST_PREF: string = 'backend_host';
  static readonly BACKEND_TOKEN_PREF: string = 'backend_token';
  static readonly BACKEND_FALLBACKS: string[] = [
    'your-domain.com',
    'localhost',
    '127.0.0.1',
  ];
  static readonly AUTO_DISCOVER: boolean = true;
}
```

Rebuild and upload the HAP to AppGallery Connect.

**For zero-config with the default domain**, no app changes are needed — just point `api.whatisit.app` DNS to your VPS and rebuild with the default config.

### 6. Test the connection

```bash
# From the HarmonyOS device or any client:
curl http://YOUR_VPS_IP:18770/status
```

Expected response:
```json
{"linked": false, "phone": "", "qr": ""}
```

## Systemd Deployment (no Docker)

### 1. Install dependencies

```bash
sudo apt update
sudo apt install -y curl git redis-server

# Install Go 1.25
curl -fsSL https://go.dev/dl/go1.25.0.linux-amd64.tar.gz -o /tmp/go.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf /tmp/go.tar.gz
echo 'export PATH="/usr/local/go/bin:$PATH"' | sudo tee /etc/profile.d/go.sh
source /etc/profile.d/go.sh
```

### 2. Deploy

```bash
# Clone repo
sudo mkdir -p /opt/whatisit
sudo chown $USER:$USER /opt/whatisit
git clone https://github.com/verbeux-ai/whatsmiau.git /opt/whatisit/server-whatsmiau
mkdir -p /opt/whatisit/adapter
# Copy adapter files from your local workspace

# Build WhatsMiau
cd /opt/whatisit/server-whatsmiau
cp .env.example .env
go mod tidy
go build -o /usr/local/bin/whatsmiau-server ./main.go

# Build adapter
cd /opt/whatisit/adapter
go mod tidy
go build -o /usr/local/bin/whatisit-adapter ./main.go

# Create systemd services
sudo tee /etc/systemd/system/whatsmiau.service > /dev/null <<EOF
[Unit]
Description=WhatsMiau Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/whatisit/server-whatsmiau
ExecStart=/usr/local/bin/whatsmiau-server
Restart=always
RestartSec=5
Environment="PORT=8080"
Environment="API_KEY=${WHATSMIAM_API_KEY:-}"

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/whatisit-adapter.service > /dev/null <<EOF
[Unit]
Description=WhatIsIt Adapter
After=network.target whatsmiau.service

[Service]
Type=simple
WorkingDirectory=/opt/whatisit/adapter
ExecStart=/usr/local/bin/whatisit-adapter
Restart=always
RestartSec=5
Environment="WHATSMIAM_URL=http://127.0.0.1:8080"
Environment="INSTANCE_ID=${INSTANCE_ID:-default}"
Environment="API_KEY=${ADAPTER_API_KEY:-}"
Environment="LISTEN_ADDR=0.0.0.0:18770"
Environment="STORE_PATH=/opt/whatisit/history.json"
Environment="MEDIA_DIR=/opt/whatisit/media"
Environment="MEDIA_PUBLIC_URL=http://127.0.0.1:18770/files"
Environment="WEBHOOK_PUBLIC_URL=http://127.0.0.1:18770/webhook/whatsmiau"

[Install]
WantedBy=multi-user.target
EOF

# Start services
sudo systemctl daemon-reload
sudo systemctl enable --now whatsmiau
sudo systemctl enable --now whatisit-adapter

# Configure firewall
sudo ufw allow 18770/tcp
sudo ufw allow 22/tcp
sudo ufw --force enable
```

### 3. Verify

```bash
sudo systemctl status whatsmiau
sudo systemctl status whatisit-adapter
journalctl -u whatsmiau -f
journalctl -u whatisit-adapter -f
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `WHATSMIAM_URL` | `http://localhost:8080` | WhatsMiau base URL |
| `INSTANCE_ID` | `default` | Single instance name |
| `API_KEY` | `` | Passed to WhatsMiau as `apikey` |
| `LISTEN_ADDR` | `0.0.0.0:18770` | Adapter listen address |
| `STORE_PATH` | `history.json` | Local history persistence |
| `MEDIA_DIR` | `media` | Local media cache |
| `MEDIA_PUBLIC_URL` | `http://localhost:18770/files` | Public URL for media files |
| `WEBHOOK_PUBLIC_URL` | `http://localhost:18770/webhook/whatsmiau` | Public URL for WhatsMiau webhooks |

## HarmonyOS App Configuration

The app uses hidden compile-time backend configuration with automatic discovery:

```typescript
// entry/src/main/ets/services/ServerConfig.ets
export class ServerConfig {
  static readonly BACKEND_HOST: string = 'api.whatisit.app';
  static readonly BACKEND_PORT: number = 18770;
  static readonly BACKEND_TOKEN: string = '';
  static readonly BACKEND_HOST_PREF: string = 'backend_host';
  static readonly BACKEND_TOKEN_PREF: string = 'backend_token';
  static readonly BACKEND_FALLBACKS: string[] = [
    'api.whatisit.app',
    'localhost',
    '127.0.0.1',
  ];
  static readonly AUTO_DISCOVER: boolean = true;
  static readonly PROVISION_SCHEME: string = 'whatisit';
  static readonly PROVISION_HOST: string = 'provision';
}
```

### Auto-Discovery Flow

1. On first launch, the app probes known hosts in order
2. The first reachable host is saved to hidden preferences
3. Subsequent launches reuse the saved host
4. No manual IP configuration needed by end users

### Provisioning via QR

For air-gapped or per-customer deployments:
1. Generate a provisioning QR using the adapter's `/provision/qr` endpoint
2. The QR encodes a `whatisit://provision?host=...&port=...` deep link
3. The app registers this scheme in its intent filter (`module.json`)
4. Scanning the QR opens the app and auto-saves the backend URL
5. The app also has a built-in "Provision another device" button on the connect screen

### Phone-Number Linking

The phone-number pairing flow:
1. User enters country code + phone number
2. App requests an 8-character code from WhatsApp
3. The code is displayed with the country code prefix (e.g., `+1 XXXXXXXX`)
4. User enters the code in WhatsApp's "Link with phone number instead" flow

### Production Setup

For production with a custom domain:
1. Set `BACKEND_HOST` to your domain (e.g., `api.yourdomain.com`)
2. Point your domain's A record to the VPS IP
3. Rebuild the HAP

### Local Development

For emulator/local testing:
- The app auto-discovers `localhost` as a fallback
- No DNS setup needed for local testing

## Webhook Flow

The adapter configures WhatsMiau to send webhooks to:
```
http://ADAPTER_HOST:18770/webhook/whatsmiau
```

Supported webhook events:
- `messages.upsert` → stored locally + WS `message` event
- `messages.update` → stored locally + WS `receipt` event
- `messages.delete` → ignored
- `contacts.upsert` → WS `chats` event
- `connection.update` → WS `linked` / `logged_out` event

## Troubleshooting

| Issue | Fix |
|---|---|
| Adapter can't reach WhatsMiau | Check `WHATSMIAM_URL` and network/firewall rules |
| Webhook not received | Ensure `WEBHOOK_PUBLIC_URL` is reachable from WhatsMiau container/host |
| Media not sending | Ensure `MEDIA_PUBLIC_URL` is reachable from WhatsMiau |
| App shows "Can't reach server" | Verify port 18770 is open and DNS points `api.whatisit.app` to your VPS |
| Auto-discovery not working | Check that the default domain resolves; try manually setting `backend_host` preference |
| Provisioning QR not opening app | Ensure `module.json` has the `whatisit://provision` intent filter and the app is installed |
| Pair code not received | Check that the phone number includes country code; verify WhatsApp can send SMS to that number |
| QR not appearing | Check adapter logs for QR broadcast; ensure WS connection is open |

## Security Notes

- Use `API_KEY` environment variable to protect both WhatsMiau and the adapter
- The adapter does not implement rate limiting - add a reverse proxy (Caddy/Nginx) for production
- Keep port 18770 open only to the internet if the app needs remote access; restrict with firewall rules if possible
- WhatsApp sessions are sensitive - ensure your VPS is secure and regularly updated

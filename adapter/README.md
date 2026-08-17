# WhatIsIt — WhatsMiau Adapter

Thin Go adapter that makes [WhatsMiau](https://github.com/verbeux-ai/whatsmiau) compatible with the existing HarmonyOS WhatIsIt app. It exposes the same custom HTTP API and WebSocket events the app expects, while forwarding all WhatsApp operations to a WhatsMiau backend.

## Why an adapter?

The HarmonyOS app (`CdpBridge`) expects a fixed set of HTTP routes and WebSocket events:

- `GET /status`, `POST /pair`, `POST /pair-code`
- `GET /chats`, `GET /messages?chat=`
- `POST /send`, `POST /send-media`, `POST /read`, `POST /react`, `POST /logout`
- `GET /media/{id}/{kind}`
- `WS /ws` push events (`qr`, `linked`, `message`, `receipt`, `chats`, `logged_out`, `passkey_*`, `pair_code`)

WhatsMiau is a robust Go WhatsApp backend built on `whatsmeow` and designed to be a drop-in replacement for the Evolution API. It uses instance-based routes (`/v1/instance/{id}/...`) and webhooks for events, but it does **not** expose the polling endpoints (`/chats`, `/messages`) or the WebSocket push API the app expects.

This adapter bridges that gap:

1. It auto-creates and manages a single WhatsMiau instance.
2. It proxies send/media/read/react/logout requests to WhatsMiau's Evolution API-compatible endpoints.
3. It configures a webhook on WhatsMiau so the adapter receives `messages.upsert`, `messages.update`, `contacts.upsert`, and `connection.update` events.
4. It stores chats and messages locally (in-memory + JSON persistence) so the app's polling endpoints work without changes.
5. It pushes events to the app over WebSocket.

## Architecture

```
HarmonyOS app (WhatIsIt)
    │  HTTP: /status /pair /send /chats /messages ...
    │  WS:   /ws push events
    ▼
Adapter (Go, port 18770)
    │  - custom API translation
    │  - local chat/message history store
    │  - webhook receiver from WhatsMiau
    │  - WS event broadcaster
    ▼
WhatsMiau (Go, port 8080)
    │  - Evolution API-compatible routes
    │  - whatsmeow WhatsApp protocol
    ▼
WhatsApp
```

## Run locally

### 1. Start dependencies

```bash
docker run -d --name redis -p 6379:6379 redis:7-alpine
```

### 2. Start WhatsMiau

```bash
cd server-whatsmiau
cp .env.example .env
go mod tidy
go run main.go
```

WhatsMiau listens on `http://localhost:8080`.

### 3. Start the adapter

```bash
cd adapter
cp go.mod go.mod.bak   # if needed
go mod tidy
go run main.go
```

The adapter listens on `http://localhost:18770`.

Point the HarmonyOS app's hidden `backend_host` pref at the adapter host.

## Provisioning QR (air-gapped / per-customer)

For deployments where users should not manually enter a backend host, the adapter exposes:

```
GET /provision/qr?host=<backend>&port=<port>
```

Response:
```json
{
  "provision_url": "whatisit://provision?host=api.example.com&port=18770",
  "backend_host": "api.example.com",
  "backend_port": "18770",
  "adapter_url": "http://adapter:18770"
}
```

Encode `provision_url` as a QR code. When a user scans it with any QR reader that opens URLs, the WhatIsIt app launches (if installed) and auto-saves the backend. If the app is not installed, the URL is shown and can be copied.

The app also includes a built-in "Provision another device" button on the connect screen that renders the same QR using its native `QRCode` component.

## Phone-number linking (8-character code + country code)

The adapter forwards the phone-number pairing request to WhatsMiau. The flow:

1. User enters country code + phone number in the app.
2. App calls `POST /v1/instance/{id}/connect` with the full number.
3. WhatsMiau requests an 8-character code from WhatsApp.
4. The code arrives via the `pair_code` WS event.
5. The app displays the code alongside the country code for easy entry in WhatsApp.

The UI now prefixes the code with `+<country>` so the user can verify the full number context in WhatsApp.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `WHATSMIAM_URL` | `http://localhost:8080` | Base URL of the WhatsMiau server |
| `INSTANCE_ID` | `default` | Single instance name used for all app requests |
| `API_KEY` | `` | Passed through to WhatsMiau as `apikey` |
| `LISTEN_ADDR` | `0.0.0.0:18770` | Adapter listen address |
| `STORE_PATH` | `history.json` | Local JSON persistence for chat history |
| `MEDIA_DIR` | `media` | Local media cache directory |
| `MEDIA_PUBLIC_URL` | `` | Public base URL for uploaded media files (e.g. `http://localhost:18770/files`). Required for media send to work across services. |

## Docker Compose

```bash
docker compose -f docker-compose.adapter.yml up -d --build
```

This starts Redis, WhatsMiau, and the adapter. The app should point at the adapter host on port 18770.

## Status mapping

The adapter translates WhatsMiau instance states to the app's expected format:

| WhatsMiau state | Adapter `linked` |
|---|---|
| `open` | `true` |
| anything else | `false` |

## Webhook events

The adapter subscribes to these WhatsMiau webhook events:

| WhatsMiau event | Adapter WS event |
|---|---|
| `messages.upsert` | `message` |
| `messages.update` | `receipt` |
| `messages.delete` | *(ignored)* |
| `contacts.upsert` | `chats` |
| `connection.update` (`open`) | `linked` |
| `connection.update` (`close`) | `logged_out` |

## Limitations

- **Calls**: WhatsApp-native voice/video calls are not proxied yet. The adapter returns `501 Not Implemented` for `/call*` routes. Use the original `server-go` backend if you need calls.
- **Media cache**: Incoming media is not cached locally by the adapter. Media URLs come from WhatsMiau directly. If you need offline media, extend the webhook handler to download and cache files.
- **Passkey**: The adapter forwards passkey requests but does not implement the full SHORTCAKE ceremony. Use the original `server-go` if your account requires passkey linking.

## Migration from server-go

1. Keep your existing `server-go` running until the adapter is validated.
2. Start WhatsMiau + the adapter.
3. Update the app's `backend_host` to point at the adapter.
4. Verify QR pairing, chat list, messages, send, and reactions work.
5. Once validated, you can retire `server-go`.

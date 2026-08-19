# WhatIsIt server (Go)

Wire-compatible port of the Rust `server/` to **Go** on
[whatsmeow](https://github.com/tulir/whatsmeow) + [meowcaller](https://github.com/purpshell/meowcaller)
for WhatsApp-native calls.

The HarmonyOS app needs **zero changes**: every HTTP route, WS event, binary
media frame tag, and the passkey (SHORTCAKE) flow match the Rust server
exactly (see `parity_test.go`).

## Build

```sh
# needs Go >= 1.25 (the pinned toolchain auto-downloads)
go build ./...
go test ./...
```

## Run

```sh
WHATSAPP_TOKEN=secret PORT=18770 go run ./cmd/server
# clear the persisted chat store before starting (fresh pairing / demo cleanup):
/tmp/whatisit-server -reset
```

| Env | Default | Meaning |
|---|---|---|
| `WHATSAPP_TOKEN` | (empty) | Bearer auth token; empty = auth off |
| `PORT` | `18770` | Listen port |
| `HOST` | `0.0.0.0` | Bind address |
| `DB_PATH` | `whatsapp.db` | whatsmeow SQLite session store |
| `MEDIA_DIR` | `media` | Incoming media cache |

## Wire contract (unchanged from the Rust server)

- **HTTP**: `/status`, `/pair`, `/pair-code`, `/chats`, `/messages?chat=&limit=`,
  `/status-list`, `/calls`, `/channels`, `/channel/follow`, `/channel/unfollow`,
  `/status-update`, `/history/backfill`, `/send`, `/send-media`, `/read`,
  `/react`, `/logout`, `/media/{id}/{kind}`, `/call*`, `/passkey/*`, `/ws`.
- **WS text events**: `qr`, `linked`, `message`, `receipt`, `chats`,
  `logged_out`, `status` (sent on connect — carry `linked`/`phone`/`qr`),
  `incoming_call` (callId/from/video), `call_state`, `pair_code`,
  `passkey_request`, `passkey_confirmation`, `passkey_error`.
- **WS binary media**: `[1][pcm s16le]` (audio), `[2][keyframe][h264 AU]` (video).

## Sync & store behaviour

- Messages are stored **time-ordered** (deduped by ID) regardless of arrival
  order; chat previews/threads/the chat list all use the newest-by-time message.
- The store **auto-flushes every 5s** and on graceful shutdown (`SIGINT`/`SIGTERM`),
  so live messages survive restarts. `Flush` also runs after every history sync.
- `/messages` serves the whole stored thread by default (cap 5,000 messages);
  pass `limit=` for a window.
- `POST /history/backfill {chat, count}` requests older messages from the
  phone's primary device via whatsmeow's on-demand history sync
  (`BuildHistorySyncRequest` + `SendPeerMessage`); the response arrives as a
  normal `events.HistorySync` and is ingested into the store.
- Status posts (`status@broadcast` messages, live or inside a history sync) are
  recorded as the latest per contact and served by `/status-list`.
- `-reset` deletes `history.json` on startup (used to clear demo/seed data or
  start a fresh pairing cleanly). WhatsApp history is only ever written by the
  phone: link the device and choose "full history" to backfill a backlog.

## Calls (meowcaller)

The app's 48 kHz stereo s16le PCM is downmixed+resampled to meowcaller's
16 kHz mono float32; the peer's audio is upsampled back. H.264 AUs pass
through; the keyframe byte in the video frame is derived from the NAL units.

## Deploy

See `DEPLOY.md`.

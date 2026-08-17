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
```

| Env | Default | Meaning |
|---|---|---|
| `WHATSAPP_TOKEN` | (empty) | Bearer auth token; empty = auth off |
| `PORT` | `18770` | Listen port |
| `HOST` | `0.0.0.0` | Bind address |
| `DB_PATH` | `whatsapp.db` | whatsmeow SQLite session store |
| `MEDIA_DIR` | `media` | Incoming media cache |

## Wire contract (unchanged from the Rust server)

- **HTTP**: `/status`, `/pair`, `/pair-code`, `/chats`, `/messages?chat=`,
  `/send`, `/send-media`, `/read`, `/react`, `/logout`, `/media/{id}/{kind}`,
  `/call*`, `/passkey/*`, `/ws`.
- **WS text events**: `qr`, `linked`, `message`, `receipt`, `chats`,
  `logged_out`, `incoming_call` (callId/from/video), `call_state`,
  `pair_code`, `passkey_request`, `passkey_confirmation`, `passkey_error`.
- **WS binary media**: `[1][pcm s16le]` (audio), `[2][keyframe][h264 AU]` (video).

## Calls (meowcaller)

The app's 48 kHz stereo s16le PCM is downmixed+resampled to meowcaller's
16 kHz mono float32; the peer's audio is upsampled back. H.264 AUs pass
through; the keyframe byte in the video frame is derived from the NAL units.

## Deploy

See `DEPLOY.md`.
